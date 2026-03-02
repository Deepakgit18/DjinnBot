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
    /// For Pyannote mode, also loads known speaker profiles from
    /// `SpeakerProfileStore` and pre-initialises the `SpeakerManager`
    /// so returning speakers are recognised immediately.
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

        // Load known speakers from the persistent SpeakerProfileStore
        // so returning speakers are recognised from the start.
        await loadKnownSpeakers(into: diarizer)

        self.pyannoteManager = diarizer
        sampleBuffer.removeAll()
        bufferStartTime = 0
        isFirstChunk = true

        logger.info("PyannoteManager ready for \(self.streamType.rawValue) stream")
    }

    /// Load known speaker profiles and initialise the DiarizerManager's
    /// SpeakerManager with them.
    private func loadKnownSpeakers(into diarizer: DiarizerManager) async {
        guard let store = SpeakerProfileStore.shared else {
            logger.info("No SpeakerProfileStore available; skipping known speaker init")
            return
        }

        do {
            let knownSpeakers = try await store.loadAllKnownFluidSpeakers()
            if !knownSpeakers.isEmpty {
                diarizer.speakerManager.initializeKnownSpeakers(knownSpeakers)
                let names = knownSpeakers.map(\.name).joined(separator: ", ")
                logger.info("Loaded \(knownSpeakers.count) known speakers: \(names)")
            } else {
                logger.info("No known speaker profiles to load")
            }
        } catch {
            logger.warning("Failed to load known speakers: \(error.localizedDescription)")
        }
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
    private func processSortformerChunk(_ samples: [Float], at absoluteTime: TimeInterval) async {
        guard let diarizer = sortformerDiarizer else { return }

        do {
            if let result = try diarizer.processSamples(samples) {
                let segments = convertSortformerResult(result)
                for segment in segments {
                    await MergeEngine.shared.add(segment)
                }
            }
        } catch {
            logger.error("Sortformer error (\(self.streamType.rawValue)): \(error.localizedDescription)")
        }
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

    // MARK: - Extract Speakers (Post-Recording)

    /// Extract all tracked speakers from the Pyannote `SpeakerManager`.
    ///
    /// Returns speaker data suitable for saving to `SpeakerProfileStore`.
    /// Only available in Pyannote mode; Sortformer returns an empty array
    /// (it has no cross-session speaker embeddings).
    func extractSpeakers() -> [ExtractedSpeaker] {
        guard mode == .pyannoteStreaming, let diarizer = pyannoteManager else { return [] }

        let allSpeakers = diarizer.speakerManager.getAllSpeakers()
        return allSpeakers.compactMap { (id, speaker) -> ExtractedSpeaker? in
            guard !speaker.currentEmbedding.isEmpty else { return nil }
            return ExtractedSpeaker(
                id: id,
                name: speaker.name,
                embedding: speaker.currentEmbedding,
                duration: speaker.duration
            )
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

        return TaggedSegment(
            stream: streamType,
            speaker: speakerLabel,
            start: startTime,
            end: endTime,
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

// MARK: - Extracted Speaker Data

/// Lightweight value-type snapshot of a speaker's identity and embedding
/// extracted post-recording from the `SpeakerManager`.
struct ExtractedSpeaker: Sendable {
    let id: String
    let name: String
    let embedding: [Float]
    let duration: Float
}
