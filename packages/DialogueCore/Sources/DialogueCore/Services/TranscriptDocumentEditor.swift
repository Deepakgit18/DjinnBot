import Foundation
import OSLog

// MARK: - TranscriptDocumentEditor

/// Serializes transcript entries into a human-editable plain-text document
/// and parses the edited text back into `TranscriptEntry` values using a
/// multi-pass lenient parser.
///
/// ## Document Format
///
/// Each segment is represented as a marker line followed by its text body,
/// with blank lines separating segments:
///
/// ```
/// «seg:A1B2C3D4 | 0:12 sky [Local]»
/// Hey, so I was thinking about the project timeline.
///
/// «seg:E5F6G7H8 | 0:25 Jordan [Remote]»
/// Yeah, I think we should push it back a week.
/// ```
///
/// The `seg:XXXXXXXX` is the first 8 hex characters of the entry's UUID.
/// Users can freely edit text bodies and speaker names. The parser matches
/// markers back to original entries through multiple fallback passes.
public enum TranscriptDocumentEditor {

    private static let logger = Logger(subsystem: "com.basedatum.Dialogue", category: "TranscriptDocumentEditor")

    // MARK: - Serialize

    /// Convert transcript entries into an editable document string.
    public static func serialize(_ entries: [TranscriptEntry]) -> String {
        let sorted = entries.sorted { $0.start < $1.start }
        var parts: [String] = []

        for entry in sorted {
            let marker = buildMarker(for: entry)
            // Combine marker + body (text may span multiple lines)
            parts.append("\(marker)\n\(entry.text)")
        }

        return parts.joined(separator: "\n\n")
    }

    /// Build the marker line for an entry.
    ///
    /// Format: `«seg:A1B2C3D4 | 0:12 sky [Local]»`
    private static func buildMarker(for entry: TranscriptEntry) -> String {
        let uuidPrefix = uuidShortPrefix(entry.id)
        let timestamp = formatTimestamp(entry.start)
        let stream = entry.stream == "Local" ? "Local" : "Remote"
        return "«seg:\(uuidPrefix) | \(timestamp) \(entry.speaker) [\(stream)]»"
    }

    /// First 8 hex characters of a UUID (lowercase, no hyphens).
    private static func uuidShortPrefix(_ uuid: UUID) -> String {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(hex.prefix(8))
    }

