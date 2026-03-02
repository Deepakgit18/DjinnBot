import FluidAudio
import Foundation
import OSLog

/// Runs high-accuracy offline Pyannote diarization (VBx pipeline) on per-stream
/// WAV files after recording stops, then re-attributes the live transcript using
/// the offline ground-truth speaker clustering.
///
/// ## Why this works better than live diarization
///
/// Live (streaming) Pyannote processes 10s sliding windows with limited context,
/// producing ~26% DER and significant speaker fragmentation. The offline pipeline
/// sees the **full audio at once**, applies VBx clustering with PLDA scoring, and
/// achieves ~14% DER — roughly 2x better accuracy.
///
/// ## Flow
///
/// 1. Load per-stream WAVs (local.wav, remote.wav) from the meeting folder
/// 2. Run `OfflineDiarizerManager.process(url)` on each independently
/// 3. For each live transcript segment, find the offline segment that overlaps
///    its time range and re-attribute to the offline speaker
/// 4. Map offline speaker IDs back to human-readable names using the live
///    recording's VoiceID matches as hints
/// 5. Save the refined transcript
///
/// ## Embedding dimension mismatch
///
/// The offline pipeline uses 192-d WeSpeaker ResNet34 embeddings (with FBank
/// features + PLDA), while VoiceID enrolled voices use 256-d embeddings from
/// the online pipeline. We do NOT compare across embedding spaces. Instead,
/// we use temporal overlap between live segments and offline segments to map
/// speaker identities.
// MARK: - Progress Tracking

/// Observable progress state for the post-recording refinement pipeline.
/// Observed by `StatusFooterView` to show a progress bar.
@MainActor
final class RefinementProgress: ObservableObject {
    static let shared = RefinementProgress()

    enum State: Equatable {
        case idle
        case preparingModels
        case processingStream(name: String, current: Int, total: Int)
        case reattributing
        case complete(reattributed: Int, total: Int)
        case failed(String)
    }

    @Published var state: State = .idle

    /// True when refinement is actively running (not idle/complete/failed).
    var isActive: Bool {
        switch state {
        case .idle, .complete, .failed: return false
        default: return true
        }
    }

    /// Fractional progress (0.0–1.0) for the progress bar, or nil if indeterminate.
    var fraction: Double? {
        switch state {
        case .preparingModels: return nil
        case .processingStream(_, let current, let total):
            guard total > 0 else { return nil }
            return Double(current - 1) / Double(total)
        case .reattributing: return 0.9
        case .complete: return 1.0
        default: return nil
        }
    }

    /// Human-readable description of the current stage.
    var description: String {
        switch state {
        case .idle: return ""
        case .preparingModels: return "Downloading refinement models..."
        case .processingStream(let name, let current, let total):
            return "Refining \(name) audio (\(current)/\(total))..."
        case .reattributing: return "Re-attributing speakers..."
        case .complete(let n, let total):
            return "Refinement complete: \(n)/\(total) segments improved"
        case .failed(let msg): return "Refinement failed: \(msg)"
        }
    }

    private init() {}
}

// MARK: - PostRecordingRefiner

