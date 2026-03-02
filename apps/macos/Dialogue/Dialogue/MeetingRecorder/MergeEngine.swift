import Combine
import Foundation
import OSLog

/// Merges ASR transcript segments and diarization speaker segments from
/// both mic and meeting streams onto a single shared audio timeline.
///
/// ## Merge Strategy
///
/// **Diarization** produces segments with speaker labels and time ranges (no text).
/// **ASR** produces segments with text and time ranges (no speaker).
///
/// Progressive transcription emits many **partial** results (broad time range,
/// text still being refined) before a **final** result (precise time range).
///
/// - Partials: update a single "live" slot per stream for immediate UI feedback.
/// - Finals:  matched to the best-overlapping diarization segment by time,
///            giving us speaker-attributed text.
///
/// ## Speaker Profile Matching
///
/// When running in Pyannote mode, diarization segments carry 256-d embeddings.
/// The merge engine accumulates per-speaker embeddings in `SpeakerChunkBuffer`.
/// Once a speaker has accumulated >= 3 seconds of speech, the averaged embedding
/// is compared against cached profiles (`CachedSpeakerProfile`) loaded at
/// recording start. A match above `profileMatchThreshold` renames the speaker
/// in all existing and future segments.
///
/// The output `mergedSegments` is sorted by start time for the UI.
@MainActor
final class MergeEngine: ObservableObject {

    static let shared = MergeEngine()

    // MARK: - Published Output

    /// The merged transcript: diarized + transcribed segments sorted by time.
    @Published var mergedSegments: [TaggedSegment] = []

    // MARK: - Internal State

    /// Committed diarization segments (speaker labels, may have text from finals).
    private var diarizationSegments: [TaggedSegment] = []

    /// Finalized ASR segments waiting to be merged with diarization.
    private var finalASRBuffer: [ASRSegment] = []

    /// One "live partial" per stream for immediate display while ASR refines.
    /// Replaced on every partial update, cleared when the final arrives.
    private var livePartials: [StreamType: ASRSegment] = [:]

    /// ASR segments that haven't matched any diarization segment yet.
    /// Re-tried on every merge cycle as new diarization segments arrive.
    private var pendingASR: [ASRSegment] = []

