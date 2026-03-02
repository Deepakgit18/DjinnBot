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

    // --- Shared ring buffer (both modes) ---
    /// Continuous ring buffer of raw audio (16 kHz mono Float32) for on-demand
    /// embedding extraction. Used by Sortformer Voice ID and by MergeEngine's
    /// unattributed-segment resolution in Pyannote mode.
    private var audioRingBuffer: [Float] = []
    /// Sample offset of the first sample in `audioRingBuffer` (how many samples
    /// were trimmed from the front). Used to convert absolute time → buffer index.
    private var ringBufferStartOffset: Int = 0
    /// Maximum ring buffer size: 60 seconds × 16,000 = 960,000 samples.
    private let maxRingBufferSamples: Int = 960_000

    // --- Clean embedding extractor (both modes) ---
    /// DiarizerManager used only for WeSpeaker embedding extraction.
    /// Has NO pre-loaded speakers — produces raw, unbiased embeddings.
    /// In Sortformer mode: used for hybrid Voice ID.
    /// In Pyannote mode: used by MergeEngine for unattributed segment resolution.
    private var embeddingExtractor: DiarizerManager?

    // --- Sortformer Voice ID state ---
    /// Per-speaker accumulated speech duration (seconds) from Sortformer segments.
    private var sortformerSpeakerDurations: [Int: TimeInterval] = [:]
    /// Set of speaker slot indices that have already been identified via VoiceID.
    private var identifiedSortformerSlots: Set<Int> = Set()
    /// Extracted embedding per speaker slot, attached to subsequent TaggedSegments.
    private var sortformerSlotEmbeddings: [Int: [Float]] = [:]
    /// All emitted diarization segments per speaker slot, used to compute the
    /// full time span when slicing the ring buffer for embedding extraction.
    private var sortformerSlotSegments: [Int: [TaggedSegment]] = [:]
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
                clusteringThreshold: 0.7,  // SDK default for internal segment clustering
                minSpeechDuration: 1.0,
                minSilenceGap: 0.5,
                debugMode: true,
                chunkDuration: 10.0
            )
            let extractor = DiarizerManager(config: extractorConfig)
            extractor.initialize(models: diarModels)

            // Do NOT pre-load enrolled voices into the extractor's SpeakerManager.
            // The extractor must produce raw, unbiased embeddings from the audio.
            // If enrolled speakers are pre-loaded, SpeakerManager will match audio
            // to them (using its permissive 0.65 distance threshold), contaminate
            // the enrolled embedding via EMA, and return a biased result.
            // VoiceID handles matching after extraction.

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
            clusteringThreshold: 0.7,  // SDK default for internal segment clustering
            minSpeechDuration: 1.0,
            minSilenceGap: 0.5,
            debugMode: true,           // Required: speakerDatabase is only returned when debugMode=true
            chunkDuration: Float(mode.chunkSeconds)  // Must match our external chunking to avoid zero-padding
        )
        let diarizer = DiarizerManager(config: config)
        diarizer.initialize(models: models)

        // Override SpeakerManager's speaker matching threshold to match the
        // user's Recognition Threshold from Settings. The SDK derives
        // speakerThreshold from clusteringThreshold * 1.2 by default, which
        // produces a different strictness level. We set it directly to
        // (1 - similarity) so both modes use an equivalent threshold.
        diarizer.speakerManager.speakerThreshold = VoiceID.shared.speakerDistanceThreshold

        // Load enrolled voices from VoiceID into SpeakerManager so that
        // known speakers are recognised from the first chunk. VoiceID owns
        // persistence; we convert its embeddings to FluidAudio Speaker objects.
        loadEnrolledVoices(into: diarizer)

        self.pyannoteManager = diarizer
        sampleBuffer.removeAll()
        bufferStartTime = 0
        isFirstChunk = true

        logger.info("PyannoteManager ready for \(self.streamType.rawValue) stream")

        // Set up a clean embedding extractor (no enrolled speakers) for
        // MergeEngine's unattributed-segment resolution. Non-blocking.
        Task { await self.prepareEmbeddingExtractor() }
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
        appendToRingBuffer(samples)

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
        sortformerSlotSegments[slotIndex, default: []].append(segment)

        guard sortformerSpeakerDurations[slotIndex, default: 0] >= minDurationForExtraction else { return }

        // Slice a contiguous window covering the speaker's segments from the
        // ring buffer. The Pyannote segmentation model expects 10-second chunks
        // (160,000 samples at 16 kHz). Shorter audio gets zero-padded, which
        // corrupts segmentation masks and produces garbage embeddings. Ensure
        // the slice is at least 10 seconds by expanding the window.
        let speakerLabel = segment.speaker
        let allSegments = sortformerSlotSegments[slotIndex] ?? [segment]
        guard let earliest = allSegments.min(by: { $0.start < $1.start }),
              let latest = allSegments.max(by: { $0.end < $1.end }) else { return }

        let minSliceDuration: TimeInterval = 10.0
        var sliceStart = earliest.start
        var sliceEnd = latest.end
        let sliceDuration = sliceEnd - sliceStart
        if sliceDuration < minSliceDuration {
            // Expand symmetrically, clamping to available ring buffer range.
            let deficit = minSliceDuration - sliceDuration
            sliceStart = max(0, sliceStart - deficit / 2)
            sliceEnd = sliceStart + max(sliceDuration, minSliceDuration)
        }

        guard let audio = sliceAudioFromRingBuffer(startTime: sliceStart, endTime: sliceEnd) else {
            logger.info("Sortformer VoiceID: ring buffer doesn't cover [\(sliceStart)s-\(sliceEnd)s] for slot \(slotIndex)")
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

    /// Pick the embedding of the **dominant speaker** (most total speech
    /// duration) from the extraction result.
    ///
    /// The ring buffer slice sent to the extractor contains the full time
    /// span between the earliest and latest Sortformer segments for a
    /// speaker slot. This span includes silence and gaps where the
    /// extractor may detect noise or secondary speakers. Returning the
    /// first dictionary entry would be arbitrary — we must select the
    /// speaker with the most speech to get a representative embedding.
    private func pickExtractedEmbedding(
        from result: DiarizationResult,
        extractor: DiarizerManager
    ) -> [Float]? {
        // Find the speaker with the most accumulated speech duration
        // from the extraction result's segments.
        var durationBySpeaker: [String: Float] = [:]
        for seg in result.segments {
            durationBySpeaker[seg.speakerId, default: 0] += seg.durationSeconds
        }

        // Sort by duration descending and return the dominant speaker's embedding.
        let ranked = durationBySpeaker.sorted { $0.value > $1.value }

        // 1. Try speakerDatabase (populated when debugMode=true).
        if let db = result.speakerDatabase {
            for (speakerId, _) in ranked {
                if let embedding = db[speakerId], !embedding.isEmpty {
                    return embedding
                }
            }
        }

        // 2. Fall back to SpeakerManager, still preferring the dominant speaker.
        let allSpeakers = extractor.speakerManager.getAllSpeakers()
        for (speakerId, _) in ranked {
            if let speaker = allSpeakers[speakerId], !speaker.currentEmbedding.isEmpty {
                return speaker.currentEmbedding
            }
        }

        // 3. Last resort: any non-empty embedding.
        for (_, speaker) in allSpeakers {
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

        // Fill the shared ring buffer so MergeEngine can request embedding
        // extraction for unattributed segments.
        appendToRingBuffer(samples)

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
                // Deliver as a batch in a single MainActor hop to avoid
                // diarization stalls from MainActor contention.
                let newSegments = segments.filter { isFirstDiarChunk || $0.start >= lastEmittedTime }
                if !newSegments.isEmpty {
                    await MergeEngine.shared.addBatch(newSegments)
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
            sortformerSpeakerDurations.removeAll()
            identifiedSortformerSlots.removeAll()
            sortformerSlotEmbeddings.removeAll()
            sortformerSlotSegments.removeAll()

        case .pyannoteStreaming:
            pyannoteManager?.cleanup()
            pyannoteManager = nil
            embeddingExtractor?.cleanup()
            embeddingExtractor = nil
            sampleBuffer.removeAll()
        }

        // Shared ring buffer cleanup (both modes)
        audioRingBuffer.removeAll()
        ringBufferStartOffset = 0

        totalSamplesProcessed = 0
        isFirstChunk = true
        isFirstDiarChunk = true
        lastEmittedTime = 0
    }

    // MARK: - On-Demand Embedding Extraction (public)

    /// Extract a WeSpeaker embedding for audio in the given time range.
    ///
    /// Used by `MergeEngine` to resolve unattributed ASR segments by comparing
    /// the unknown segment's embedding against neighbouring speakers' embeddings.
    ///
    /// The Pyannote segmentation model requires 10-second chunks (160,000 samples
    /// at 16 kHz). If the requested range is shorter, it is expanded symmetrically
    /// to 10 seconds. The dominant speaker (most total speech duration) from the
    /// extraction result is returned.
    ///
    /// Returns an empty array if the ring buffer doesn't cover the requested range
    /// or if the embedding extractor is unavailable.
    func extractEmbedding(startTime: TimeInterval, endTime: TimeInterval) async -> [Float] {
        guard let extractor = embeddingExtractor else {
            logger.info("extractEmbedding: no extractor available for \(self.streamType.rawValue)")
            return []
        }

        // Expand to minimum 10 seconds for Pyannote segmentation model.
        // Expand backwards (into the past) first since future audio may not
        // be in the ring buffer yet when extraction is triggered near real-time.
        let minSliceDuration: TimeInterval = 10.0
        var sliceStart = startTime
        var sliceEnd = endTime
        let duration = sliceEnd - sliceStart
        if duration < minSliceDuration {
            let deficit = minSliceDuration - duration
            sliceStart = max(0, sliceStart - deficit)
            sliceEnd = max(sliceEnd, sliceStart + minSliceDuration)
        }

        guard let audio = sliceAudioFromRingBuffer(startTime: sliceStart, endTime: sliceEnd) else {
            let ss = String(format: "%.1f", sliceStart)
            let se = String(format: "%.1f", sliceEnd)
            logger.info("extractEmbedding: ring buffer doesn't cover [\(ss)s-\(se)s] for \(self.streamType.rawValue)")
            return []
        }

        do {
            let result = try extractor.performCompleteDiarization(audio)
            let embedding = pickExtractedEmbedding(from: result, extractor: extractor)
            return embedding ?? []
        } catch {
            logger.warning("extractEmbedding failed for \(self.streamType.rawValue): \(error.localizedDescription)")
            return []
        }
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

            // Use the enrolled voice name directly when SpeakerManager matched
            // a known speaker (e.g. "sky"), without the stream prefix. Auto-
            // generated IDs (e.g. "1", "2") still get the prefix to disambiguate
            // Local-1 from Remote-1.
            let isEnrolledName = VoiceID.shared.allEnrolledVoices().contains { $0.userID == seg.speakerId }
            let speakerLabel = isEnrolledName ? seg.speakerId : "\(streamType.rawValue)-\(seg.speakerId)"
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


