import DialogueCore
import AVFoundation
import Combine
import CoreAudio
import Foundation
import OSLog

/// Manages voice enrollment: records 3 microphone clips (~10 seconds each),
/// extracts embeddings via `VoiceID`, and saves the averaged result as an
/// enrolled voice.
///
/// Uses `AudioInputStreamer` (HAL Output Audio Unit) for reliable audio
/// capture with direct device control, independent of system defaults.
///
/// Usage:
/// 1. Call `prepare()` — loads diarizer models and starts device monitoring.
/// 2. For each of 3 clips:
///    a. Call `startRecording()` — user reads the displayed prompt.
///    b. Call `stopRecording()` — clip is stored internally.
/// 3. After 3 clips, call `saveProfile(name:)` to enroll via VoiceID.
///
/// **Live mic preview**: Whenever the manager is in `.ready` or `.silenceDetected`
/// state, a lightweight preview stream runs to show live mic levels in the UI.
///
/// **Silence detection**: During recording, the manager tracks consecutive
/// silence duration. If the audio level stays below `silenceThreshold` for
/// `silenceAutoStopDelay` seconds, recording auto-stops and transitions to
/// the `silenceDetected` state with a prompt to check System Settings.
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
        /// Recording auto-stopped because no audio input was detected.
        case silenceDetected
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

    // MARK: - Input Device Selection

    /// Available audio input devices.
    @Published private(set) var availableDevices: [AudioDevice] = []

    /// The currently selected device ID (used to highlight in the picker).
    @Published private(set) var currentDeviceID: AudioDeviceID?

    /// Switch the input device directly on the streamer.
    /// No system default mutation — the HAL Output unit handles it.
    ///
    /// `selectDevice` on the streamer tears down the current stream
    /// (uninitializes the AU, nils the continuation). If a preview or
    /// recording stream was consuming buffers, it must be restarted
    /// after the device switch completes.
    func selectDevice(_ device: AudioDevice) {
        guard device.audioDeviceID != currentDeviceID else { return }
        logger.info("User selected input device: \(device.name)")
        LogStore.shared.log("User switching input to '\(device.name)' (ID: \(device.audioDeviceID))", category: .voiceEnrollment)

        // Remember whether we need to restart the preview after switching.
        let wasPreviewActive = previewStreamTask != nil
        stopPreview()

        do {
            try streamer.selectDevice(device)
            currentDeviceID = device.audioDeviceID
        } catch {
            logger.error("Failed to select device \(device.name): \(error.localizedDescription)")
            LogStore.shared.log("Failed to select device '\(device.name)': \(error.localizedDescription)", category: .voiceEnrollment, level: .error)
            state = .error("Failed to select device: \(error.localizedDescription)")
            return
        }

        // Restart the preview stream if it was running before the switch.
        if wasPreviewActive && shouldPreview {
            startPreview()
        }
    }

    /// Refresh the list of available input devices and the current selection.
    /// Respects the user's persisted mic preference from Settings.
    func refreshDevices() {
        availableDevices = streamer.listInputDevices()
        if currentDeviceID == nil {
            // Try the user's persisted preference first
            let preferredUID = UserDefaults.standard.string(forKey: "selectedInputDeviceUID") ?? ""
            if !preferredUID.isEmpty, let preferred = streamer.deviceByUID(preferredUID) {
                currentDeviceID = preferred.audioDeviceID
            } else {
                currentDeviceID = streamer.currentDevice?.audioDeviceID ?? streamer.defaultInputDevice()?.audioDeviceID
            }
        }
    }

    // MARK: - Silence Detection

    /// Peak level below which audio is considered silence.
    /// Typical background noise sits around 0.005–0.02; speech is >0.05.
    private let silenceThreshold: Float = 0.01

    /// Seconds of continuous silence before auto-stopping the recording.
    private let silenceAutoStopDelay: TimeInterval = 3.0

    /// How long silence has been continuous during the current recording.
    @Published private(set) var continuousSilenceDuration: TimeInterval = 0

    /// Whether the user has been warned about silence (level bar not moving).
    /// Shows a warning banner before auto-stop kicks in.
    @Published private(set) var silenceWarningActive: Bool = false

    /// Threshold for showing the warning (before auto-stop).
    private let silenceWarningDelay: TimeInterval = 1.5

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

    /// The AudioInputStreamer that handles all device enumeration, selection,
    /// and audio capture via a Core Audio HAL Output Audio Unit.
    private let streamer = AudioInputStreamer()

    /// Subscription for device list changes.
    private var devicesCancellable: AnyCancellable?

    /// Recorded samples for the current clip (16 kHz mono Float32).
    private var recordedSamples: [Float] = []
    private var recordingStartDate: Date?
    private var durationTimer: Timer?

    /// Task that consumes the audio stream during recording.
    private var recordingStreamTask: Task<Void, Never>?

    /// Task that consumes the audio stream during preview (level only).
    private var previewStreamTask: Task<Void, Never>?

    /// Collected audio clips (16 kHz mono Float32) from each recording round.
    private var collectedClips: [[Float]] = []

    /// Minimum seconds of audio needed for a usable clip.
    let minimumDuration: TimeInterval = 3.0
    /// Recommended duration per clip for best results.
    let recommendedDuration: TimeInterval = 10.0

    /// Whether the current state warrants running the mic preview.
    private var shouldPreview: Bool {
        switch state {
        case .ready, .silenceDetected: return true
        default: return false
        }
    }

    // MARK: - Lifecycle

    /// Prepare for enrollment by ensuring VoiceID's diarizer models
    /// are loaded for embedding extraction.
    func prepare() async {
        guard state == .idle || isErrorState || state == .silenceDetected else { return }
        collectedClips.removeAll()
        clipCount = 0
        LogStore.shared.log("Voice enrollment prepare() called (state: \(String(describing: state)))", category: .voiceEnrollment)

        refreshDevices()
        setupDeviceListener()

        do {
            try await VoiceID.shared.prepare()
            state = .ready
            startPreview()
            logger.info("VoiceEnrollmentManager ready")
            LogStore.shared.log("Voice enrollment ready. Starting mic preview.", category: .voiceEnrollment)
        } catch {
            state = .error("Failed to load models: \(error.localizedDescription)")
            logger.error("Enrollment model load failed: \(error.localizedDescription)")
            LogStore.shared.log("Enrollment model load failed: \(error.localizedDescription)", category: .voiceEnrollment, level: .error)
        }
    }

    private var isErrorState: Bool {
        if case .error = state { return true }
        return false
    }

    // MARK: - Device Change Listener

    /// Subscribe to device list changes from the AudioInputStreamer.
    private func setupDeviceListener() {
        devicesCancellable?.cancel()
        devicesCancellable = streamer.devicesPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] devices in
                guard let self else { return }
                self.availableDevices = devices
                self.currentDeviceID = self.streamer.currentDevice?.audioDeviceID
                self.logger.info("Device list updated: \(devices.count) input device(s)")
                LogStore.shared.log("Device list updated: \(devices.count) input device(s)", category: .voiceEnrollment)
            }
    }

    // MARK: - Mic Preview

    /// Start a lightweight audio stream for level monitoring only.
    /// No samples are stored. Uses the AudioInputStreamer.
    private func startPreview() {
        stopPreview()
        LogStore.shared.log("Starting mic preview via AudioInputStreamer", category: .voiceEnrollment)

        // Select device if none selected — respect user's Settings preference
        if streamer.currentDevice == nil {
            let preferredUID = UserDefaults.standard.string(forKey: "selectedInputDeviceUID") ?? ""
            let device: AudioDevice?
            if !preferredUID.isEmpty {
                device = streamer.deviceByUID(preferredUID) ?? streamer.defaultInputDevice()
            } else {
                device = streamer.defaultInputDevice()
            }
            guard let device else {
                logger.warning("Preview: no input device available")
                LogStore.shared.log("Preview: no input device available", category: .voiceEnrollment, level: .warning)
                return
            }
            do {
                try streamer.selectDevice(device)
                currentDeviceID = device.audioDeviceID
            } catch {
                logger.warning("Preview: failed to select device: \(error.localizedDescription)")
                LogStore.shared.log("Preview: failed to select device: \(error.localizedDescription)", category: .voiceEnrollment, level: .warning)
                return
            }
        }

        do {
            let stream = try streamer.start(sampleRate: 16_000)
            previewStreamTask = Task { [weak self] in
                for await buffer in stream {
                    guard let self, !Task.isCancelled else { break }
                    let peak = Self.peakFromPCMBuffer(buffer)
                    await MainActor.run {
                        self.peakLevel = peak
                    }
                }
            }
            LogStore.shared.log("Mic preview started via AudioInputStreamer", category: .voiceEnrollment)
        } catch {
            logger.error("Preview: failed to start stream: \(error.localizedDescription)")
            LogStore.shared.log("Preview: failed to start stream: \(error.localizedDescription)", category: .voiceEnrollment, level: .error)
        }
    }

    /// Stop the preview stream.
    private func stopPreview() {
        previewStreamTask?.cancel()
        previewStreamTask = nil
        streamer.stop()
        peakLevel = 0
    }

    /// Compute peak amplitude from a mono Float32 PCM buffer.
    private static func peakFromPCMBuffer(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let floatData = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var peak: Float = 0
        let samples = floatData[0]
        for i in 0..<count {
            let val = abs(samples[i])
            if val > peak { peak = val }
        }
        return peak
    }

    // MARK: - Recording

    /// Start capturing microphone audio at 16 kHz mono for the current clip.
    func startRecording() {
        switch state {
        case .ready: break
        case .done: break
        case .silenceDetected: break
        default: return
        }
        LogStore.shared.log("Enrollment startRecording() called (clip \(clipCount + 1)/\(requiredClipCount))", category: .voiceEnrollment)

        // Verify microphone permission before starting.
        PermissionManager.shared.checkMicrophone()
        let micStatus = PermissionManager.shared.microphoneStatus
        LogStore.shared.log("Microphone permission: \(String(describing: micStatus))", category: .voiceEnrollment)
        guard micStatus == .granted else {
            state = .error("Microphone access is required. Open System Settings > Privacy & Security > Microphone.")
            LogStore.shared.log("Microphone not authorized for enrollment", category: .voiceEnrollment, level: .error)
            return
        }

        // Stop preview — we'll start a dedicated recording stream
        stopPreview()

        recordedSamples.removeAll()
        recordingDuration = 0
        peakLevel = 0
        continuousSilenceDuration = 0
        silenceWarningActive = false

        // Select default device if none selected
        if streamer.currentDevice == nil {
            if let defaultDevice = streamer.defaultInputDevice() {
                do {
                    try streamer.selectDevice(defaultDevice)
                    currentDeviceID = defaultDevice.audioDeviceID
                } catch {
                    state = .error("Failed to select input device: \(error.localizedDescription)")
                    LogStore.shared.log("Failed to select default device for recording: \(error.localizedDescription)", category: .voiceEnrollment, level: .error)
                    startPreview()
                    return
                }
            } else {
                state = .error("No microphone available. Check System Settings > Sound > Input.")
                LogStore.shared.log("No input device available for recording", category: .voiceEnrollment, level: .error)
                startPreview()
                return
            }
        }

        do {
            let stream = try streamer.start(sampleRate: 16_000)
            recordingStartDate = Date()
            state = .recording(duration: 0)

            // Consume the stream — store samples and compute peak
            recordingStreamTask = Task { [weak self] in
                for await buffer in stream {
                    guard let self, !Task.isCancelled else { break }
                    let samples = Self.toFloatArray(buffer)
                    let peak = samples.reduce(Float(0)) { max($0, abs($1)) }

                    await MainActor.run {
                        self.recordedSamples.append(contentsOf: samples)
                        self.peakLevel = peak
                    }
                }
            }

            // Duration timer for UI updates and silence detection
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordingStartDate else { return }
                    let elapsed = Date().timeIntervalSince(start)
                    self.recordingDuration = elapsed
                    self.state = .recording(duration: elapsed)
                    self.updateSilenceTracking()
                }
            }

            let deviceName = streamer.currentDevice?.name ?? "unknown"
            logger.info("Enrollment clip \(self.clipCount + 1)/\(self.requiredClipCount) recording started (device: \(deviceName))")
            LogStore.shared.log("Enrollment recording started (device: \(deviceName), clip \(clipCount + 1)/\(requiredClipCount))", category: .voiceEnrollment)
        } catch {
            state = .error("Failed to start microphone: \(error.localizedDescription)")
            LogStore.shared.log("Failed to start enrollment recording: \(error.localizedDescription)", category: .voiceEnrollment, level: .error)
            startPreview()
        }
    }

    // MARK: - Silence Tracking

    /// Called every 0.1s during recording. Tracks how long the audio level
    /// has stayed below the silence threshold and auto-stops if needed.
    private func updateSilenceTracking() {
        if peakLevel < silenceThreshold {
            // Silence continues
            continuousSilenceDuration += 0.1

            // Show warning after warning delay
            if continuousSilenceDuration >= silenceWarningDelay {
                silenceWarningActive = true
            }

            // Auto-stop after full silence delay
            if continuousSilenceDuration >= silenceAutoStopDelay {
                logger.warning("Silence detected for \(self.silenceAutoStopDelay)s — auto-stopping enrollment recording")
                autoStopForSilence()
            }
        } else {
            // Audio detected — reset silence tracking
            continuousSilenceDuration = 0
            silenceWarningActive = false
        }
    }

    /// Stop recording due to silence and transition to the silenceDetected state.
    private func autoStopForSilence() {
        LogStore.shared.log("Auto-stopping enrollment recording due to silence (\(String(format: "%.1f", silenceAutoStopDelay))s of silence detected)", category: .voiceEnrollment, level: .warning)
        stopRecordingStream()

        // Discard the silent recording — don't store it as a clip
        recordedSamples.removeAll()
        peakLevel = 0
        silenceWarningActive = false

        state = .silenceDetected
        LogStore.shared.log("Transitioned to silenceDetected state. Restarting preview.", category: .voiceEnrollment)

        // Restart preview so user can see if the mic starts working
        startPreview()
    }

    /// Stop the recording stream and timer without discarding samples.
    private func stopRecordingStream() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingStreamTask?.cancel()
        recordingStreamTask = nil
        streamer.stop()
        recordingStartDate = nil
    }

    /// Stop recording the current clip.
    ///
    /// Stores the recorded audio internally. Returns `true` if the clip
    /// was valid and stored, `false` on error.
    func stopRecording() async -> Bool {
        LogStore.shared.log("Stopping enrollment recording (samples collected: \(recordedSamples.count))", category: .voiceEnrollment)
        stopRecordingStream()
        silenceWarningActive = false
        continuousSilenceDuration = 0

        guard !recordedSamples.isEmpty else {
            state = .error("No audio recorded")
            LogStore.shared.log("Enrollment stopRecording: no audio samples collected", category: .voiceEnrollment, level: .error)
            return false
        }

        let durationSec = Double(recordedSamples.count) / 16_000.0
        guard durationSec >= minimumDuration else {
            state = .error("Recording too short (\(String(format: "%.1f", durationSec))s). Need at least \(Int(minimumDuration))s.")
            LogStore.shared.log("Enrollment clip too short: \(String(format: "%.1f", durationSec))s (minimum: \(minimumDuration)s)", category: .voiceEnrollment, level: .warning)
            return false
        }

        // Store the clip
        collectedClips.append(recordedSamples)
        clipCount = collectedClips.count

        logger.info("Clip \(self.clipCount)/\(self.requiredClipCount) recorded (\(String(format: "%.1f", durationSec))s)")
        LogStore.shared.log("Enrollment clip \(clipCount)/\(requiredClipCount) stored (\(String(format: "%.1f", durationSec))s, \(recordedSamples.count) samples)", category: .voiceEnrollment)

        state = .ready

        // Restart preview for the next clip
        if !allClipsRecorded {
            startPreview()
        }

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

        stopPreview()
        state = .processing
        LogStore.shared.log("Processing voice enrollment for '\(trimmedName)' (\(collectedClips.count) clips)", category: .voiceEnrollment)

        do {
            let userID = trimmedName.lowercased().replacingOccurrences(of: " ", with: "_")
            try await VoiceID.shared.enroll(userID: userID, audioClips: collectedClips, colorIndex: colorIndex)
            state = .done(profileName: trimmedName)
            logger.info("Enrolled '\(trimmedName)' from \(self.collectedClips.count) clips")
            LogStore.shared.log("Voice enrollment successful for '\(trimmedName)' (userID: \(userID))", category: .voiceEnrollment)
            return true
        } catch {
            state = .error("Enrollment failed: \(error.localizedDescription)")
            logger.error("Enrollment failed: \(error.localizedDescription)")
            LogStore.shared.log("Voice enrollment failed for '\(trimmedName)': \(error.localizedDescription)", category: .voiceEnrollment, level: .error)
            return false
        }
    }

    /// Cancel any in-progress recording and return to ready.
    func cancel() {
        stopRecordingStream()
        stopPreview()
        recordedSamples.removeAll()
        recordingDuration = 0
        peakLevel = 0
        continuousSilenceDuration = 0
        silenceWarningActive = false
        state = .ready
    }

    /// Clean up completely, discarding all collected clips.
    func cleanup() {
        cancel()
        stopPreview()
        devicesCancellable?.cancel()
        devicesCancellable = nil
        collectedClips.removeAll()
        clipCount = 0
        state = .idle
    }

    // MARK: - Helpers

    /// Extract a contiguous [Float] from a mono PCM buffer's first channel.
    private static func toFloatArray(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }
}