@available(macOS 14.0, iOS 17.0, *)
final class PostRecordingRefiner {

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "PostRecordingRefiner")

    /// Per-stream offline diarization result.
    struct StreamResult {
        let stream: StreamType
        let segments: [TimedSpeakerSegment]
        let speakerDatabase: [String: [Float]]?
    }

    // MARK: - Public API

    /// Refine a meeting's transcript using offline diarization on per-stream WAVs.
    ///
    /// - Parameters:
    ///   - localWavURL: Path to local (mic) WAV file
    ///   - remoteWavURL: Path to remote (meeting app) WAV file
    ///   - liveSegments: The live transcript segments to refine
    /// - Returns: Refined transcript segments with improved speaker attribution
    func refine(
        localWavURL: URL?,
        remoteWavURL: URL?,
        liveSegments: [TaggedSegment]
    ) async throws -> [TaggedSegment] {
        logger.info("[REFINE] Starting post-recording refinement")
        let progress = RefinementProgress.shared

        // Initialize offline diarizer
        let config = OfflineDiarizerConfig.default
        let diarizer = OfflineDiarizerManager(config: config)

        await MainActor.run { progress.state = .preparingModels }
        logger.info("[REFINE] Preparing offline diarizer models...")
        try await diarizer.prepareModels()
        logger.info("[REFINE] Offline diarizer models ready")

        // Count how many streams we'll process
        let fm = FileManager.default
        var streamJobs: [(url: URL, stream: StreamType, name: String)] = []
        if let localURL = localWavURL, fm.fileExists(atPath: localURL.path) {
            streamJobs.append((localURL, .mic, "Local"))
        }
        if let remoteURL = remoteWavURL, fm.fileExists(atPath: remoteURL.path) {
            streamJobs.append((remoteURL, .meeting, "Remote"))
        }

        // Run offline diarization on each stream independently
        var offlineResults: [StreamResult] = []

        for (index, job) in streamJobs.enumerated() {
            await MainActor.run {
                progress.state = .processingStream(
                    name: job.name, current: index + 1, total: streamJobs.count
                )
            }
            logger.info("[REFINE] Processing \(job.name) audio...")
            do {
                let result = try await diarizer.process(job.url)
                let sr = StreamResult(
                    stream: job.stream,
                    segments: result.segments,
                    speakerDatabase: result.speakerDatabase
                )
                offlineResults.append(sr)
                let speakers = Set(result.segments.map(\.speakerId))
                logger.info("[REFINE] \(job.name): \(result.segments.count) segments, \(speakers.count) speakers: \(speakers.sorted().joined(separator: ", "))")
            } catch {
                logger.warning("[REFINE] \(job.name) diarization failed: \(error.localizedDescription)")
            }
        }

        guard !offlineResults.isEmpty else {
            logger.warning("[REFINE] No offline results produced; returning live transcript unchanged")
            await MainActor.run { progress.state = .idle }
            return liveSegments
        }

        await MainActor.run { progress.state = .reattributing }

        // Build offline speaker name mapping: offline ID → human-readable name.
        // Uses temporal overlap between live segments and offline segments to
        // transfer VoiceID-identified names (e.g. "sky") to offline speaker clusters.
        let nameMapping = buildNameMapping(
            liveSegments: liveSegments,
            offlineResults: offlineResults
        )

        // Re-attribute each live segment using offline diarization.
        // When word timings are available and the offline diarization shows a
        // speaker transition *within* a live segment, split the segment at the
        // word boundary closest to the offline transition point.
        var refined: [TaggedSegment] = []
        var reattributed = 0
        var split = 0
        var unchanged = 0

        for seg in liveSegments {
            guard seg.isFinal, !seg.text.isEmpty else {
                refined.append(seg)
                continue
            }

            // Find the offline result for this stream
            guard let offlineResult = offlineResults.first(where: { $0.stream == seg.stream }) else {
                refined.append(seg)
                unchanged += 1
                continue
            }

            // Find all offline speaker spans that overlap this segment's time range.
            let speakerSpans = findOverlappingSpans(
                start: seg.start, end: seg.end,
                offlineSegments: offlineResult.segments,
                nameMapping: nameMapping,
                stream: seg.stream
            )

            if speakerSpans.isEmpty {
                // No offline data covers this segment
                refined.append(seg)
                unchanged += 1
                continue
            }

            if speakerSpans.count == 1 {
                // Single speaker — simple re-attribution (no split needed)
                let resolvedName = speakerSpans[0].speaker
                if seg.speaker != resolvedName {
                    var updated = seg
                    updated.speaker = resolvedName
                    refined.append(updated)
                    reattributed += 1
                    let ts = String(format: "%.1f", seg.start)
                    let te = String(format: "%.1f", seg.end)
                    logger.info("[REFINE] [\(ts)s-\(te)s] '\(seg.speaker)' → '\(resolvedName)'")
                } else {
                    refined.append(seg)
                    unchanged += 1
                }
                continue
            }

            // Multiple speakers overlap this segment — try to split using word timings
            if !seg.wordTimings.isEmpty {
                let splitSegments = splitAtSpeakerBoundaries(
                    segment: seg,
                    speakerSpans: speakerSpans
                )
                if splitSegments.count > 1 {
                    let ts = String(format: "%.1f", seg.start)
                    let te = String(format: "%.1f", seg.end)
                    let speakers = splitSegments.map(\.speaker).joined(separator: " → ")
                    logger.info("[REFINE] [\(ts)s-\(te)s] SPLIT into \(splitSegments.count) parts: \(speakers)")
                    refined.append(contentsOf: splitSegments)
                    split += 1
                    continue
                }
            }

            // Fall back to dominant-speaker re-attribution when no word timings
            // or splitting produced only one segment
            let dominant = speakerSpans.max { $0.overlap < $1.overlap }!
            if seg.speaker != dominant.speaker {
                var updated = seg
                updated.speaker = dominant.speaker
                refined.append(updated)
                reattributed += 1
                let ts = String(format: "%.1f", seg.start)
                let te = String(format: "%.1f", seg.end)
                logger.info("[REFINE] [\(ts)s-\(te)s] '\(seg.speaker)' → '\(dominant.speaker)' (dominant)")
            } else {
                refined.append(seg)
                unchanged += 1
            }
        }

        logger.info("[REFINE] Complete: \(reattributed) re-attributed, \(split) split, \(unchanged) unchanged, \(refined.count) total segments (was \(liveSegments.count))")
        await MainActor.run {
            progress.state = .complete(reattributed: reattributed + split, total: refined.count)
        }

        // Auto-dismiss after 5 seconds
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if case .complete = progress.state {
                progress.state = .idle
            }
        }

        return refined
    }

    // MARK: - Name Mapping

    /// Build a mapping from offline speaker IDs to human-readable names.
    ///
    /// Strategy: for each offline speaker, find which live speaker name
    /// appears most frequently in overlapping time ranges. If that live name
    /// was a VoiceID-identified name (like "sky"), transfer it. Otherwise,
    /// keep the offline ID with a stream prefix.
    private func buildNameMapping(
        liveSegments: [TaggedSegment],
        offlineResults: [StreamResult]
    ) -> [String: String] {
        var mapping: [String: String] = [:]

        for offlineResult in offlineResults {
            let stream = offlineResult.stream

            // Group offline segments by speaker
            var offlineSpeakerSegments: [String: [TimedSpeakerSegment]] = [:]
            for seg in offlineResult.segments {
                offlineSpeakerSegments[seg.speakerId, default: []].append(seg)
            }

            // For each offline speaker, find the live speaker with most overlap
            let streamLiveSegments = liveSegments.filter { $0.stream == stream && $0.isFinal && !$0.text.isEmpty }

            // Track how much overlap each (offlineSpeaker → liveSpeaker) pair has
            var overlapMatrix: [String: [String: TimeInterval]] = [:]

            for (offlineSpeakerID, offlineSegs) in offlineSpeakerSegments {
                var liveSpeakerOverlaps: [String: TimeInterval] = [:]

                for offlineSeg in offlineSegs {
                    let oStart = Double(offlineSeg.startTimeSeconds)
                    let oEnd = Double(offlineSeg.endTimeSeconds)

                    for liveSeg in streamLiveSegments {
                        let overlapStart = max(oStart, liveSeg.start)
                        let overlapEnd = min(oEnd, liveSeg.end)
                        let overlap = max(0, overlapEnd - overlapStart)
                        if overlap > 0 {
                            liveSpeakerOverlaps[liveSeg.speaker, default: 0] += overlap
                        }
                    }
                }

                overlapMatrix[offlineSpeakerID] = liveSpeakerOverlaps
            }

            // Assign names: prefer VoiceID-identified names, then enrolled voice names
            var usedNames: Set<String> = []
            let enrolledNames = Set(VoiceID.shared.allEnrolledVoices().map(\.userID))

            // Sort offline speakers by total speech duration (most speech first)
            // so more prominent speakers get name priority
            let rankedOfflineSpeakers = offlineSpeakerSegments.keys.sorted { a, b in
                let aDur = offlineSpeakerSegments[a]?.reduce(0.0) { $0 + Double($1.durationSeconds) } ?? 0
                let bDur = offlineSpeakerSegments[b]?.reduce(0.0) { $0 + Double($1.durationSeconds) } ?? 0
                return aDur > bDur
            }

            for offlineSpeakerID in rankedOfflineSpeakers {
                let key = "\(stream.rawValue)-\(offlineSpeakerID)"
                guard let liveSpeakerOverlaps = overlapMatrix[offlineSpeakerID] else {
                    // No live overlap — use stream-prefixed offline ID
                    mapping[key] = "\(stream.rawValue)-\(offlineSpeakerID)"
                    continue
                }

                // Sort by overlap duration descending
                let ranked = liveSpeakerOverlaps.sorted { $0.value > $1.value }

                // Prefer enrolled voice names that aren't already used
                var bestName: String?
                for (liveName, _) in ranked {
                    if enrolledNames.contains(liveName) && !usedNames.contains(liveName) {
                        bestName = liveName
                        break
                    }
                }

                // Fall back to the most-overlapping live name if it's not already used
                if bestName == nil, let topMatch = ranked.first, !usedNames.contains(topMatch.key) {
                    bestName = topMatch.key
                }

                let resolvedName = bestName ?? "\(stream.rawValue)-\(offlineSpeakerID)"
                mapping[key] = resolvedName
                usedNames.insert(resolvedName)

                let dur = String(format: "%.1f", liveSpeakerOverlaps.values.reduce(0, +))
                logger.info("[REFINE] Mapping offline \(offlineSpeakerID) → '\(resolvedName)' (\(dur)s overlap)")
            }
        }

        return mapping
    }

    // MARK: - Overlap Matching

    /// A resolved speaker span within a live segment's time range.
    struct SpeakerSpan {
        let speaker: String       // Resolved (mapped) speaker name
        let start: TimeInterval   // Span start within the segment
        let end: TimeInterval     // Span end within the segment
        let overlap: TimeInterval // How much of the span overlaps the segment
    }

    /// Find ALL offline speaker spans that overlap a given time range, resolved
    /// through the name mapping. Spans are sorted by start time.
    ///
    /// Unlike the old `findBestOverlap` which returned a single winner, this
    /// returns every speaker transition within the segment so we can split text.
    private func findOverlappingSpans(
        start: TimeInterval,
        end: TimeInterval,
        offlineSegments: [TimedSpeakerSegment],
        nameMapping: [String: String],
        stream: StreamType
    ) -> [SpeakerSpan] {
        var spans: [SpeakerSpan] = []

        for seg in offlineSegments {
            let oStart = Double(seg.startTimeSeconds)
            let oEnd = Double(seg.endTimeSeconds)
            let overlapStart = max(start, oStart)
            let overlapEnd = min(end, oEnd)
            let overlap = overlapEnd - overlapStart

            guard overlap >= 0.05 else { continue } // 50ms minimum

            let resolvedName = nameMapping["\(stream.rawValue)-\(seg.speakerId)"]
                ?? "\(stream.rawValue)-\(seg.speakerId)"

            spans.append(SpeakerSpan(
                speaker: resolvedName,
                start: overlapStart,
                end: overlapEnd,
                overlap: overlap
            ))
        }

        // Sort by start time
        spans.sort { $0.start < $1.start }

        // Merge consecutive spans from the same speaker (offline diarization
        // sometimes fragments a single speaker turn into adjacent segments)
        var merged: [SpeakerSpan] = []
        for span in spans {
            if var last = merged.last, last.speaker == span.speaker,
               span.start - last.end < 0.3 { // 300ms gap tolerance
                last = SpeakerSpan(
                    speaker: last.speaker,
                    start: last.start,
                    end: max(last.end, span.end),
                    overlap: last.overlap + span.overlap
                )
                merged[merged.count - 1] = last
            } else {
                merged.append(span)
            }
        }

        return merged
    }

    // MARK: - Segment Splitting

    /// Split a live segment at speaker boundaries using word-level timing.
    ///
    /// For each speaker transition point in `speakerSpans`, finds the word whose
    /// timing boundary is closest and splits the text there. Returns one
    /// `TaggedSegment` per speaker span, with correct text, timing, and word timings.
    private func splitAtSpeakerBoundaries(
        segment: TaggedSegment,
        speakerSpans: [SpeakerSpan]
    ) -> [TaggedSegment] {
        let words = segment.wordTimings
        guard words.count >= 2, speakerSpans.count >= 2 else {
            // Can't split with fewer than 2 words or 2 speaker spans
            return [segment]
        }

        // For each word, determine which speaker span it belongs to.
        // Use the midpoint of the word's time range to decide.
        var wordSpeakers: [(word: WordTiming, speaker: String)] = []
        for word in words {
            let wordMid = (word.start + word.end) / 2.0
            // Find the span whose time range contains this word's midpoint
            let matchingSpan = speakerSpans.first { span in
                wordMid >= span.start - 0.1 && wordMid <= span.end + 0.1
            }
            // Fall back to the span with the nearest start if no direct containment
            let speaker = matchingSpan?.speaker ?? speakerSpans.min(by: {
                abs(($0.start + $0.end) / 2.0 - wordMid) < abs(($1.start + $1.end) / 2.0 - wordMid)
            })!.speaker
            wordSpeakers.append((word: word, speaker: speaker))
        }

        // Group consecutive words by speaker
        var groups: [(speaker: String, words: [WordTiming])] = []
        for (word, speaker) in wordSpeakers {
            if var last = groups.last, last.speaker == speaker {
                last.words.append(word)
                groups[groups.count - 1] = last
            } else {
                groups.append((speaker: speaker, words: [word]))
            }
        }

        // Don't split if all words ended up with the same speaker
        guard groups.count >= 2 else {
            var updated = segment
            updated.speaker = groups[0].speaker
            return [updated]
        }

        // Filter out groups with only whitespace/punctuation words
        let substantialGroups = groups.filter { group in
            let text = group.words.map(\.word).joined()
            return text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }
        guard substantialGroups.count >= 2 else {
            // After filtering, only one speaker has real content
            if let first = substantialGroups.first {
                var updated = segment
                updated.speaker = first.speaker
                return [updated]
            }
            return [segment]
        }

        // Build TaggedSegments from each group
        var result: [TaggedSegment] = []
        for group in groups {
            let text = group.words.map(\.word).joined()

            // Skip groups that are only whitespace/punctuation
            guard text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else {
                // Append text to the previous or next segment instead of dropping
                if var prev = result.last {
                    prev.text += text
                    prev.wordTimings += group.words
                    prev.end = max(prev.end, group.words.last?.end ?? prev.end)
                    result[result.count - 1] = prev
                }
                continue
            }

            let segStart = group.words.first?.start ?? segment.start
            let segEnd = group.words.last?.end ?? segment.end

            result.append(TaggedSegment(
                stream: segment.stream,
                speaker: group.speaker,
                start: segStart,
                end: segEnd,
                text: text.trimmingCharacters(in: .whitespaces),
                embedding: segment.embedding,
                isFinal: true,
                wordTimings: group.words
            ))
        }

        // Sanity check — if splitting produced empty results, return original
        return result.isEmpty ? [segment] : result
    }
}
