import AVFoundation
import CoreMedia
import Foundation
import OSLog
@preconcurrency import Speech

/// Lightweight speech-to-text engine for the voice command hotkey.
///
/// Unlike `RealtimeTranscriptionManager` (which feeds into the MergeEngine
/// meeting pipeline), this transcriber accumulates text into a simple string
/// and publishes it for the overlay UI.
///
/// Lifecycle: `prepare()` once at app launch (reuses ModelPreloader's cached
/// locale/assets), then `start()` / `stop()` per hotkey press.
@available(macOS 26.0, *)
actor VoiceCommandTranscriber {

    // MARK: - Published State (MainActor)

    /// Accumulated transcript text, updated progressively.
    @MainActor var transcript: String = ""

    /// Current mic audio level (0–1) for the waveform.
    @MainActor var audioLevel: Float = 0

    /// The finalized text so far (only confirmed words, no partial).
    /// Used by dictation mode to know what's safe to insert.
    var currentFinalizedText: String { finalizedText }

    /// Length of finalized text (convenience for diffing).
    var finalizedTextLength: Int { finalizedText.count }

    // MARK: - Private

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "VoiceCommandASR")

    private var transcriber: SpeechTranscriber?
    private var analyzer: SpeechAnalyzer?
    private var analyzerFormat: AVAudioFormat?
    private var asrLocale: Locale?
    private var isPrepared = false

    // Streaming state
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultTask: Task<Void, Never>?
    private var analyzeTask: Task<Void, Never>?

    // Audio engine
    private var audioEngine: AVAudioEngine?
    private var converter: AVAudioConverter?

    // MARK: - Prepare

    /// Pre-build the SpeechAnalyzer pipeline. Call once at app launch.
    /// Reuses ModelPreloader's cached ASR locale and asset check.
    func prepare() async throws {
        guard !isPrepared else { return }
        logger.info("Preparing VoiceCommandTranscriber")

        // 1. Match locale (reuse from ModelPreloader if available)
        let locale: Locale
        if let cached = await ModelPreloader.shared.asrLocale {
            locale = cached
        } else {
            guard let matched = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
                throw TranscriptionError.unsupportedLocale
            }
            locale = matched
        }

        // 2. Create transcriber
        let newTranscriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        self.transcriber = newTranscriber
        self.asrLocale = locale

        // 3. Assets should already be installed by ModelPreloader; skip download
        let assetsPreloaded = await ModelPreloader.shared.asrAssetsInstalled
        if !assetsPreloaded {
            logger.info("Assets not pre-loaded; checking installation")
            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [newTranscriber]) {
                try await downloader.downloadAndInstall()
            }
        }

        // 4. Best audio format
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [newTranscriber]) else {
            throw TranscriptionError.noCompatibleFormat
        }
        self.analyzerFormat = format

        // 5. Create analyzer
        let newAnalyzer = SpeechAnalyzer(modules: [newTranscriber])
        try await newAnalyzer.prepareToAnalyze(in: format)
        self.analyzer = newAnalyzer

        isPrepared = true
        logger.info("VoiceCommandTranscriber ready (format: \(format))")
    }

    // MARK: - Start / Stop

    /// Begin mic capture and live transcription.
    func start() async throws {
        if !isPrepared {
            try await prepare()
        }

        guard let transcriber, let analyzer, let analyzerFormat else {
            throw TranscriptionError.notPrepared
        }

        // Reset transcript
        await MainActor.run { self.transcript = "" }

        // Create input stream
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.inputContinuation = continuation

        // Result consumption task
        resultTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    let isFinal = result.range.end <= result.resultsFinalizationTime
                    await self.handleResult(text: text, isFinal: isFinal)
                }
            } catch {
                await self.logInfo("Result stream ended: \(error.localizedDescription)")
            }
        }

        // Analyzer consumption task
        analyzeTask = Task {
            do {
                _ = try await analyzer.analyzeSequence(stream)
            } catch {
                self.logger.info("Analyze sequence ended: \(error.localizedDescription)")
            }
        }

        // Start audio engine with mic tap
        try startAudioCapture(analyzerFormat: analyzerFormat, continuation: continuation)

        logger.info("Voice command transcription started")
    }

    /// Stop mic capture and transcription. Returns the final transcript text.
    func stop() async -> String {
        // Stop audio engine first
        stopAudioCapture()

        // Finish the input stream
        inputContinuation?.finish()
        inputContinuation = nil

        // Finalize the analyzer
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        // Wait briefly for final results to arrive
        try? await Task.sleep(for: .milliseconds(300))

        // Cancel tasks
        resultTask?.cancel()
        analyzeTask?.cancel()
        resultTask = nil
        analyzeTask = nil

        // Re-create the analyzer for next use (SpeechAnalyzer is single-use)
        await rebuildAnalyzer()

        let finalText = await transcript
        logger.info("Voice command stopped. Transcript length: \(finalText.count)")
        return finalText
    }

    // MARK: - Result Handling

    /// Tracks finalized text so we can build a progressive transcript.
    private var finalizedText: String = ""

    private func handleResult(text: String, isFinal: Bool) async {
        if isFinal {
            // Append this final chunk
            if !finalizedText.isEmpty {
                finalizedText += " "
            }
            finalizedText += text.trimmingCharacters(in: .whitespacesAndNewlines)
            let snapshot = finalizedText
            await MainActor.run {
                self.transcript = snapshot
            }
        } else {
            // Show finalized + current partial
            let partial = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let display = finalizedText.isEmpty ? partial : finalizedText + " " + partial
            await MainActor.run {
                self.transcript = display
            }
        }
    }

    private func logInfo(_ msg: String) {
        logger.info("\(msg)")
    }

    // MARK: - Audio Capture

    private func startAudioCapture(
        analyzerFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0 else {
            throw TranscriptionError.noCompatibleFormat
        }

        // Create a persistent converter from hardware format to analyzer format
        guard let conv = AVAudioConverter(from: hwFormat, to: analyzerFormat) else {
            throw TranscriptionError.noCompatibleFormat
        }
        self.converter = conv

        // Install tap at hardware format
        let ratio = analyzerFormat.sampleRate / hwFormat.sampleRate
        let bufferSize = AVAudioFrameCount(4096)
        let analyzerFmt = analyzerFormat // capture for Sendable closure

        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, time in
            // Compute RMS for waveform
            let rms = Self.computeRMS(buffer)
            Task { @MainActor in
                guard let self else { return }
                self.audioLevel = rms
            }

            // Convert to analyzer format
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard outputFrameCount > 0,
                  let outputBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFmt, frameCapacity: outputFrameCount) else {
                return
            }

            var error: NSError?
            var consumed = false
            conv.convert(to: outputBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            guard error == nil, outputBuffer.frameLength > 0 else { return }

            let input = AnalyzerInput(buffer: outputBuffer)
            continuation.yield(input)
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }

    private func stopAudioCapture() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        converter = nil

        // Reset audio level
        Task { @MainActor in
            self.audioLevel = 0
        }
    }

    private static func computeRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        let data = channelData[0]
        for i in 0..<count {
            let sample = data[i]
            sum += sample * sample
        }
        let rms = sqrtf(sum / Float(count))
        // Normalize: typical speech RMS is 0.01–0.1
        return min(rms * 8, 1.0)
    }

    // MARK: - Rebuild Analyzer

    /// SpeechAnalyzer is single-use (can't re-start after finalize).
    /// Rebuild it so the next hotkey press works.
    private func rebuildAnalyzer() async {
        guard let analyzerFormat, let locale = asrLocale else { return }

        // Need a fresh transcriber too (it's consumed by the results stream)
        let newTranscriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedProgressiveTranscription
        )
        self.transcriber = newTranscriber

        let newAnalyzer = SpeechAnalyzer(modules: [newTranscriber])
        do {
            try await newAnalyzer.prepareToAnalyze(in: analyzerFormat)
            self.analyzer = newAnalyzer
        } catch {
            logger.error("Failed to rebuild analyzer: \(error.localizedDescription)")
            self.analyzer = nil
            isPrepared = false
        }

        // Reset finalized text for next session
        finalizedText = ""
    }
}
