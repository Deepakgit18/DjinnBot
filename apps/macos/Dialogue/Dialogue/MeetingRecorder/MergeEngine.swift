import Combine
import Foundation
import OSLog

/// Timestamp-tracked unattributed ASR segment awaiting embedding-based resolution.
struct UnattributedEntry: Sendable {
    let asr: ASRSegment
    /// Wall-clock time when this entry was first added to the unattributed buffer.
    let addedAt: Date
}

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

    /// ASR finals that had no good diarization overlap and are waiting for
    /// diarization to catch up. Retried every merge cycle. Displayed as
    /// "Speaker-?" in the UI until resolved. Each entry tracks when it was
    /// first added so we can trigger embedding-based resolution after a delay.
    private var unattributedASR: [UnattributedEntry] = []

    /// One "live partial" per stream for immediate display while ASR refines.
    /// Replaced on every partial update, cleared when the final arrives.
    private var livePartials: [StreamType: ASRSegment] = [:]

    /// Debounce timer for batch merge operations.
    private var mergeTimer: Timer?
    private let mergeInterval: TimeInterval = 0.25

    /// Minimum temporal overlap (seconds) required between an ASR final and a
    /// diarization segment for the match to be accepted. Prevents
    /// misattribution from tiny sliver overlaps at segment boundaries.
    private let minOverlapThreshold: TimeInterval = 0.5

    /// Maximum gap (seconds) between an unattributed ASR segment and a
    /// neighbouring resolved segment for the adjacency fallback to apply.
    private let maxAdjacencyGap: TimeInterval = 2.0

    /// How long (seconds) an unattributed entry can wait for embedding
    /// extraction before falling through to overlap / adjacency.
    private let embeddingTimeoutDelay: TimeInterval = 10.0

    /// Registered per-stream diarization managers for embedding extraction.
    /// Set by `RealtimePipeline` during setup so MergeEngine can request
    /// on-demand embeddings from the ring buffer.
    @available(macOS 26.0, *)
    private var diarizationManagers: [StreamType: RealtimeDiarizationManager] = [:]

    /// Tracks which unattributed entries already have an in-flight embedding
    /// extraction task, to avoid duplicate requests.
    private var pendingExtractions: Set<TimeInterval> = []

    /// Stores completed embedding extraction results keyed by ASR start time.
    /// Consumed on the next merge cycle.
    private var completedEmbeddings: [TimeInterval: [Float]] = [:]

    /// Tracks extractions that failed so we don't retry them.
    private var failedExtractions: Set<TimeInterval> = []

    /// Minimum cosine similarity for embedding-based speaker matching.
    /// Configurable via Settings ("Embedding Match Threshold").
    private var embeddingMatchThreshold: Float {
        let v = UserDefaults.standard.float(forKey: "embeddingMatchThreshold")
        return v > 0 ? v : 0.40
    }

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

    // MARK: - Diarization Manager Registration

    /// Register a diarization manager for a stream so MergeEngine can request
    /// embedding extractions for unattributed segment resolution.
    @available(macOS 26.0, *)
    func registerDiarizationManager(_ manager: RealtimeDiarizationManager, for stream: StreamType) {
        diarizationManagers[stream] = manager
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
    ///
    /// Only active in **Sortformer** mode. In Pyannote mode, SpeakerManager
    /// handles identification natively via `initializeKnownSpeakers` — the
    /// embeddings it returns are the enrolled embeddings themselves, so
    /// running VoiceID on top would always yield 1.000 similarity (comparing
    /// a vector against itself) and mask SpeakerManager's actual quality.
    private func attemptVoiceIdentification(for segment: TaggedSegment) {
        let key = segment.speaker

        // In Pyannote mode, SpeakerManager already identifies known speakers
        // in-pipeline (Layer 1). VoiceID is only needed for Sortformer's
        // hybrid embedding extraction path.
        let modeRaw = UserDefaults.standard.string(forKey: "diarizationMode") ?? ""
        let mode = DiarizationMode(rawValue: modeRaw) ?? .pyannoteStreaming
        guard mode == .sortformer else { return }

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
    ///
    /// **Pyannote mode**: ASR finals with no diarization overlap are held in
    /// `unattributedASR` and retried every cycle until diarization catches up.
    /// They appear as "Speaker-?" in the UI until resolved. Pyannote timestamps
    /// are accurate but lag behind ASR by ~10s.
    ///
    /// **Sortformer mode**: Frame-based timestamps are unreliable (internal
    /// buffering offsets them from ASR wall-clock time). When no overlap is
    /// found, the nearest same-stream diarization segment's speaker is used
    /// immediately, since VoiceID has already resolved slot names.
    private func performMerge() {
        let modeRaw = UserDefaults.standard.string(forKey: "diarizationMode") ?? ""
        let currentMode = DiarizationMode(rawValue: modeRaw) ?? .pyannoteStreaming

        // 1a. Retry previously-unattributed ASR finals.
        //     Priority: embedding match → overlap → adjacency (after timeout).
        //     Embedding extraction is triggered immediately when an entry becomes
        //     unattributed. Results arrive asynchronously via completedEmbeddings.
        var stillUnattributed: [UnattributedEntry] = []
        for entry in unattributedASR {
            let age = Date().timeIntervalSince(entry.addedAt)
            let key = entry.asr.start

            // 1. Check for completed embedding — highest priority
            if let embedding = completedEmbeddings.removeValue(forKey: key) {
                if let speaker = matchEmbeddingToSpeaker(embedding, stream: entry.asr.stream) {
                    let asrS = String(format: "%.1f", entry.asr.start)
                    let asrE = String(format: "%.1f", entry.asr.end)
                    logger.info("[MERGE] \(entry.asr.stream.rawValue) [\(asrS)s-\(asrE)s] → '\(speaker.name)' (embedding similarity \(String(format: "%.3f", speaker.similarity))): \"\(entry.asr.text)\"")
                    let resolved = TaggedSegment(
                        stream: entry.asr.stream,
                        speaker: speaker.name,
                        start: entry.asr.start,
                        end: entry.asr.end,
                        text: entry.asr.text,
                        embedding: embedding,
                        isFinal: true
                    )
                    diarizationSegments.append(resolved)
                    continue
                }
                // Embedding extracted but no match above threshold — fall through
            }

            // 2. Check if extraction failed or timed out — fall to overlap / adjacency
            let extractionDone = failedExtractions.contains(key)
            let timedOut = age >= embeddingTimeoutDelay

            if extractionDone || timedOut {
                failedExtractions.remove(key)
                // Try overlap-based
                if let resolved = resolveASR(entry.asr) {
                    commitResolved(asr: entry.asr, match: resolved)
                } else {
                    // Adjacency fallback
                    let sameStream = diarizationSegments.filter {
                        $0.stream == entry.asr.stream && !$0.text.isEmpty
                    }
                    let asrStartTime = entry.asr.start
                    let asrEndTime = entry.asr.end
                    let preceding = sameStream
                        .filter { $0.end <= asrStartTime + 0.1 }
                        .max { (a: TaggedSegment, b: TaggedSegment) in a.end < b.end }
                    let following = sameStream
                        .filter { $0.start >= asrEndTime - 0.1 }
                        .min { (a: TaggedSegment, b: TaggedSegment) in a.start < b.start }
                    resolveViaAdjacency(asr: entry.asr, preceding: preceding, following: following)
                }
                continue
            }

            // 3. Extraction still pending — trigger if not already in flight
            if !pendingExtractions.contains(key) {
                triggerEmbeddingExtraction(for: entry)
            }
            stillUnattributed.append(entry)
        }
        unattributedASR = stillUnattributed

        // 1b. Process new ASR finals.
        var deferred: [ASRSegment] = []

        for asr in finalASRBuffer {
            let sameStreamDiar = diarizationSegments.filter { $0.stream == asr.stream }
            let asrStart = String(format: "%.1f", asr.start)
            let asrEnd = String(format: "%.1f", asr.end)
            let streamName = asr.stream.rawValue

            if sameStreamDiar.isEmpty {
                // No diarization segments yet for this stream. Diarization
                // may still be warming up (Pyannote needs a full 10s chunk).
                // Defer this ASR final for retry on the next merge cycle.
                deferred.append(asr)
                logger.info("[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] DEFERRED (no diar segs yet): \"\(asr.text)\"")
            } else if let resolved = resolveASR(asr) {
                commitResolved(asr: asr, match: resolved)
            } else if currentMode == .sortformer {
                // Sortformer timestamps don't correlate with ASR timestamps
                // (internal buffering, FIFO, frame offsets). Use the most
                // recent same-stream diarization segment's speaker, which
                // VoiceID has already resolved to an enrolled name if matched.
                let recentDiar = sameStreamDiar.max { $0.end < $1.end }
                let fallbackSpeaker = recentDiar?.speaker ?? "\(asr.stream.rawValue)-Unknown"
                let fallback = TaggedSegment(
                    stream: asr.stream,
                    speaker: fallbackSpeaker,
                    start: asr.start,
                    end: asr.end,
                    text: asr.text,
                    isFinal: true
                )
                diarizationSegments.append(fallback)
                logger.info("[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] → '\(fallbackSpeaker)' (Sortformer nearest): \"\(asr.text)\"")
            } else {
                // Pyannote mode: diarization exists for this stream but
                // doesn't cover this ASR time range yet. Hold as unattributed
                // ("Speaker-?") and immediately trigger embedding extraction.
                let entry = UnattributedEntry(asr: asr, addedAt: Date())
                unattributedASR.append(entry)
                triggerEmbeddingExtraction(for: entry)
                let diarCount = sameStreamDiar.count
                logger.info("[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] UNATTRIBUTED (\(diarCount) diar segs, extracting embedding): \"\(asr.text)\"")
            }
        }
        finalASRBuffer = deferred

        // 2. Build the output: collapsed diarization segments + unattributed + partials
        var output = collapseAdjacentSegments(diarizationSegments)

        // 3. Add unattributed ASR finals as "Speaker-?" rows so the user sees
        //    the text immediately even though speaker identity is pending.
        for entry in unattributedASR {
            let placeholder = TaggedSegment(
                stream: entry.asr.stream,
                speaker: "Speaker-?",
                start: entry.asr.start,
                end: entry.asr.end,
                text: entry.asr.text,
                isFinal: true
            )
            output.append(placeholder)
        }

        // 4. Append live partials as tentative rows at the end of the transcript.
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

        // 5. Sort: finals by start time, non-finals (live partials) always at the end.
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

    // MARK: - Embedding Extraction & Matching

    /// Trigger async embedding extraction for an unattributed entry.
    /// Results are stored in `completedEmbeddings` (or `failedExtractions`)
    /// and consumed on the next merge cycle.
    private func triggerEmbeddingExtraction(for entry: UnattributedEntry) {
        let key = entry.asr.start
        // Skip if already in flight or permanently failed (no manager available)
        guard !pendingExtractions.contains(key),
              !failedExtractions.contains(key) else { return }

        guard #available(macOS 26.0, *),
              let manager = diarizationManagers[entry.asr.stream] else {
            // No manager available — permanently failed, fall through on next cycle
            failedExtractions.insert(key)
            return
        }

        pendingExtractions.insert(key)
        let asr = entry.asr

        Task { @MainActor [weak self] in
            guard let self else { return }
            let embedding = await manager.extractEmbedding(
                startTime: asr.start,
                endTime: asr.end
            )
            self.pendingExtractions.remove(key)

            if embedding.isEmpty {
                // Don't mark as permanently failed — the ring buffer may not
                // have enough audio yet. The next merge cycle will re-trigger
                // extraction once more audio has accumulated.
                self.logger.info("[MERGE] Embedding extraction returned empty for \(asr.stream.rawValue) [\(String(format: "%.1f", asr.start))s-\(String(format: "%.1f", asr.end))s], will retry")
            } else {
                self.completedEmbeddings[key] = embedding
            }
            self.scheduleMerge()
        }
    }

    /// Match an embedding against ALL known speakers on the same stream.
    /// Returns the best speaker name and similarity, or nil if none exceed
    /// the configurable `embeddingMatchThreshold`.
    private func matchEmbeddingToSpeaker(
        _ embedding: [Float],
        stream: StreamType
    ) -> (name: String, similarity: Float)? {
        let threshold = embeddingMatchThreshold

        // Collect one representative embedding per unique speaker on this stream.
        var speakerEmbeddings: [String: [Float]] = [:]
        for seg in diarizationSegments where seg.stream == stream && !seg.embedding.isEmpty {
            if speakerEmbeddings[seg.speaker] == nil {
                speakerEmbeddings[seg.speaker] = seg.embedding
            }
        }

        var bestName: String?
        var bestSim: Float = -1
        for (speaker, emb) in speakerEmbeddings {
            let sim = cosineSimilarity(embedding, emb)
            if sim > bestSim {
                bestSim = sim
                bestName = speaker
            }
        }

        guard let name = bestName, bestSim >= threshold else { return nil }
        return (name: name, similarity: bestSim)
    }

    /// Adjacency fallback: attribute to the preceding segment's speaker if
    /// the temporal gap is small enough. Otherwise commit as "Speaker-?".
    private func resolveViaAdjacency(
        asr: ASRSegment,
        preceding: TaggedSegment?,
        following: TaggedSegment?
    ) {
        let asrStart = String(format: "%.1f", asr.start)
        let asrEnd = String(format: "%.1f", asr.end)
        let streamName = asr.stream.rawValue

        if let prev = preceding, (asr.start - prev.end) < maxAdjacencyGap {
            logger.info("[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] → '\(prev.speaker)' (adjacency, gap \(String(format: "%.1f", asr.start - prev.end))s): \"\(asr.text)\"")
            let fallback = TaggedSegment(
                stream: asr.stream,
                speaker: prev.speaker,
                start: asr.start,
                end: asr.end,
                text: asr.text,
                isFinal: true
            )
            diarizationSegments.append(fallback)
        } else if let next = following, (next.start - asr.end) < maxAdjacencyGap {
            logger.info("[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] → '\(next.speaker)' (adjacency-next, gap \(String(format: "%.1f", next.start - asr.end))s): \"\(asr.text)\"")
            let fallback = TaggedSegment(
                stream: asr.stream,
                speaker: next.speaker,
                start: asr.start,
                end: asr.end,
                text: asr.text,
                isFinal: true
            )
            diarizationSegments.append(fallback)
        } else {
            // Permanent Speaker-? — no adjacency match either
            logger.warning("[MERGE] \(streamName) [\(asrStart)s-\(asrEnd)s] → 'Speaker-?' (no adjacency match): \"\(asr.text)\"")
            let fallback = TaggedSegment(
                stream: asr.stream,
                speaker: "Speaker-?",
                start: asr.start,
                end: asr.end,
                text: asr.text,
                isFinal: true
            )
            diarizationSegments.append(fallback)
        }
    }

    /// Cosine similarity between two embedding vectors.
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA * normB)
        return denom > 1e-6 ? dot / denom : 0
    }

    // MARK: - Flush (end-of-recording)

    /// Resolve all remaining unattributed segments immediately.
    /// Called before saving the transcript when recording stops.
    ///
    /// Priority: completed embedding → overlap → adjacency → permanent Speaker-?
    func flushUnattributed() {
        for entry in unattributedASR {
            let key = entry.asr.start

            // Try completed embedding first
            if let embedding = completedEmbeddings.removeValue(forKey: key),
               let speaker = matchEmbeddingToSpeaker(embedding, stream: entry.asr.stream) {
                let asrS = String(format: "%.1f", entry.asr.start)
                let asrE = String(format: "%.1f", entry.asr.end)
                logger.info("[MERGE] \(entry.asr.stream.rawValue) [\(asrS)s-\(asrE)s] → '\(speaker.name)' (flush embedding \(String(format: "%.3f", speaker.similarity))): \"\(entry.asr.text)\"")
                let resolved = TaggedSegment(
                    stream: entry.asr.stream,
                    speaker: speaker.name,
                    start: entry.asr.start,
                    end: entry.asr.end,
                    text: entry.asr.text,
                    embedding: embedding,
                    isFinal: true
                )
                diarizationSegments.append(resolved)
            } else if let resolved = resolveASR(entry.asr) {
                // Try overlap-based
                commitResolved(asr: entry.asr, match: resolved)
            } else {
                // Adjacency fallback
                let sameStream = diarizationSegments.filter {
                    $0.stream == entry.asr.stream && !$0.text.isEmpty
                }
                let flushStart = entry.asr.start
                let flushEnd = entry.asr.end
                let preceding = sameStream
                    .filter { $0.end <= flushStart + 0.1 }
                    .max { (a: TaggedSegment, b: TaggedSegment) in a.end < b.end }
                let following = sameStream
                    .filter { $0.start >= flushEnd - 0.1 }
                    .min { (a: TaggedSegment, b: TaggedSegment) in a.start < b.start }
                resolveViaAdjacency(asr: entry.asr, preceding: preceding, following: following)
            }
        }
        unattributedASR.removeAll()
        pendingExtractions.removeAll()
        completedEmbeddings.removeAll()
        failedExtractions.removeAll()

        // Rebuild output
        performMerge()
    }

    // MARK: - ASR Resolution Helpers

    /// Try to find a diarization segment that overlaps this ASR final with
    /// sufficient overlap. Returns the index and matched segment, or nil
    /// if no good match exists yet.
    private func resolveASR(_ asr: ASRSegment) -> (index: Int, segment: TaggedSegment)? {
        // Only consider same-stream diarization segments.
        let candidates = diarizationSegments.enumerated().filter {
            $0.element.stream == asr.stream && overlapDuration($0.element, asr) >= minOverlapThreshold
        }

        guard let best = candidates.max(by: { a, b in
            overlapDuration(a.element, asr) < overlapDuration(b.element, asr)
        }) else { return nil }

        return (index: best.offset, segment: best.element)
    }

    /// Commit a resolved ASR final into the diarization segments store.
    private func commitResolved(asr: ASRSegment, match: (index: Int, segment: TaggedSegment)) {
        let (index, matched) = match
        let asrStart = String(format: "%.1f", asr.start)
        let asrEnd = String(format: "%.1f", asr.end)
        let overlap = String(format: "%.2f", overlapDuration(matched, asr))
        let ms = String(format: "%.1f", matched.start)
        let me = String(format: "%.1f", matched.end)
        let streamName = asr.stream.rawValue
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
        unattributedASR.removeAll()
        pendingExtractions.removeAll()
        completedEmbeddings.removeAll()
        failedExtractions.removeAll()
        livePartials.removeAll()
        mergedSegments.removeAll()
        speakerRenames.removeAll()
        identifiedSpeakers.removeAll()
        speakerDurations.removeAll()
        if #available(macOS 26.0, *) {
            diarizationManagers.removeAll()
        }
    }
}