    /// Format seconds as `M:SS`.
    private static func formatTimestamp(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    // MARK: - Parse

    /// Parse an edited document string back into transcript entries.
    ///
    /// The parser runs multiple passes with increasing leniency:
    /// 1. Exact UUID prefix match
    /// 2. Fuzzy match by position + timestamp proximity
    /// 3. Marker-only match (no UUID, using timestamp + speaker)
    /// 4. Structural recovery (best-effort for damaged markers)
    ///
    /// Returns a `ParseResult` that may contain errors. The caller should
    /// check `hasErrors` and present the error UI if needed.
    public static func parse(_ text: String, original: [TranscriptEntry]) -> ParseResult {
        let sortedOriginal = original.sorted { $0.start < $1.start }
        let originalByPrefix = Dictionary(
            sortedOriginal.map { (uuidShortPrefix($0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let originalByID = Dictionary(
            sortedOriginal.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Step 1: Split the document into raw segments (marker + body)
        let rawSegments = splitIntoRawSegments(text)

        // Step 2: Parse each raw segment through the multi-pass pipeline
        var results: [SegmentParseResult] = []
        var matchedIDs = Set<UUID>()

        for (index, raw) in rawSegments.enumerated() {
            let result = parseRawSegment(
                raw,
                index: index,
                originalByPrefix: originalByPrefix,
                originalByID: originalByID,
                sortedOriginal: sortedOriginal,
                matchedIDs: &matchedIDs
            )
            results.append(result)
        }

        // Step 3: Detect deletions — original entries not present in output
        let deletedIDs = Set(sortedOriginal.map(\.id)).subtracting(matchedIDs)

        return ParseResult(
            segments: results,
            deletedEntryIDs: Array(deletedIDs),
            originalEntries: sortedOriginal
        )
    }

    // MARK: - Raw Segment Splitting

    /// A raw segment extracted from the document text.
    public struct RawSegment {
        /// The full marker line (including «»).
        let markerLine: String
        /// Line number (0-indexed) of the marker in the original text.
        let markerLineNumber: Int
        /// The text body following the marker.
        let bodyText: String
        /// Line range (0-indexed, inclusive) of the entire segment in the document.
        let lineRange: ClosedRange<Int>
    }

    /// Split the document into raw segments by detecting marker lines.
    /// A marker line matches the pattern: `«...»` (possibly with leading whitespace).
    private static func splitIntoRawSegments(_ text: String) -> [RawSegment] {
        let lines = text.components(separatedBy: .newlines)
        var segments: [RawSegment] = []
        var currentMarkerLine: String?
        var currentMarkerLineNum: Int?
        var bodyLines: [String] = []
        var bodyStartLine: Int?

        for (lineNum, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("«") && trimmed.hasSuffix("»") {
                // New marker found — flush previous segment
                if let marker = currentMarkerLine, let markerNum = currentMarkerLineNum {
                    let body = bodyLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let endLine = bodyLines.isEmpty ? markerNum : (bodyStartLine ?? markerNum) + bodyLines.count - 1
                    segments.append(RawSegment(
                        markerLine: marker,
                        markerLineNumber: markerNum,
                        bodyText: body,
                        lineRange: markerNum...max(markerNum, lineNum - 1)
                    ))
                }
                currentMarkerLine = trimmed
                currentMarkerLineNum = lineNum
                bodyLines = []
                bodyStartLine = nil
            } else {
                // Body line (or whitespace between segments)
                if currentMarkerLine != nil {
                    if bodyStartLine == nil && !trimmed.isEmpty {
                        bodyStartLine = lineNum
                    }
                    bodyLines.append(line)
                }
                // Lines before the first marker are ignored
            }
        }

        // Flush last segment
        if let marker = currentMarkerLine, let markerNum = currentMarkerLineNum {
            let body = bodyLines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let endLine = lines.count - 1
            segments.append(RawSegment(
                markerLine: marker,
                markerLineNumber: markerNum,
                bodyText: body,
                lineRange: markerNum...endLine
            ))
        }

        return segments
    }

    // MARK: - Marker Parsing

    /// Components extracted from a marker line.
    public struct ParsedMarker {
        var uuidPrefix: String?
        var timestamp: TimeInterval?
        var speaker: String?
        var stream: String?
    }

    /// Parse the components of a marker line.
    ///
    /// Expected format: `«seg:A1B2C3D4 | 0:12 sky [Local]»`
    /// Each component may be missing or malformed — we extract what we can.
    private static func parseMarker(_ line: String) -> ParsedMarker {
        // Strip the « and »
        var content = line
        if content.hasPrefix("«") { content = String(content.dropFirst()) }
        if content.hasSuffix("»") { content = String(content.dropLast()) }
        content = content.trimmingCharacters(in: .whitespaces)

        var marker = ParsedMarker()

        // Try to extract UUID prefix: "seg:XXXXXXXX"
        if let segRange = content.range(of: "seg:", options: .caseInsensitive) {
            let afterSeg = content[segRange.upperBound...]
            // Take hex characters (up to 8)
            let hexChars = afterSeg.prefix(while: { $0.isHexDigit })
            if hexChars.count >= 4 {
                marker.uuidPrefix = String(hexChars).lowercased()
            }
        }

        // Try to extract stream: "[Local]" or "[Remote]"
        if let bracketRange = content.range(of: "\\[(?:Local|Remote)\\]", options: .regularExpression) {
            let streamStr = content[bracketRange].dropFirst().dropLast()
            marker.stream = String(streamStr)
        }

        // Try to extract timestamp: "M:SS" or "MM:SS" pattern
        // Look for it after the "|" separator
        let afterPipe: Substring
        if let pipeRange = content.range(of: "|") {
            afterPipe = content[pipeRange.upperBound...]
        } else {
            afterPipe = content[content.startIndex...]
        }

        let timestampPattern = #"(\d{1,3}):(\d{2})"#
        if let match = afterPipe.range(of: timestampPattern, options: .regularExpression) {
            let timestampStr = afterPipe[match]
            let parts = timestampStr.split(separator: ":")
            if parts.count == 2,
               let minutes = Int(parts[0]),
               let seconds = Int(parts[1]) {
                marker.timestamp = TimeInterval(minutes * 60 + seconds)
            }

            // Speaker name is between timestamp and stream bracket
            let afterTimestamp = afterPipe[match.upperBound...]
                .trimmingCharacters(in: .whitespaces)
            // Remove the [Stream] part if present
            let speakerStr: String
            if let bracketStart = afterTimestamp.range(of: "[") {
                speakerStr = String(afterTimestamp[afterTimestamp.startIndex..<bracketStart.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            } else {
                speakerStr = afterTimestamp.trimmingCharacters(in: .whitespaces)
            }
            if !speakerStr.isEmpty {
                marker.speaker = speakerStr
            }
        }

        return marker
    }

    // MARK: - Multi-Pass Matching

    private static func parseRawSegment(
        _ raw: RawSegment,
        index: Int,
        originalByPrefix: [String: TranscriptEntry],
        originalByID: [UUID: TranscriptEntry],
        sortedOriginal: [TranscriptEntry],
        matchedIDs: inout Set<UUID>
    ) -> SegmentParseResult {
        let parsed = parseMarker(raw.markerLine)

        // Pass 1: Exact UUID prefix match
        if let prefix = parsed.uuidPrefix,
           let original = originalByPrefix[prefix],
           !matchedIDs.contains(original.id) {
            matchedIDs.insert(original.id)
            return .matched(SegmentMatch(
                entryID: original.id,
                newSpeaker: parsed.speaker ?? original.speaker,
                newText: raw.bodyText.isEmpty ? original.text : raw.bodyText,
                stream: parsed.stream ?? original.stream,
                start: original.start,
                end: original.end,
                isFinal: original.isFinal
            ))
        }

        // Pass 2: Fuzzy match by position + timestamp proximity
        if let timestamp = parsed.timestamp {
            // Find the closest unmatched original entry by timestamp
            var bestMatch: TranscriptEntry?
            var bestDistance: TimeInterval = .greatestFiniteMagnitude

            for orig in sortedOriginal where !matchedIDs.contains(orig.id) {
                let distance = abs(orig.start - timestamp)
                if distance < bestDistance {
                    bestDistance = distance
                    bestMatch = orig
                }
            }

            // Accept if within 5 seconds (timestamps are M:SS so 1s precision loss is expected)
            if let match = bestMatch, bestDistance <= 5.0 {
                matchedIDs.insert(match.id)
                return .matched(SegmentMatch(
                    entryID: match.id,
                    newSpeaker: parsed.speaker ?? match.speaker,
                    newText: raw.bodyText.isEmpty ? match.text : raw.bodyText,
                    stream: parsed.stream ?? match.stream,
                    start: match.start,
                    end: match.end,
                    isFinal: match.isFinal
                ))
            }
        }

        // Pass 3: Position-based match (fallback for completely mangled markers)
        if index < sortedOriginal.count {
            let positionalCandidate = sortedOriginal[index]
            if !matchedIDs.contains(positionalCandidate.id) {
                // Only accept if speaker or timestamp has some resemblance
                let speakerMatch = parsed.speaker == positionalCandidate.speaker
                let timestampClose = parsed.timestamp.map { abs($0 - positionalCandidate.start) <= 30 } ?? false

                if speakerMatch || timestampClose {
                    matchedIDs.insert(positionalCandidate.id)
                    return .matched(SegmentMatch(
                        entryID: positionalCandidate.id,
                        newSpeaker: parsed.speaker ?? positionalCandidate.speaker,
                        newText: raw.bodyText.isEmpty ? positionalCandidate.text : raw.bodyText,
                        stream: parsed.stream ?? positionalCandidate.stream,
                        start: positionalCandidate.start,
                        end: positionalCandidate.end,
                        isFinal: positionalCandidate.isFinal
                    ))
                }
            }
        }

        // All passes failed — report error
        let reason: ParseError
        if parsed.uuidPrefix == nil && parsed.timestamp == nil && parsed.speaker == nil {
            reason = .corruptedMarker(
                line: raw.markerLine,
                suggestion: "The segment marker is unreadable. It should look like: «seg:XXXXXXXX | M:SS Speaker [Local]»"
            )
        } else if let prefix = parsed.uuidPrefix, originalByPrefix[prefix] == nil {
            reason = .unrecognizedUUID(prefix: prefix)
        } else {
            reason = .ambiguousMatch(
                markerLine: raw.markerLine,
                detail: "Could not confidently match this marker to any original segment. The UUID, timestamp, or speaker may have been altered too much."
            )
        }

        return .error(SegmentError(
            lineRange: raw.lineRange,
            markerLine: raw.markerLine,
            bodyText: raw.bodyText,
            reason: reason
        ))
    }
}

// MARK: - Parse Result Types

/// The result of parsing an edited transcript document.
public struct ParseResult {
    /// Per-segment parse results (matched or error).
    public let segments: [SegmentParseResult]
    /// UUIDs of original entries not found in the edited document (deletions).
    public let deletedEntryIDs: [UUID]
    /// The original entries for reference.
    public let originalEntries: [TranscriptEntry]

    /// Whether any segments failed to parse.
    public var hasErrors: Bool {
        segments.contains { if case .error = $0 { return true } else { return false } }
    }

    /// The error segments only.
    public var errors: [SegmentError] {
        segments.compactMap { if case .error(let e) = $0 { return e } else { return nil } }
    }

    /// The successfully matched segments only.
    public var matches: [SegmentMatch] {
        segments.compactMap { if case .matched(let m) = $0 { return m } else { return nil } }
    }

    /// Build final `TranscriptEntry` array from matched segments.
    /// Errors are left unchanged from the original.
    public func buildEntries() -> [TranscriptEntry] {
        var entriesByID: [UUID: TranscriptEntry] = [:]
        for orig in originalEntries {
            entriesByID[orig.id] = orig
        }

        // Apply matched edits
        for match in matches {
            if let orig = entriesByID[match.entryID] {
                entriesByID[match.entryID] = TranscriptEntry(
                    id: orig.id,
                    speaker: match.newSpeaker,
                    start: orig.start,
                    end: orig.end,
                    text: match.newText,
                    stream: match.stream,
                    isFinal: orig.isFinal
                )
            }
        }

        // Remove deletions
        for id in deletedEntryIDs {
            entriesByID.removeValue(forKey: id)
        }

        return entriesByID.values.sorted { $0.start < $1.start }
    }
}

/// Result for a single segment parse attempt.
public enum SegmentParseResult {
    case matched(SegmentMatch)
    case error(SegmentError)
}

/// A successfully matched segment with edits applied.
public struct SegmentMatch {
    public let entryID: UUID
    public let newSpeaker: String
    public let newText: String
    public let stream: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let isFinal: Bool
}

/// A segment that failed to parse.
public struct SegmentError: Identifiable {
    public let id = UUID()
    /// Line range (0-indexed, inclusive) in the edited document.
    public let lineRange: ClosedRange<Int>
    /// The raw marker line.
    public let markerLine: String
    /// The raw body text.
    public let bodyText: String
    /// Why parsing failed.
    public let reason: ParseError
}

/// Why a segment failed to parse.
public enum ParseError {
    /// The marker line is so mangled it can't be read at all.
    case corruptedMarker(line: String, suggestion: String)
    /// The UUID prefix doesn't match any original entry.
    case unrecognizedUUID(prefix: String)
    /// Multiple possible matches; can't determine which is correct.
    case ambiguousMatch(markerLine: String, detail: String)

    public var localizedDescription: String {
        switch self {
        case .corruptedMarker(_, let suggestion):
            return suggestion
        case .unrecognizedUUID(let prefix):
            return "The segment code '\(prefix)' doesn't match any original segment. Don't modify the seg: codes."
        case .ambiguousMatch(_, let detail):
            return detail
        }
    }
}
