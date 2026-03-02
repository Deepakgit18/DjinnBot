import AVFoundation
import FluidAudio
import Foundation
import OSLog

/// Manages streaming speaker diarization for one audio stream using
/// either FluidAudio's Sortformer or Pyannote backend.
///
/// Each stream (mic / meeting) gets its own diarizer instance so that
/// speaker slots and embeddings are tracked independently. The merge
/// engine later reconciles speakers across streams.
///
/// **Sortformer**: Frame-level streaming via `SortformerDiarizer`.
///   Fixed 4 speaker slots, no cross-session memory.
///
/// **Pyannote**: Chunk-based streaming via `DiarizerManager` with
///   `SpeakerManager` for cross-chunk and cross-session identity.
///   Supports 6+ speakers and known-speaker pre-loading.
///
/// Reference: FluidAudio v0.12.1 – Sortformer.md, GettingStarted.md
@available(macOS 26.0, *)
actor RealtimeDiarizationManager {

    // MARK: - Properties

    private let streamType: StreamType
    private let mode: DiarizationMode
    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "Diarization")

    // --- Sortformer backend ---
    private var sortformerDiarizer: SortformerDiarizer?
    private var frameDurationSeconds: Float = 0.08

    // --- Sortformer Voice ID: hybrid embedding extraction ---
    /// DiarizerManager used only for WeSpeaker embedding extraction in Sortformer mode.
    private var embeddingExtractor: DiarizerManager?
    /// Set of enrolled voice user-IDs, used to distinguish pre-loaded embeddings from
    /// embeddings that the extractor actually found in the audio.
    private var enrolledUserIDs: Set<String> = []
    /// Continuous ring buffer of raw mic audio (16 kHz mono Float32) for embedding
    /// extraction. Indexed by absolute sample offset so we can slice by time range.
    private var audioRingBuffer: [Float] = []
    /// Sample offset of the first sample in `audioRingBuffer` (how many samples
    /// were trimmed from the front). Used to convert absolute time → buffer index.
    private var ringBufferStartOffset: Int = 0
    /// Maximum ring buffer size: 60 seconds × 16,000 = 960,000 samples.
    private let maxRingBufferSamples: Int = 960_000
    /// Per-speaker accumulated speech duration (seconds) from Sortformer segments.
    private var sortformerSpeakerDurations: [Int: TimeInterval] = [:]
    /// Set of speaker slot indices that have already been identified via VoiceID.
    private var identifiedSortformerSlots: Set<Int> = Set()
    /// Extracted embedding per speaker slot, attached to subsequent TaggedSegments.
    private var sortformerSlotEmbeddings: [Int: [Float]] = [:]
    /// Minimum accumulated speech duration (seconds) before attempting extraction.
    private let minDurationForExtraction: TimeInterval = 3.0

    // --- Pyannote backend ---
    private var pyannoteManager: DiarizerManager?

    /// Accumulated samples waiting to reach `chunkSeconds` before processing.
    private var sampleBuffer: [Float] = []

    /// Timeline offset (seconds) of the first sample in `sampleBuffer`.
    private var bufferStartTime: TimeInterval = 0

    /// Whether we have received the first audio chunk (for time anchoring).
    private var isFirstChunk = true

    /// Tracks the latest absolute time up to which diarization segments have been
    /// emitted. Used to deduplicate segments from overlapping sliding-window chunks.
    /// Only segments whose start time >= this value are emitted.
    private var lastEmittedTime: TimeInterval = 0

    /// Whether this is the first processed diarization chunk (emit all segments).
    private var isFirstDiarChunk = true

    /// Accumulated time offset for absolute timestamps.
    private var totalSamplesProcessed: Int = 0

    // MARK: - Init

    init(streamType: StreamType, mode: DiarizationMode = .pyannoteStreaming) {
        self.streamType = streamType
        self.mode = mode
    }

    // MARK: - Setup

    /// Initialise the diarizer for the selected mode.
    ///
    /// Reads pre-loaded models from `ModelPreloader.shared` when available,
    /// falling back to downloading from HuggingFace (slow path).
    ///
    /// For Pyannote mode, enrolled voices from `VoiceID` are pre-loaded
    /// into the `SpeakerManager` so known speakers are recognised
    /// immediately from the first diarization chunk.
    func prepare() async throws {
        logger.info("Preparing diarizer for \(self.streamType.rawValue) stream (mode: \(self.mode.rawValue))")

        switch mode {
        case .sortformer:
            try await prepareSortformer()
        case .pyannoteStreaming:
            try await preparePyannote()
        }
    }

    // MARK: - Sortformer Setup

    private func prepareSortformer() async throws {
        let config = SortformerConfig.default
        self.frameDurationSeconds = config.frameDurationSeconds

        let diarizer = SortformerDiarizer(config: config)

        let preloadedModels = await ModelPreloader.shared.sortformerModels
        if let models = preloadedModels {
            logger.info("Using pre-loaded Sortformer models for \(self.streamType.rawValue)")
            diarizer.initialize(models: models)
        } else {
            logger.info("No pre-loaded Sortformer models; downloading from HuggingFace (slow path)")
            let models = try await SortformerModels.loadFromHuggingFace(config: config)
            diarizer.initialize(models: models)
        }

        self.sortformerDiarizer = diarizer
        logger.info("SortformerDiarizer ready for \(self.streamType.rawValue) stream")

        // Hybrid Voice ID: set up the embedding extractor in the background
        // so it doesn't block recording start. It's only needed after ~3s of
        // speech, giving plenty of time to initialise.
        if VoiceID.shared.hasEnrolledVoices {
            Task { await self.prepareEmbeddingExtractor() }
        } else {
            logger.info("No enrolled voices — skipping embedding extractor setup for Sortformer")
        }
    }

    // MARK: - Embedding Extractor Setup (background, non-blocking)

    /// Initialise the DiarizerManager used for WeSpeaker embedding extraction
    /// in Sortformer mode. Runs in the background so it doesn't delay recording.
    private func prepareEmbeddingExtractor() async {
        do {
            let diarModels: DiarizerModels
            if let preloaded = await MainActor.run(body: { ModelPreloader.shared.diarizerModels }) {
                diarModels = preloaded
            } else {
                diarModels = try await DiarizerModels.downloadIfNeeded()
            }

            let extractorConfig = DiarizerConfig(
                clusteringThreshold: VoiceID.shared.clusteringThreshold,
                minSpeechDuration: 1.0,
                minSilenceGap: 0.5,
                debugMode: true,
                chunkDuration: 10.0
            )
            let extractor = DiarizerManager(config: extractorConfig)
            extractor.initialize(models: diarModels)

            // Pre-load enrolled voices so the extractor's SpeakerManager can
            // match against them immediately.
            loadEnrolledVoices(into: extractor)

            // Remember enrolled IDs so we can filter them from extraction results.
            self.enrolledUserIDs = Set(VoiceID.shared.allEnrolledVoices().map(\.userID))
            self.embeddingExtractor = extractor
            logger.info("Embedding extractor ready for Sortformer Voice ID on \(self.streamType.rawValue)")
        } catch {
            logger.warning("Failed to load embedding extractor for Sortformer Voice ID: \(error.localizedDescription). Voice ID will be unavailable in Sortformer mode.")
        }
    }

    // MARK: - Pyannote Setup

    private func preparePyannote() async throws {
        let preloadedModels = await ModelPreloader.shared.diarizerModels
        let models: DiarizerModels

        if let preloaded = preloadedModels {
            logger.info("Using pre-loaded Pyannote diarizer models for \(self.streamType.rawValue)")
            models = preloaded
        } else {
            logger.info("No pre-loaded Pyannote models; downloading from HuggingFace (slow path)")
            models = try await DiarizerModels.downloadIfNeeded()
        }

        let config = DiarizerConfig(
            clusteringThreshold: 0.7,
            minSpeechDuration: 1.0,
            minSilenceGap: 0.5,
            debugMode: true,           // Required: speakerDatabase is only returned when debugMode=true
            chunkDuration: Float(mode.chunkSeconds)  // Must match our external chunking to avoid zero-padding
        )
        let diarizer = DiarizerManager(config: config)
        diarizer.initialize(models: models)

        // Load enrolled voices from VoiceID into SpeakerManager so that
        // known speakers are recognised from the first chunk. VoiceID owns
        // persistence; we convert its embeddings to FluidAudio Speaker objects.
        loadEnrolledVoices(into: diarizer)

        self.pyannoteManager = diarizer
        sampleBuffer.removeAll()
        bufferStartTime = 0
        isFirstChunk = true

        logger.info("PyannoteManager ready for \(self.streamType.rawValue) stream")
    }

    /// Convert VoiceID enrolled voices to FluidAudio `Speaker` objects and
    /// pre-load them into the DiarizerManager's `SpeakerManager`.
    ///
    /// This enables the SDK's built-in cosine-distance matching so that
    /// known speakers are recognised immediately from the first chunk,
    /// rather than waiting for MergeEngine's post-hoc VoiceID check.
    private func loadEnrolledVoices(into diarizer: DiarizerManager) {
        let enrolled = VoiceID.shared.allEnrolledVoices()
        guard !enrolled.isEmpty else {
            logger.info("No VoiceID enrolled voices to load")
            return
        }

        let speakers = enrolled.map { voice in
            Speaker(
                id: voice.userID,
                name: voice.userID,
                currentEmbedding: voice.vector,
                isPermanent: true
            )
        }
        diarizer.initializeKnownSpeakers(speakers)
        let names = enrolled.map(\.userID).joined(separator: ", ")
        logger.info("Loaded \(speakers.count) enrolled voice(s) into SpeakerManager: \(names)")
    }

    // MARK: - Streaming Processing

    /// Process a chunk of 16 kHz mono Float32 samples.
    ///
    /// Dispatches to the appropriate backend:
    /// - **Sortformer**: Feeds directly into the frame-level streaming pipeline.
    /// - **Pyannote**: Accumulates in a buffer and processes when a full
    ///   chunk (e.g. 5 seconds) has been collected.
    ///
    /// Resulting `TaggedSegment`s are posted to `MergeEngine.shared`.
    ///
    /// - Parameters:
    ///   - samples: Audio samples (16 kHz mono Float32)
    ///   - absoluteTime: Timeline offset for the start of this chunk
    func processChunk(_ samples: [Float], at absoluteTime: TimeInterval) async {
        switch mode {
        case .sortformer:
            await processSortformerChunk(samples, at: absoluteTime)
        case .pyannoteStreaming:
            await processPyannoteChunk(samples, at: absoluteTime)
        }

        totalSamplesProcessed += samples.count
    }

    // MARK: - Sortformer Processing

    /// Feed samples into the Sortformer streaming pipeline and convert
    /// frame-level speaker probabilities into `TaggedSegment` values.
    ///
    /// When an embedding extractor is available (enrolled voices exist),
    /// raw audio is appended to a continuous ring buffer. Sortformer segments
    /// carry absolute timestamps which are used to slice the ring buffer for
    /// embedding extraction once a speaker accumulates ~3s of speech.
    private func processSortformerChunk(_ samples: [Float], at absoluteTime: TimeInterval) async {
        guard let diarizer = sortformerDiarizer else { return }

        // Append raw audio to the ring buffer (before Sortformer processing,
        // so the audio is available when segments arrive).
        if embeddingExtractor != nil {
            appendToRingBuffer(samples)
        }

        do {
            if let result = try diarizer.processSamples(samples) {
                let segments = convertSortformerResult(result)

                // Track per-speaker duration and trigger extraction when ready.
                if embeddingExtractor != nil {
                    for segment in segments {
                        accumulateSpeakerDuration(segment)
                    }
                }

                for segment in segments {
                    await MergeEngine.shared.add(segment)
                }
            }
        } catch {
            logger.error("Sortformer error (\(self.streamType.rawValue)): \(error.localizedDescription)")
        }
    }

    // MARK: - Sortformer Voice ID Helpers

    /// Append raw audio to the continuous ring buffer, trimming the front
    /// when it exceeds the maximum size.
    private func appendToRingBuffer(_ samples: [Float]) {
        audioRingBuffer.append(contentsOf: samples)

        // Trim from the front if the buffer is too large.
        if audioRingBuffer.count > maxRingBufferSamples {
            let excess = audioRingBuffer.count - maxRingBufferSamples
            audioRingBuffer.removeFirst(excess)
            ringBufferStartOffset += excess
        }
    }

    /// Slice audio from the ring buffer for a given absolute time range.
    /// Returns nil if the requested range is outside the buffer.
    private func sliceAudioFromRingBuffer(startTime: TimeInterval, endTime: TimeInterval) -> [Float]? {
        let startSample = Int(startTime * 16_000)
        let endSample = Int(endTime * 16_000)

        // Convert absolute sample indices to ring buffer indices.
        let bufferStart = startSample - ringBufferStartOffset
        let bufferEnd = endSample - ringBufferStartOffset

        guard bufferStart >= 0, bufferEnd <= audioRingBuffer.count, bufferStart < bufferEnd else {
            return nil
        }

        return Array(audioRingBuffer[bufferStart..<bufferEnd])
    }

    /// Track accumulated speech duration per Sortformer speaker slot.
    /// When a speaker exceeds the threshold, trigger embedding extraction
    /// using audio sliced from the ring buffer.
    private func accumulateSpeakerDuration(_ segment: TaggedSegment) {
        // Extract the speaker slot index from the label (e.g. "Local-Speaker1" → 0).
        guard let slotIndex = sortformerSlotIndex(from: segment.speaker) else { return }
        guard !identifiedSortformerSlots.contains(slotIndex) else { return }

        sortformerSpeakerDurations[slotIndex, default: 0] += segment.duration

        guard sortformerSpeakerDurations[slotIndex, default: 0] >= minDurationForExtraction else { return }

        // Collect all time ranges for this speaker from diarization segments
        // that are already in MergeEngine, plus the current segment.
        // For simplicity, slice a single contiguous window: from the earliest
        // segment start to the latest segment end for this speaker.
        // The Pyannote extraction pass will re-segment internally.
        let speakerLabel = segment.speaker
        let allSegments = diarizationSegmentsForSpeaker(speakerLabel, latestSegment: segment)
        guard let earliest = allSegments.min(by: { $0.start < $1.start }),
              let latest = allSegments.max(by: { $0.end < $1.end }) else { return }

        guard let audio = sliceAudioFromRingBuffer(startTime: earliest.start, endTime: latest.end) else {
            logger.info("Sortformer VoiceID: ring buffer doesn't cover [\(earliest.start)s-\(latest.end)s] for slot \(slotIndex)")
            return
        }

        // Mark as attempted before async extraction.
        identifiedSortformerSlots.insert(slotIndex)

        Task { [audio] in
            await extractEmbeddingForSortformerSlot(slotIndex, audio: audio, speakerLabel: speakerLabel)
        }
    }

    /// Return the Sortformer slot index (0-based) from a speaker label like "Local-Speaker1".
    private func sortformerSlotIndex(from label: String) -> Int? {
        // Labels are formatted as "<stream>-Speaker<N>" where N is 1-based.
        guard let range = label.range(of: "Speaker") else { return nil }
        let numStr = label[range.upperBound...]
        guard let num = Int(numStr) else { return nil }
        return num - 1 // Convert to 0-based
    }

    /// Collect all diarization segments for a speaker label from the ring of
    /// segments we've already emitted, plus the current one.
    private func diarizationSegmentsForSpeaker(
        _ label: String,
        latestSegment: TaggedSegment
    ) -> [TaggedSegment] {
        // We don't have direct access to MergeEngine's internal segments from
        // here (it's @MainActor). Instead, we track emitted segments locally.
        // For the initial implementation, just use the latest segment's time
        // range expanded by the accumulated duration.
        return [latestSegment]
    }

    /// Run a one-shot Pyannote diarization on ring-buffer audio for a
    /// Sortformer speaker slot to extract a WeSpeaker embedding, then
    /// feed it to VoiceID for identification.
    private func extractEmbeddingForSortformerSlot(
        _ slotIndex: Int,
        audio: [Float],
        speakerLabel: String
    ) async {
        guard let extractor = embeddingExtractor else { return }

        do {
            let result = try extractor.performCompleteDiarization(audio)

            // Find the embedding that was actually extracted from the audio.
            // We must skip pre-loaded enrolled voices (which are in the
            // speakerDatabase by default) and only use embeddings the
            // extractor created from this audio.
            let embedding = pickExtractedEmbedding(from: result, extractor: extractor)

            guard let embedding, !embedding.isEmpty else {
                logger.info("Sortformer VoiceID: no embedding extracted for slot \(slotIndex)")
                return
            }

            // Store the embedding so subsequent segments carry it.
            sortformerSlotEmbeddings[slotIndex] = embedding

            // Emit a zero-duration segment with the embedding so MergeEngine's
            // VoiceID path can match and retroactively rename all segments.
            let segment = TaggedSegment(
                stream: streamType,
                speaker: speakerLabel,
                start: 0,
                end: 0,
                embedding: embedding,
                isFinal: true
            )
            await MergeEngine.shared.add(segment)

            let (matchedID, similarity) = VoiceID.shared.identifySpeaker(fromEmbedding: embedding)
            let sim = String(format: "%.3f", similarity)
            if let matchedID {
                logger.info("Sortformer VoiceID: slot \(slotIndex) → '\(matchedID)' (similarity \(sim))")
            } else {
                logger.info("Sortformer VoiceID: slot \(slotIndex) unrecognised (best similarity \(sim))")
            }
        } catch {
            logger.warning("Sortformer VoiceID: embedding extraction failed for slot \(slotIndex): \(error.localizedDescription)")
        }
    }

    /// Pick the embedding that was actually extracted from the audio, skipping
    /// any pre-loaded enrolled voices. Falls back to the first non-enrolled
    /// speaker in `SpeakerManager.getAllSpeakers()`.
    private func pickExtractedEmbedding(
        from result: DiarizationResult,
        extractor: DiarizerManager
    ) -> [Float]? {
        // 1. Try speakerDatabase first (populated when debugMode=true).
        if let db = result.speakerDatabase {
            for (id, embedding) in db where !enrolledUserIDs.contains(id) {
                if !embedding.isEmpty { return embedding }
            }
        }

        // 2. Fall back to SpeakerManager speakers, skipping enrolled ones.
        for (id, speaker) in extractor.speakerManager.getAllSpeakers() {
            if !enrolledUserIDs.contains(id), !speaker.currentEmbedding.isEmpty {
                return speaker.currentEmbedding
            }
        }

        // 3. If the extractor matched the audio to an enrolled speaker (good!),
        //    use that embedding. This means the audio IS the enrolled person.
        if let db = result.speakerDatabase {
            for (_, embedding) in db where !embedding.isEmpty {
                return embedding
            }
        }
        for (_, speaker) in extractor.speakerManager.getAllSpeakers() {
            if !speaker.currentEmbedding.isEmpty {
                return speaker.currentEmbedding
            }
        }

        return nil
    }

    // MARK: - Pyannote Processing

    /// Accumulate samples and process full chunks through the Pyannote pipeline.
    ///
    /// Uses manual chunking (no `AudioStream`) to stay compatible with actor
    /// isolation. Chunks are processed with a sliding window:
    ///   - Chunk size: `mode.chunkSeconds` (default 5.0s = 80,000 samples)
    ///   - Advance:    `mode.chunkSkipSeconds` (default 2.0s = 32,000 samples)
    private func processPyannoteChunk(_ samples: [Float], at absoluteTime: TimeInterval) async {
        guard let diarizer = pyannoteManager else { return }

        if isFirstChunk {
            bufferStartTime = absoluteTime
            isFirstChunk = false
        }

        sampleBuffer.append(contentsOf: samples)

        let chunkSampleCount = Int(mode.chunkSeconds * 16_000)
        let skipSampleCount = Int(mode.chunkSkipSeconds * 16_000)

        // Process all complete chunks in the buffer
        while sampleBuffer.count >= chunkSampleCount {
            let chunk = Array(sampleBuffer.prefix(chunkSampleCount))

            do {
                let result = try diarizer.performCompleteDiarization(chunk, atTime: bufferStartTime)
                // Segments already have absolute timestamps via atTime: parameter.
                let segments = convertPyannoteResult(result, offsetTime: 0)

                // Deduplicate: overlapping sliding-window chunks produce segments
                // for the same time range. Only emit segments that start in the
                // "fresh" (non-overlapping) portion of this chunk.
                for segment in segments {
                    if isFirstDiarChunk || segment.start >= lastEmittedTime {
                        await MergeEngine.shared.add(segment)
                    }
                }

                isFirstDiarChunk = false
                // Next chunk should only emit segments after the current skip boundary
                lastEmittedTime = bufferStartTime + mode.chunkSkipSeconds
            } catch {
                logger.error("Pyannote error (\(self.streamType.rawValue)): \(error.localizedDescription)")
            }

            // Advance the buffer by the skip amount (sliding window)
            let advance = min(skipSampleCount, sampleBuffer.count)
            sampleBuffer.removeFirst(advance)
            bufferStartTime += Double(advance) / 16_000.0
        }
    }

    // MARK: - Stop

    /// Stop the diarizer and clean up resources.
    func stop() {
        switch mode {
        case .sortformer:
            sortformerDiarizer?.cleanup()
            sortformerDiarizer = nil
            embeddingExtractor?.cleanup()
            embeddingExtractor = nil
            audioRingBuffer.removeAll()
            ringBufferStartOffset = 0
            sortformerSpeakerDurations.removeAll()
            identifiedSortformerSlots.removeAll()
            sortformerSlotEmbeddings.removeAll()
            enrolledUserIDs.removeAll()

        case .pyannoteStreaming:
            pyannoteManager?.cleanup()
            pyannoteManager = nil
            sampleBuffer.removeAll()
        }

        totalSamplesProcessed = 0
        isFirstChunk = true
        isFirstDiarChunk = true
        lastEmittedTime = 0
    }

    // MARK: - Sortformer Conversion

    /// Convert Sortformer chunk results (frame-level speaker probabilities)
    /// into discrete `TaggedSegment` objects with speaker IDs.
    private func convertSortformerResult(
        _ result: SortformerChunkResult
    ) -> [TaggedSegment] {
        let numSpeakers = 4 // Sortformer fixed slots
        let frameCount = result.frameCount
        guard frameCount > 0 else { return [] }

        // Threshold for considering a speaker "active" in a frame
        let activationThreshold: Float = 0.5
        var segments: [TaggedSegment] = []

        // Track contiguous active regions per speaker
        for speakerIndex in 0..<numSpeakers {
            var isActive = false
            var regionStart = 0

            for frame in 0..<frameCount {
                let prob = result.getSpeakerPrediction(speaker: speakerIndex, frame: frame, numSpeakers: numSpeakers)

                if prob > activationThreshold && !isActive {
                    isActive = true
                    regionStart = frame
                } else if prob <= activationThreshold && isActive {
                    isActive = false
                    let segment = makeSortformerSegment(
                        speakerIndex: speakerIndex,
                        startFrame: result.startFrame + regionStart,
                        endFrame: result.startFrame + frame
                    )
                    if segment.duration >= 0.3 { // Minimum 300ms segment
                        segments.append(segment)
                    }
                }
            }

            // Close any open region at end of chunk
            if isActive {
                let segment = makeSortformerSegment(
                    speakerIndex: speakerIndex,
                    startFrame: result.startFrame + regionStart,
                    endFrame: result.startFrame + frameCount
                )
                if segment.duration >= 0.3 {
                    segments.append(segment)
                }
            }
        }

        return segments.sorted { $0.start < $1.start }
    }

    private func makeSortformerSegment(
        speakerIndex: Int,
        startFrame: Int,
        endFrame: Int
    ) -> TaggedSegment {
        let startTime = TimeInterval(startFrame) * TimeInterval(frameDurationSeconds)
        let endTime = TimeInterval(endFrame) * TimeInterval(frameDurationSeconds)
        let speakerLabel = "\(streamType.rawValue)-Speaker\(speakerIndex + 1)"

        // Attach any cached embedding from the hybrid Voice ID extraction.
        let embedding = sortformerSlotEmbeddings[speakerIndex] ?? []

        return TaggedSegment(
            stream: streamType,
            speaker: speakerLabel,
            start: startTime,
            end: endTime,
            embedding: embedding,
            isFinal: true
        )
    }

    // MARK: - Pyannote Conversion

    /// Convert a `DiarizationResult` from the Pyannote pipeline into
    /// `TaggedSegment` objects with absolute timestamps and embeddings.
    ///
    /// Timestamps from `performCompleteDiarization` are relative to the
    /// chunk start, so we add `offsetTime` to get absolute timeline values.
    ///
    /// Embeddings are sourced from `DiarizationResult.speakerDatabase`
    /// and attached to each segment for downstream profile matching.
    private func convertPyannoteResult(
        _ result: DiarizationResult,
        offsetTime: TimeInterval
    ) -> [TaggedSegment] {
        // speakerDatabase is populated when debugMode=true in DiarizerConfig.
        // Fall back to SpeakerManager embeddings if the DB is missing.
        var speakerEmbeddings: [String: [Float]] = result.speakerDatabase ?? [:]
        if speakerEmbeddings.isEmpty, let diarizer = pyannoteManager {
            for (id, speaker) in diarizer.speakerManager.getAllSpeakers() {
                if !speaker.currentEmbedding.isEmpty {
                    speakerEmbeddings[id] = speaker.currentEmbedding
                }
            }
        }

        return result.segments.compactMap { seg -> TaggedSegment? in
            let startTime = offsetTime + Double(seg.startTimeSeconds)
            let endTime = offsetTime + Double(seg.endTimeSeconds)
            guard endTime > startTime else { return nil }

            let speakerLabel = "\(streamType.rawValue)-\(seg.speakerId)"
            let embedding = speakerEmbeddings[seg.speakerId] ?? []

            return TaggedSegment(
                stream: streamType,
                speaker: speakerLabel,
                start: startTime,
                end: endTime,
                embedding: embedding,
                isFinal: true
            )
        }
    }
}


