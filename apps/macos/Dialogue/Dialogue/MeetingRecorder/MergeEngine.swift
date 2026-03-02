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
/// ## Speaker Identification
///
/// Speaker identification is fully delegated to `VoiceID`. When a diarization
/// segment carries an embedding, `VoiceID.identifySpeaker(fromEmbedding:)` is
/// called to resolve auto-generated labels to enrolled user IDs. The merge
/// engine itself performs no embedding math — it only tracks renames so that
/// previously-emitted segments are updated retroactively.
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

    /// Debounce timer for batch merge operations.
    private var mergeTimer: Timer?
    private let mergeInterval: TimeInterval = 0.25

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "MergeEngine")

    // MARK: - VoiceID Speaker Renames

    /// Speaker label renames discovered via VoiceID matching.
    /// Key: original auto-generated label, Value: resolved enrolled user ID.
    private var speakerRenames: [String: String] = [:]

    /// Tracks which auto-generated speaker labels have already been identified
    /// (or attempted) via VoiceID, to avoid redundant identification calls.
    private var identifiedSpeakers: Set<String> = []

    /// Minimum accumulated speech duration (seconds) before attempting
    /// VoiceID identification for a speaker. Ensures enough audio context
    /// for a reliable match.
    private let minDurationForIdentification: TimeInterval = 3.0

    /// Per-speaker accumulated speech duration for progressive identification.
    private var speakerDurations: [String: TimeInterval] = [:]

    private init() {}

    // MARK: - Ingestion

    /// Add a diarization segment (from RealtimeDiarizationManager).
    func add(_ segment: TaggedSegment) {
        // Apply any known renames
        var seg = segment
        if let rename = speakerRenames[seg.speaker] {
            seg.speaker = rename
        }

        diarizationSegments.append(seg)

        // Accumulate duration and attempt VoiceID identification
        attemptVoiceIdentification(for: segment)

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

    // MARK: - VoiceID Identification

    /// Accumulate speech duration for a speaker and attempt identification
    /// once enough audio has been collected.
    private func attemptVoiceIdentification(for segment: TaggedSegment) {
        let key = segment.speaker

        // Skip if already identified or if VoiceID has no enrolled voices
        guard !identifiedSpeakers.contains(key),
              VoiceID.shared.hasEnrolledVoices else { return }

        // Accumulate duration
        speakerDurations[key, default: 0] += segment.duration

        // Wait until enough speech has accumulated
        guard speakerDurations[key, default: 0] >= minDurationForIdentification else { return }

        // Only attempt identification when the segment carries an embedding.
        // In Sortformer mode, embeddings arrive asynchronously after ~3s of
        // accumulated speech — earlier segments won't have them yet.
        // Don't mark as identified until we actually have an embedding to try.
        guard !segment.embedding.isEmpty else { return }

        // Mark as attempted (even if no match, to avoid retrying every segment)
        identifiedSpeakers.insert(key)

        let (userID, similarity) = VoiceID.shared.identifySpeaker(fromEmbedding: segment.embedding)

        if let userID {
            speakerRenames[key] = userID
            renameSpeaker(from: key, to: userID)
            let sim = String(format: "%.3f", similarity)
            logger.info("VoiceID: '\(key)' → '\(userID)' (similarity \(sim))")
        } else {
            let sim = String(format: "%.3f", similarity)
            logger.info("VoiceID: '\(key)' unrecognised (best similarity \(sim))")
        }
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
    private func performMerge() {
        // 1. Merge finalized ASR results into diarization segments.
        //    ASR finals that arrive before any diarization segments exist
        //    are kept in the buffer for retry on the next merge cycle.
        var deferred: [ASRSegment] = []

        for asr in finalASRBuffer {
            // Find all diarization segments that overlap this ASR result
            let candidates = diarizationSegments.enumerated().filter {
                overlapDuration($0.element, asr) > 0 && $0.element.stream == asr.stream
            }

            let bestMatch = candidates.max { a, b in
                overlapDuration(a.element, asr) < overlapDuration(b.element, asr)
            }

            let asrStart = String(format: "%.1f", asr.start)
            let asrEnd = String(format: "%.1f", asr.end)
            let streamName = asr.stream.rawValue

            if let (index, matched) = bestMatch {
                let overlap = String(format: "%.2f", overlapDuration(matched, asr))
                let ms = String(format: "%.1f", matched.start)
                let me = String(format: "%.1f", matched.end)
                let msg = "[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] → \(matched.speaker) [\(ms)s-\(me)s] overlap=\(overlap)s: \"\(asr.text)\""
                logger.info("\(msg)")

                if diarizationSegments[index].text.isEmpty {
                    // First ASR final for this diarization segment — write in place.
                    diarizationSegments[index].text = asr.text
                    diarizationSegments[index].isFinal = true
                } else {
                    // Diarization segment already has text from a previous ASR final.
                    // Create a new segment so each ASR final gets its own output row.
                    let extra = TaggedSegment(
                        stream: asr.stream,
                        speaker: matched.speaker,
                        start: asr.start,
                        end: asr.end,
                        text: asr.text,
                        embedding: matched.embedding,
                        isFinal: true
                    )
                    diarizationSegments.append(extra)
                }
            } else {
                let sameStreamDiar = diarizationSegments.filter { $0.stream == asr.stream }
                let diarCount = sameStreamDiar.count
                let asrStartTime = asr.start
                let nearestDiar = sameStreamDiar.min { (a: TaggedSegment, b: TaggedSegment) -> Bool in
                    abs(a.start - asrStartTime) < abs(b.start - asrStartTime)
                }

                if diarCount == 0 {
                    // No diarization segments yet for this stream. Diarization
                    // may still be warming up (Pyannote needs a full 10s chunk).
                    // Defer this ASR final for retry on the next merge cycle.
                    deferred.append(asr)
                    logger.info("[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] DEFERRED (no diar segs yet): \"\(asr.text)\"")
                } else {
                    // Fallback: use the nearest diarization segment's speaker if
                    // available, so that VoiceID renames carry through even when
                    // timestamps don't perfectly overlap.
                    let fallbackSpeaker: String
                    if let nearest = nearestDiar {
                        fallbackSpeaker = nearest.speaker
                        let ns = String(format: "%.1f", nearest.start)
                        let ne = String(format: "%.1f", nearest.end)
                        logger.warning("[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] NO OVERLAP (\(diarCount) diar segs, nearest: [\(ns)s-\(ne)s]) → using '\(fallbackSpeaker)': \"\(asr.text)\"")
                    } else {
                        fallbackSpeaker = "\(asr.stream.rawValue)-Unknown"
                        logger.warning("[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] NO DIAR SEGS: \"\(asr.text)\"")
                    }
                    let fallback = TaggedSegment(
                        stream: asr.stream,
                        speaker: fallbackSpeaker,
                        start: asr.start,
                        end: asr.end,
                        text: asr.text,
                        isFinal: true
                    )
                    diarizationSegments.append(fallback)
                }
            }
        }
        finalASRBuffer = deferred

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
        //    Hide diarization-only segments (no text) and noise-only segments
        //    (whitespace / stray punctuation from ASR picking up background noise).
        let withText = output.filter { $0.hasSubstantialContent }
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

    /// Reset all state (call when starting a new recording).
    func reset() {
        mergeTimer?.invalidate()
        mergeTimer = nil
        diarizationSegments.removeAll()
        finalASRBuffer.removeAll()
        livePartials.removeAll()
        mergedSegments.removeAll()
        speakerRenames.removeAll()
        identifiedSpeakers.removeAll()
        speakerDurations.removeAll()
    }
}
