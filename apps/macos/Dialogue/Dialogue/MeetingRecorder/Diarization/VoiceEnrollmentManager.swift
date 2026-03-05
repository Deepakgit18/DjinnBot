import AVFoundation
import CoreAudio
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
/// Always uses the system default audio input device. If the user needs to
/// change their microphone, they should do so in System Settings > Sound.
///
/// **Live mic preview**: Whenever the manager is in `.ready` or `.silenceDetected`
/// state, a lightweight preview engine runs to show live mic levels in the UI.
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
    @Published private(set) var availableDevices: [AudioInputDeviceManager.InputDevice] = []

    /// The current system default input device ID, used to highlight the
    /// active device in the picker.
    @Published private(set) var currentDefaultDeviceID: AudioDeviceID?

    /// Switch the system-wide default input device.
    /// Our CoreAudio property listener handles restarting the engine.
    func selectDevice(_ device: AudioInputDeviceManager.InputDevice) {
        guard device.audioDeviceID != currentDefaultDeviceID else { return }
        logger.info("User selected input device: \(device.name)")
        LogStore.shared.log("User switching system default input to '\(device.name)' (ID: \(device.audioDeviceID))", category: .voiceEnrollment)
        AudioInputDeviceManager.setSystemDefaultInputDevice(device)
        // currentDefaultDeviceID updates when handleDefaultInputDeviceChanged fires
    }

    /// Refresh the list of available input devices and the current default.
    func refreshDevices() {
        availableDevices = AudioInputDeviceManager.availableInputDevices()
        currentDefaultDeviceID = AudioInputDeviceManager.defaultInputDevice()?.audioDeviceID
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

    /// Engine used for actual recording (captures samples).
    private var recordingEngine: AVAudioEngine?
    private var recordedSamples: [Float] = []
    private var recordingStartDate: Date?
    private var durationTimer: Timer?

    /// Lightweight engine used for live mic level preview.
    /// Runs when not recording so the user can see the level meter respond
    /// before pressing record.
    private var previewEngine: AVAudioEngine?

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

    /// Observer token for `AVAudioEngineConfigurationChange` on the preview engine.
    private var previewConfigObserver: NSObjectProtocol?
    /// Observer token for `AVAudioEngineConfigurationChange` on the recording engine.
    private var recordingConfigObserver: NSObjectProtocol?

    /// Whether we're currently handling a device change to prevent re-entrancy.
    private var isHandlingDeviceChange = false

    /// The CoreAudio property listener block, stored so we can remove it later.
    /// Must be the exact same block reference for add/remove.
    private nonisolated(unsafe) var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?

    // MARK: - Default Device Change Observation

    /// Start observing the system default input device via CoreAudio.
    /// When the user switches their mic in System Settings, we get a callback
    /// and can restart the active engine on the new device.
    private func startObservingDefaultDevice() {
        // Remove any existing listener first
        stopObservingDefaultDevice()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.handleDefaultInputDeviceChanged()
            }
        }
        deviceChangeListenerBlock = block

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )

        if status != noErr {
            logger.error("Failed to add default input device listener: OSStatus \(status)")
        } else {
            logger.info("Observing default input device changes")
        }
    }

    /// Stop observing the system default input device.
    private func stopObservingDefaultDevice() {
        guard let block = deviceChangeListenerBlock else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        deviceChangeListenerBlock = nil
    }

    /// Called when the system default input device changes.
    /// Tears down the old engine immediately, then schedules a delayed
    /// restart to give CoreAudio time to finish its internal cleanup.
    private func handleDefaultInputDeviceChanged() {
        guard !isHandlingDeviceChange else { return }
        isHandlingDeviceChange = true

        // Update the published device list and current default
        refreshDevices()

        let deviceName = AudioInputDeviceManager.defaultInputDevice()?.name ?? "unknown"
        logger.info("Default input device changed to: \(deviceName)")
        LogStore.shared.log("Default input device changed to '\(deviceName)'. Will restart engine after delay.", category: .voiceEnrollment)

        let wasRecording: Bool
        switch state {
        case .recording:
            wasRecording = true
            // Tear down old engine immediately (samples are preserved)
            stopRecordingEngine()
        case .ready, .silenceDetected:
            wasRecording = false
            stopPreview()
        default:
            isHandlingDeviceChange = false
            return
        }

        // Delay restart to let CoreAudio finish tearing down the old device.
        // Without this, creating a new AVAudioEngine immediately can hit
        // stale device state and deadlock or throw errors.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.isHandlingDeviceChange = false

            if wasRecording {
                self.restartRecordingEngine()
            } else if self.shouldPreview || self.state == .ready {
                self.startPreview()
            }
        }
    }

    /// Called when an `AVAudioEngine` posts a configuration change notification.
    /// This fires when the engine's I/O unit detects a channel count or sample
    /// rate change. The engine has already stopped itself at this point.
    private func handleEngineConfigChange(isRecordingEngine: Bool) {
        guard !isHandlingDeviceChange else { return }
        isHandlingDeviceChange = true

        logger.info("AVAudioEngine config change (recording=\(isRecordingEngine))")
        LogStore.shared.log("AVAudioEngine configuration changed (isRecording=\(isRecordingEngine)). Will restart engine after delay.", category: .voiceEnrollment)

        if isRecordingEngine {
            stopRecordingEngine()
        } else {
            stopPreview()
        }

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self else { return }
            self.isHandlingDeviceChange = false

            if isRecordingEngine {
                self.restartRecordingEngine()
            } else if self.shouldPreview || self.state == .ready {
                self.startPreview()
            }
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
        startObservingDefaultDevice()

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

    // MARK: - Mic Preview

    /// Start a lightweight mic tap for level monitoring only.
    /// No samples are stored. Runs on the system default input device.
    private func startPreview() {
        stopPreview()
        LogStore.shared.log("Starting mic preview (system default device)", category: .voiceEnrollment)

        let engine = AVAudioEngine()

        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        LogStore.shared.log("Preview input format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch", category: .voiceEnrollment)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            logger.warning("Preview: no valid format from input node")
            LogStore.shared.log("Preview: INVALID format from input node (sampleRate=\(hwFormat.sampleRate), channels=\(hwFormat.channelCount)). No mic available.", category: .voiceEnrollment, level: .error)
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            // Compute peak from raw buffer (no conversion needed for just levels)
            let peak = Self.peakFromBuffer(buffer)
            Task { @MainActor in
                self.peakLevel = peak
            }
        }

        engine.prepare()
        do {
            try engine.start()
            previewEngine = engine

            // Observe config changes (device switches, format changes)
            previewConfigObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleEngineConfigChange(isRecordingEngine: false)
                }
            }

            logger.info("Mic preview started (system default device)")
            LogStore.shared.log("Mic preview engine started (isRunning: \(engine.isRunning))", category: .voiceEnrollment)
        } catch {
            logger.error("Preview: failed to start engine: \(error.localizedDescription)")
            LogStore.shared.log("Preview: failed to start engine: \(error.localizedDescription)", category: .voiceEnrollment, level: .error)
        }
    }

    /// Stop the preview engine.
    /// Safe to call even if the engine was already stopped by CoreAudio
    /// (e.g. during a device change).
    private func stopPreview() {
        if let observer = previewConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            previewConfigObserver = nil
        }
        guard let engine = previewEngine else { return }
        LogStore.shared.log("Stopping mic preview engine (isRunning: \(engine.isRunning))", category: .voiceEnrollment)
        // Only call stop() if still running — calling stop() on an engine
        // whose device was yanked by CoreAudio can deadlock.
        if engine.isRunning {
            engine.stop()
        }
        engine.inputNode.removeTap(onBus: 0)
        previewEngine = nil
        peakLevel = 0
    }

    /// Tear down and restart the preview on the current device.
    private func restartPreview() {
        stopPreview()
        startPreview()
    }

    /// Compute peak amplitude from a buffer without conversion.
    /// Handles float32 (AVAudioEngine mic tap) and int16 (SCStream) formats.
    private static func peakFromBuffer(_ buffer: AVAudioPCMBuffer) -> Float {
        if let floatData = buffer.floatChannelData {
            let count = Int(buffer.frameLength)
            guard count > 0 else { return 0 }
            var peak: Float = 0
            for i in 0..<count {
                let val = abs(floatData[0][i])
                if val > peak { peak = val }
            }
            return peak
        }
        if let int16Data = buffer.int16ChannelData {
            let count = Int(buffer.frameLength)
            guard count > 0 else { return 0 }
            var peak: Int16 = 0
            for i in 0..<count {
                let val = abs(int16Data[0][i])
                if val > peak { peak = val }
            }
            return Float(peak) / Float(Int16.max)
        }
        return 0
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

        // Stop preview — we'll use a dedicated recording engine
        stopPreview()

        recordedSamples.removeAll()
        recordingDuration = 0
        peakLevel = 0
        continuousSilenceDuration = 0
        silenceWarningActive = false

        let engine = AVAudioEngine()
        LogStore.shared.log("Using system default input device for recording", category: .voiceEnrollment)

        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        LogStore.shared.log("Recording engine input format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch, commonFormat=\(hwFormat.commonFormat.rawValue)", category: .voiceEnrollment)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            state = .error("No microphone available. Check System Settings > Sound > Input.")
            LogStore.shared.log("INVALID recording input format — no microphone available (sampleRate=\(hwFormat.sampleRate), channels=\(hwFormat.channelCount))", category: .voiceEnrollment, level: .error)
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let converted = MeetingAudioConverter.convertTo16kMono(buffer) else {
                LogStore.shared.log("Enrollment: failed to convert audio buffer to 16kHz mono", category: .voiceEnrollment, level: .warning)
                return
            }
            let samples = MeetingAudioConverter.toFloatArray(converted)
            let peak = samples.reduce(Float(0)) { max($0, abs($1)) }

            Task { @MainActor in
                self.recordedSamples.append(contentsOf: samples)
                self.peakLevel = peak
            }
        }
        LogStore.shared.log("Recording tap installed on input node (bufferSize: 4096)", category: .voiceEnrollment)

        engine.prepare()
        do {
            try engine.start()
            self.recordingEngine = engine
            recordingStartDate = Date()
            state = .recording(duration: 0)

            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordingStartDate else { return }
                    let elapsed = Date().timeIntervalSince(start)
                    self.recordingDuration = elapsed
                    self.state = .recording(duration: elapsed)

                    // Silence detection
                    self.updateSilenceTracking()
                }
            }

            // Observe config changes (device switches, format changes)
            recordingConfigObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleEngineConfigChange(isRecordingEngine: true)
                }
            }

            logger.info("Enrollment clip \(self.clipCount + 1)/\(self.requiredClipCount) recording started (system default device)")
            LogStore.shared.log("Enrollment recording engine started (isRunning: \(engine.isRunning), clip \(clipCount + 1)/\(requiredClipCount))", category: .voiceEnrollment)
        } catch {
            state = .error("Failed to start microphone: \(error.localizedDescription)")
            LogStore.shared.log("Failed to start enrollment recording engine: \(error.localizedDescription)", category: .voiceEnrollment, level: .error)
            // Restart preview since recording failed
            startPreview()
        }
    }

    // MARK: - Recording Engine Restart

    /// Tear down the current recording engine without discarding collected samples.
    /// Used when we need to recreate the engine on a new device.
    /// Safe to call even if the engine was already stopped by CoreAudio.
    private func stopRecordingEngine() {
        if let observer = recordingConfigObserver {
            NotificationCenter.default.removeObserver(observer)
            recordingConfigObserver = nil
        }
        durationTimer?.invalidate()
        durationTimer = nil
        if let engine = recordingEngine {
            // Only call stop() if still running — calling stop() on an engine
            // whose device was yanked by CoreAudio can deadlock.
            if engine.isRunning {
                engine.stop()
            }
            engine.inputNode.removeTap(onBus: 0)
            recordingEngine = nil
        }
    }

    /// Restart the recording engine on the new default device.
    /// Preserves samples already collected (they're already 16kHz mono).
    /// Picks up the new device's hardware format for the fresh tap.
    private func restartRecordingEngine() {
        guard case .recording = state else { return }
        let samplesBeforeRestart = recordedSamples.count
        logger.info("Restarting recording engine (preserving \(samplesBeforeRestart) samples)")
        LogStore.shared.log("Restarting recording engine after device change (\(samplesBeforeRestart) samples preserved)", category: .voiceEnrollment)

        // Tear down old engine (keep samples, keep timer state)
        stopRecordingEngine()

        // Build a fresh engine on the new default device
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.inputFormat(forBus: 0)
        LogStore.shared.log("New recording engine format: \(hwFormat.sampleRate)Hz, \(hwFormat.channelCount)ch", category: .voiceEnrollment)

        guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
            logger.warning("Recording restart: no valid input format from new device")
            LogStore.shared.log("Recording restart failed: no valid input format. Transitioning to silenceDetected.", category: .voiceEnrollment, level: .warning)
            recordedSamples.removeAll()
            peakLevel = 0
            state = .silenceDetected
            startPreview()
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
            self.recordingEngine = engine

            // Observe config changes on the new engine
            recordingConfigObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange,
                object: engine,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.handleEngineConfigChange(isRecordingEngine: true)
                }
            }

            // Restart the duration timer
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordingStartDate else { return }
                    let elapsed = Date().timeIntervalSince(start)
                    self.recordingDuration = elapsed
                    self.state = .recording(duration: elapsed)
                    self.updateSilenceTracking()
                }
            }

            logger.info("Recording engine restarted on new device")
            LogStore.shared.log("Recording engine restarted successfully (isRunning: \(engine.isRunning))", category: .voiceEnrollment)
        } catch {
            logger.error("Failed to restart recording engine: \(error.localizedDescription)")
            LogStore.shared.log("Failed to restart recording engine: \(error.localizedDescription)", category: .voiceEnrollment, level: .error)
            // Fall back to silence detected so user can try again
            recordedSamples.removeAll()
            recordingStartDate = nil
            peakLevel = 0
            state = .silenceDetected
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
        stopRecordingEngine()
        recordingStartDate = nil

        // Discard the silent recording — don't store it as a clip
        recordedSamples.removeAll()
        peakLevel = 0
        silenceWarningActive = false

        state = .silenceDetected
        LogStore.shared.log("Transitioned to silenceDetected state. Restarting preview.", category: .voiceEnrollment)

        // Restart preview so user can see if the mic starts working
        startPreview()
    }

    /// Stop recording the current clip.
    ///
    /// Stores the recorded audio internally. Returns `true` if the clip
    /// was valid and stored, `false` on error.
    func stopRecording() async -> Bool {
        LogStore.shared.log("Stopping enrollment recording (samples collected: \(recordedSamples.count))", category: .voiceEnrollment)
        stopRecordingEngine()
        recordingStartDate = nil
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
        stopRecordingEngine()
        stopPreview()
        recordedSamples.removeAll()
        recordingStartDate = nil
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
        stopObservingDefaultDevice()
        collectedClips.removeAll()
        clipCount = 0
        state = .idle
    }
}
