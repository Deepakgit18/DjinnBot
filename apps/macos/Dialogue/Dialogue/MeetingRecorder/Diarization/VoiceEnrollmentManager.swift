import AVFoundation
import Foundation
import OSLog

/// Manages voice enrollment: records 3 microphone clips (~10 seconds each),
/// extracts embeddings via `VoiceID`, and saves the averaged result as an
/// enrolled voice.
///
/// Usage:
/// 1. Call `prepare()` — no model preloading needed (VoiceID owns the runner).
/// 2. For each of 3 clips:
///    a. Call `startRecording()` — user reads the displayed prompt.
///    b. Call `stopRecording()` — clip is stored internally.
/// 3. After 3 clips, call `saveProfile(name:)` to enroll via VoiceID.
///
/// Minimum recommended recording per clip: 5 seconds (3s absolute minimum).
/// Best results at 8–10 seconds of clear solo speech per clip.
@available(macOS 26.0, *)
@MainActor
final class VoiceEnrollmentManager: ObservableObject {

    // MARK: - Published State

    enum State: Equatable {
        case idle
        case ready
        case recording(duration: TimeInterval)
        case processing
        case done(profileName: String)
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var peakLevel: Float = 0

    /// Number of clips recorded so far (0–3).
    @Published private(set) var clipCount: Int = 0

    /// Total clips required for enrollment.
    let requiredClipCount: Int = 3

    // MARK: - Reading Prompts

    /// Text prompts for the user to read aloud during each enrollment clip.
    /// Designed to elicit natural speech with varied phonemes.
    static let enrollmentPrompts: [String] = [
        "The quick brown fox jumps over the lazy dog. My voice is my passport, verify me. I enjoy having conversations about all sorts of interesting topics throughout the day.",
        "She sells seashells by the seashore. The shells she sells are surely seashells. Peter Piper picked a peck of pickled peppers. A peck of pickled peppers Peter Piper picked.",
        "How much wood would a woodchuck chuck if a woodchuck could chuck wood? A woodchuck would chuck all the wood he could chuck if a woodchuck could chuck wood. That is all.",
    ]

    // MARK: - Private

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "VoiceEnrollment")
    private var audioEngine: AVAudioEngine?
    private var recordedSamples: [Float] = []
    private var recordingStartDate: Date?
    private var durationTimer: Timer?

    /// Collected audio clips (16 kHz mono Float32) from each recording round.
    private var collectedClips: [[Float]] = []

    /// Minimum seconds of audio needed for a usable clip.
    let minimumDuration: TimeInterval = 3.0
    /// Recommended duration per clip for best results.
    let recommendedDuration: TimeInterval = 10.0

    // MARK: - Lifecycle

    /// Prepare for enrollment by ensuring VoiceID's diarizer models
    /// are loaded for embedding extraction.
    func prepare() async {
        guard state == .idle || isErrorState else { return }
        collectedClips.removeAll()
        clipCount = 0

        do {
            try await VoiceID.shared.prepare()
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

    /// Start capturing microphone audio at 16 kHz mono for the current clip.
    func startRecording() {
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
            guard let converted = MeetingAudioConverter.convertTo16kMono(buffer) else { return }
            let samples = MeetingAudioConverter.toFloatArray(converted)
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

            logger.info("Enrollment clip \(self.clipCount + 1)/\(self.requiredClipCount) recording started")
        } catch {
            state = .error("Failed to start microphone: \(error.localizedDescription)")
        }
    }

    /// Stop recording the current clip.
    ///
    /// Stores the recorded audio internally. Returns `true` if the clip
    /// was valid and stored, `false` on error.
    func stopRecording() async -> Bool {
        durationTimer?.invalidate()
        durationTimer = nil

        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        recordingStartDate = nil

        guard !recordedSamples.isEmpty else {
            state = .error("No audio recorded")
            return false
        }

        let durationSec = Double(recordedSamples.count) / 16_000.0
        guard durationSec >= minimumDuration else {
            state = .error("Recording too short (\(String(format: "%.1f", durationSec))s). Need at least \(Int(minimumDuration))s.")
            return false
        }

        // Store the clip
        collectedClips.append(recordedSamples)
        clipCount = collectedClips.count

        logger.info("Clip \(self.clipCount)/\(self.requiredClipCount) recorded (\(String(format: "%.1f", durationSec))s)")

        state = .ready
        return true
    }

    /// The reading prompt for the current clip (0-indexed from clipCount).
    var currentPrompt: String {
        let index = min(clipCount, Self.enrollmentPrompts.count - 1)
        return Self.enrollmentPrompts[index]
    }

    /// Whether all required clips have been recorded.
    var allClipsRecorded: Bool {
        clipCount >= requiredClipCount
    }

    // MARK: - Enrollment

    /// Enroll the speaker using all collected audio clips via VoiceID.
    ///
    /// Call after all 3 clips have been recorded.
    ///
    /// - Parameter name: Display name for the speaker.
    /// - Returns: `true` if enrollment succeeded.
    func saveProfile(name: String, colorIndex: Int? = nil) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            state = .error("Name cannot be empty")
            return false
        }

        guard !collectedClips.isEmpty else {
            state = .error("No audio clips recorded")
            return false
        }

        state = .processing

        do {
            let userID = trimmedName.lowercased().replacingOccurrences(of: " ", with: "_")
            try await VoiceID.shared.enroll(userID: userID, audioClips: collectedClips, colorIndex: colorIndex)
            state = .done(profileName: trimmedName)
            logger.info("Enrolled '\(trimmedName)' from \(self.collectedClips.count) clips")
            return true
        } catch {
            state = .error("Enrollment failed: \(error.localizedDescription)")
            logger.error("Enrollment failed: \(error.localizedDescription)")
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

    /// Clean up completely, discarding all collected clips.
    func cleanup() {
        cancel()
        collectedClips.removeAll()
        clipCount = 0
        state = .idle
    }
}