    /// Debounce timer for batch merge operations.
    private var mergeTimer: Timer?
    private let mergeInterval: TimeInterval = 0.25

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "MergeEngine")

    // MARK: - Speaker Profile Matching

    /// Per-speaker embedding accumulation buffers for progressive profile matching.
    private var speakerBuffers: [String: SpeakerChunkBuffer] = [:]

    /// Cached profiles loaded at recording start for synchronous matching.
    private var cachedProfiles: [CachedSpeakerProfile] = []

    /// Speaker label renames discovered via profile matching.
    /// Key: original auto-generated label, Value: resolved profile name.
    private var speakerRenames: [String: String] = [:]

    /// Cosine similarity threshold for matching a speaker to a cached profile.
    /// Range 0.65–0.72 recommended (GettingStarted.md).
    private let profileMatchThreshold: Float = 0.68

    private init() {}

    // MARK: - Configuration

    /// Load cached speaker profiles for in-memory matching during recording.
    ///
    /// Call this at recording start from the controller, after loading
    /// profiles from `SpeakerProfileStore`.
    func setCachedProfiles(_ profiles: [CachedSpeakerProfile]) {
        cachedProfiles = profiles
        logger.info("Loaded \(profiles.count) cached speaker profiles for matching")
    }

    // MARK: - Ingestion

    /// Add a diarization segment (from RealtimeDiarizationManager).
    func add(_ segment: TaggedSegment) {
        // Apply any known renames
        var seg = segment
        if let rename = speakerRenames[seg.speaker] {
            seg.speaker = rename
        }

        diarizationSegments.append(seg)

        // Update speaker embedding buffer for progressive matching
        updateSpeakerBuffer(for: segment)

        scheduleMerge()
    }

    /// Add an ASR result (from RealtimeTranscriptionManager).
    ///
    /// Partials update the live slot for that stream.
    /// Finals are buffered for merge with diarization.
    func addASR(_ segment: ASRSegment) {
        if segment.isFinal {
            // Final result: precise timestamps, ready to merge with diarization.
            finalASRBuffer.append(segment)
            // Clear the live partial for this stream since it's been finalized.
            livePartials.removeValue(forKey: segment.stream)
        } else {
            // Partial: replace the live slot (only the latest partial matters).
            livePartials[segment.stream] = segment
        }
        scheduleMerge()
    }

    // MARK: - Speaker Buffer Accumulation

    /// Track per-speaker embedding accumulation for progressive profile matching.
    private func updateSpeakerBuffer(for segment: TaggedSegment) {
        // Only accumulate when we have embeddings (Pyannote mode) and cached profiles
        guard !segment.embedding.isEmpty, !cachedProfiles.isEmpty else { return }

        let key = segment.speaker
        var buffer = speakerBuffers[key] ?? SpeakerChunkBuffer()

        buffer.totalDuration += segment.duration

        // Average the new embedding with the cumulative one
        buffer.cumulativeEmbedding = Self.averageEmbeddings(
            buffer.cumulativeEmbedding,
            segment.embedding
        )
        buffer.embeddingCount += 1

        // When enough speech accumulated and not yet matched, attempt profile matching
        if buffer.totalDuration >= 3.0, !buffer.hasMatched, let avgEmb = buffer.cumulativeEmbedding {
            if let matchedName = matchAgainstCachedProfiles(embedding: avgEmb) {
                buffer.hasMatched = true
                speakerRenames[key] = matchedName
                // Retroactively rename all existing segments for this speaker
                renameSpeaker(from: key, to: matchedName)
                logger.info("Speaker '\(key)' matched to profile '\(matchedName)'")
            }
        }

        speakerBuffers[key] = buffer
    }

    /// Compare an embedding against all cached profiles and return the best match name.
    private func matchAgainstCachedProfiles(embedding: [Float]) -> String? {
        var bestScore: Float = profileMatchThreshold
        var bestName: String?

        for profile in cachedProfiles {
            let score = Self.cosineSimilarity(embedding, profile.embedding)
            if score > bestScore {
                bestScore = score
                bestName = profile.name
            }
        }

        return bestName
    }

    /// Rename all existing segments from one speaker label to another.
    private func renameSpeaker(from oldName: String, to newName: String) {
        for i in diarizationSegments.indices where diarizationSegments[i].speaker == oldName {
            diarizationSegments[i].speaker = newName
        }
        // Force re-merge to update the published output
        scheduleMerge()
    }

    // MARK: - Merge Logic

    private func scheduleMerge() {
        mergeTimer?.invalidate()
        mergeTimer = Timer.scheduledTimer(withTimeInterval: mergeInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.performMerge()
            }
        }
    }

    /// Match finalized ASR text to diarization segments by temporal overlap,
    /// then append live partials at the end.
    ///
    /// ASR typically runs ahead of diarization (lower latency). When no diarization
    /// segment overlaps an ASR result, it goes to `pendingASR` and is re-tried on
    /// every subsequent merge cycle as new diarization segments arrive.
    /// After 30 seconds with no match, a fallback "Unknown" attribution is used.
    private func performMerge() {
        // Combine new finals with previously unmatched ASR for re-try.
        // Sort by start time so earlier ASR claims earlier diar segments first.
        let allASR = (pendingASR + finalASRBuffer).sorted { $0.start < $1.start }
        finalASRBuffer.removeAll()
        pendingASR.removeAll()

        let maxPendingAge: TimeInterval = 30 // seconds before giving up

        // Track which diar indices have already been claimed by an ASR this cycle.
        // Each diar segment should only be matched by ONE ASR segment to prevent
        // text overwriting (e.g., two ASR segments both best-matching the same diar).
        var claimedIndices = Set<Int>()

        for asr in allASR {
            // Find overlapping diar segments that haven't been claimed yet
            let candidates = diarizationSegments.enumerated().filter {
                overlapDuration($0.element, asr) > 0
                    && $0.element.stream == asr.stream
                    && !claimedIndices.contains($0.offset)
            }

            let bestMatch = candidates.max { a, b in
                overlapDuration(a.element, asr) < overlapDuration(b.element, asr)
            }

            let asrStart = String(format: "%.1f", asr.start)
            let asrEnd = String(format: "%.1f", asr.end)
            let streamName = asr.stream.rawValue

            if let (index, matched) = bestMatch {
                claimedIndices.insert(index)
                let overlap = String(format: "%.2f", overlapDuration(matched, asr))
                let ms = String(format: "%.1f", matched.start)
                let me = String(format: "%.1f", matched.end)
                let msg = "[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] → \(matched.speaker) [\(ms)s-\(me)s] overlap=\(overlap)s: \"\(asr.text)\""
                logger.info("\(msg)")

                // Append text (don't overwrite) — handles edge case where
                // a previous cycle already set text on this segment.
                if diarizationSegments[index].text.isEmpty {
                    diarizationSegments[index].text = asr.text
                } else {
                    diarizationSegments[index].text += " " + asr.text
                }
                diarizationSegments[index].isFinal = true
            } else {
                // No overlapping unclaimed diar segment found.
                // Check if diarization has caught up to this ASR's time range.
                let sameStreamDiar = diarizationSegments.filter { $0.stream == asr.stream }
                let latestDiarEnd = sameStreamDiar.map(\.end).max() ?? 0

                if latestDiarEnd > asr.end + maxPendingAge {
                    // Diarization has moved far past this ASR — give up, use fallback.
                    // Attribute to the nearest diar speaker if possible.
                    let nearest = sameStreamDiar.min { abs($0.start - asr.start) < abs($1.start - asr.start) }
                    let speaker = nearest?.speaker ?? "\(asr.stream.rawValue)-Unknown"

                    logger.warning("[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] FALLBACK → \(speaker): \"\(asr.text)\"")
                    let fallback = TaggedSegment(
                        stream: asr.stream,
                        speaker: speaker,
                        start: asr.start,
                        end: asr.end,
                        text: asr.text,
                        isFinal: true
                    )
                    diarizationSegments.append(fallback)
                } else {
                    // Diarization hasn't caught up yet — keep for re-try
                    pendingASR.append(asr)
                }
            }
        }

        // 2. Build the output: collapsed diarization segments + live partials
        var output = collapseAdjacentSegments(diarizationSegments)

        // 3. Append live partials as tentative rows at the end of the transcript.
        //    These show what the recognizer is currently hearing, attributed to
        //    the best-matching diarization speaker if possible.
        for (partialStream, partial) in livePartials {
            // Try to find a recent diarization segment to attribute the partial to
            let streamDiarSegs = diarizationSegments.filter { $0.stream == partialStream }
            let recentDiar = streamDiarSegs.max { $0.end < $1.end }

            let speaker = recentDiar?.speaker ?? "\(partialStream.rawValue)-..."
            let partialSegment = TaggedSegment(
                stream: partialStream,
                speaker: speaker,
                start: partial.start,
                end: partial.end,
                text: partial.text,
                isFinal: false
            )
            output.append(partialSegment)
        }

        // 4. Sort: finals by start time, non-finals (live partials) always at the end.
        //    Partials have start=0.0 from progressive transcription, so sorting by
        //    start would put them at the top. Using end time for partials places them
        //    at the current position in the transcript.
        //    Hide diarization-only segments (no text) to avoid empty "..." rows.
        let withText = output.filter { !$0.text.isEmpty }
        let finals = withText.filter { $0.isFinal }.sorted { $0.start < $1.start }
        let partials = withText.filter { !$0.isFinal }.sorted { $0.end < $1.end }
        mergedSegments = finals + partials
    }

    /// Collapse adjacent segments from the same speaker within a gap threshold.
    private func collapseAdjacentSegments(_ segments: [TaggedSegment]) -> [TaggedSegment] {
        let sorted = segments.sorted { $0.start < $1.start }
        var result: [TaggedSegment] = []
        let maxGap: TimeInterval = 1.5 // seconds

        for segment in sorted {
            if var last = result.last,
               last.speaker == segment.speaker,
               last.stream == segment.stream,
               segment.start - last.end < maxGap {
                // Merge into the previous segment
                last.end = max(last.end, segment.end)
                if !segment.text.isEmpty {
                    if last.text.isEmpty {
                        last.text = segment.text
                    } else {
                        last.text += " " + segment.text
                    }
                }
                last.isFinal = segment.isFinal
                result[result.count - 1] = last
            } else {
                result.append(segment)
            }
        }

        return result
    }

    // MARK: - Helpers

    /// Compute the temporal overlap between a diarization segment and an ASR segment.
    private func overlapDuration(_ diar: TaggedSegment, _ asr: ASRSegment) -> TimeInterval {
        let overlapStart = max(diar.start, asr.start)
        let overlapEnd = min(diar.end, asr.end)
        return max(0, overlapEnd - overlapStart)
    }

    /// Cosine similarity between two embedding vectors.
    ///
    /// Returns a value in [-1, 1] where 1 = identical direction.
    /// Assumes L2-normalised 256-d WeSpeaker embeddings.
    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var magA: Float = 0
        var magB: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            magA += a[i] * a[i]
            magB += b[i] * b[i]
        }
        let denom = sqrt(magA) * sqrt(magB)
        return denom > 0 ? dot / denom : 0
    }

    /// Average two embeddings using exponential weighting (50/50).
    ///
    /// If `existing` is nil, returns `new` directly. This naturally gives
    /// exponentially decaying weight to older embeddings, which is desirable
    /// for speaker matching as recent speech is more representative.
    private static func averageEmbeddings(_ existing: [Float]?, _ new: [Float]) -> [Float] {
        guard let existing, existing.count == new.count else { return new }
        return zip(existing, new).map { ($0 + $1) / 2.0 }
    }

    /// Reset all state (call when starting a new recording).
    func reset() {
        mergeTimer?.invalidate()
        mergeTimer = nil
        diarizationSegments.removeAll()
        finalASRBuffer.removeAll()
        pendingASR.removeAll()
        livePartials.removeAll()
        mergedSegments.removeAll()
        speakerBuffers.removeAll()
        speakerRenames.removeAll()
        // Note: cachedProfiles are NOT cleared here — they persist until
        // the next recording's setCachedProfiles() call.
    }
}

// MARK: - Speaker Chunk Buffer

/// Tracks cumulative embedding and speech duration for a single speaker.
///
/// Used by `MergeEngine` for progressive profile matching: once a speaker
/// has >= 3 seconds of speech with embeddings, we compare the averaged
/// embedding against cached profiles to resolve their identity.
private struct SpeakerChunkBuffer {
    /// Running average of all embeddings received for this speaker.
    var cumulativeEmbedding: [Float]?

    /// Number of embeddings that have been averaged.
    var embeddingCount: Int = 0

    /// Total speech duration in seconds across all segments.
    var totalDuration: TimeInterval = 0

    /// Whether this speaker has already been matched to a profile.
    /// Once matched, no further matching attempts are made.
    var hasMatched: Bool = false
}
