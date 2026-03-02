import AVFoundation
import FluidAudio
import Foundation
import OSLog

/// Manages voice enrollment: records a microphone sample, extracts a
/// speaker embedding via FluidAudio's `DiarizerManager.extractEmbedding()`,
/// and saves it as a persistent `SpeakerProfile`.
///
/// Usage:
/// 1. Call `startRecording()` to begin capturing microphone audio.
/// 2. Call `stopRecording()` to finish — returns the extracted embedding.
/// 3. Call `saveProfile(name:embedding:)` to persist.
///
/// Minimum recommended recording: 5 seconds (3s absolute minimum).
/// Best results at 8–10 seconds of clear solo speech.
@available(macOS 26.0, *)
@MainActor
final class VoiceEnrollmentManager: ObservableObject {

    // MARK: - Published State

    enum State: Equatable {
        case idle
        case preparingModels
        case ready
        case recording(duration: TimeInterval)
        case processing
        case done(profileName: String)
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var peakLevel: Float = 0

    // MARK: - Private

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "VoiceEnrollment")
    private var audioEngine: AVAudioEngine?
    private var recordedSamples: [Float] = []
    private var recordingStartDate: Date?
    private var durationTimer: Timer?
    private var diarizer: DiarizerManager?

    /// Minimum seconds of audio needed for a usable embedding.
    let minimumDuration: TimeInterval = 3.0
    /// Recommended duration for best results.
    let recommendedDuration: TimeInterval = 8.0

    // MARK: - Lifecycle

    /// Prepare the diarizer models for embedding extraction.
    /// Call once before the first enrollment.
    func prepare() async {
        guard state == .idle || state == .error("") || isErrorState else { return }
        state = .preparingModels

        do {
            // Reuse models from ModelPreloader if available, otherwise download
            let preloader = ModelPreloader.shared
            let models: DiarizerModels

            if let preloaded = preloader.diarizerModels {
                models = preloaded
            } else {
                models = try await DiarizerModels.downloadIfNeeded()
            }

            // Use the same config as recording so embeddings are comparable.
            // debugMode=true is required for speakerDatabase to be returned.
            // chunkDuration=10.0 matches the segmentation model's native window.
            let config = DiarizerConfig(
                clusteringThreshold: 0.7,
                minSpeechDuration: 1.0,
                minSilenceGap: 0.5,
                debugMode: true,
                chunkDuration: 10.0
            )
            let mgr = DiarizerManager(config: config)
            mgr.initialize(models: models)
            self.diarizer = mgr

            state = .ready
            logger.info("VoiceEnrollmentManager ready")
        } catch {
            state = .error("Failed to load models: \(error.localizedDescription)")
            logger.error("Enrollment model load failed: \(error.localizedDescription)")
        }
    }

    private var isErrorState: Bool {
        if case .error = state { return true }
        return false
    }

    // MARK: - Recording

    /// Start capturing microphone audio at 16 kHz mono.
    func startRecording() {
        // Allow starting from .ready or after a completed enrollment (.done)
        switch state {
        case .ready: break
        case .done: break
        default: return
        }

        recordedSamples.removeAll()
        recordingDuration = 0
        peakLevel = 0

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            state = .error("No microphone available")
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Convert to 16 kHz mono Float32
            guard let converted = MeetingAudioConverter.convertTo16kMono(buffer) else { return }
            let samples = MeetingAudioConverter.toFloatArray(converted)

            // Compute peak for the level meter
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }

            Task { @MainActor in
                self.recordedSamples.append(contentsOf: samples)
                self.peakLevel = peak
            }
        }

        engine.prepare()
        do {
            try engine.start()
            self.audioEngine = engine
            recordingStartDate = Date()
            state = .recording(duration: 0)

            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordingStartDate else { return }
                    let elapsed = Date().timeIntervalSince(start)
                    self.recordingDuration = elapsed
                    self.state = .recording(duration: elapsed)
                }
            }

            logger.info("Enrollment recording started")
        } catch {
            state = .error("Failed to start microphone: \(error.localizedDescription)")
        }
    }

    private var isDoneState: Bool {
        if case .done = state { return true }
        return false
    }

    /// Stop recording and extract the speaker embedding.
    ///
    /// Returns the 256-d embedding, or nil on failure.
    func stopRecording() async -> [Float]? {
        durationTimer?.invalidate()
        durationTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recordingStartDate = nil

        guard !recordedSamples.isEmpty else {
            state = .error("No audio recorded")
            return nil
        }

        let durationSec = Double(recordedSamples.count) / 16_000.0
        guard durationSec >= minimumDuration else {
            state = .error("Recording too short (\(String(format: "%.1f", durationSec))s). Need at least \(Int(minimumDuration))s.")
            return nil
        }

        state = .processing
        logger.info("Processing enrollment audio: \(String(format: "%.1f", durationSec))s")

        guard let diarizer else {
            state = .error("Diarizer not initialized")
            return nil
        }

        // Run full diarization on the enrollment audio to extract a speaker
        // embedding. The enrollment clip should contain a single speaker,
        // so we take the first (and usually only) speaker's embedding from
        // the result's speakerDatabase.
        do {
            let result = try diarizer.performCompleteDiarization(recordedSamples)
            if let db = result.speakerDatabase, let firstEntry = db.values.first {
                logger.info("Embedding extracted via diarization: \(firstEntry.count) dimensions")
                state = .ready
                return firstEntry
            }

            // Fallback: get embedding from SpeakerManager
            let speakers = diarizer.speakerManager.getAllSpeakers()
            if let firstSpeaker = speakers.values.first {
                let emb = firstSpeaker.currentEmbedding
                if !emb.isEmpty {
                    logger.info("Embedding extracted via SpeakerManager: \(emb.count) dimensions")
                    state = .ready
                    return emb
                }
            }

            state = .error("No speaker detected in recording. Try speaking louder or longer.")
            return nil
        } catch {
            state = .error("Embedding extraction failed: \(error.localizedDescription)")
            logger.error("performCompleteDiarization failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Save the extracted embedding as a named speaker profile.
    func saveProfile(name: String, embedding: [Float]) async -> Bool {
        guard let store = SpeakerProfileStore.shared else {
            state = .error("Profile store unavailable")
            return false
        }

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            state = .error("Name cannot be empty")
            return false
        }

        do {
            try store.saveOrUpdateProfile(
                speakerId: trimmedName.lowercased().replacingOccurrences(of: " ", with: "_"),
                displayName: trimmedName,
                embedding: embedding
            )
            state = .done(profileName: trimmedName)
            logger.info("Saved enrollment profile for '\(trimmedName)'")
            return true
        } catch {
            state = .error("Failed to save: \(error.localizedDescription)")
            return false
        }
    }

    /// Cancel any in-progress recording.
    func cancel() {
        durationTimer?.invalidate()
        durationTimer = nil
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recordedSamples.removeAll()
        recordingStartDate = nil
        recordingDuration = 0
        peakLevel = 0
        state = .ready
    }

    /// Clean up completely.
    func cleanup() {
        cancel()
        diarizer?.cleanup()
        diarizer = nil
        state = .idle
    }
}
