import AVFoundation
import Foundation
import OSLog
import ScreenCaptureKit

/// Manages dual audio capture: local microphone (`AudioInputStreamer` HAL unit)
/// and meeting app audio (ScreenCaptureKit per-app SCStream).
///
/// Audio from both sources is:
/// 1. Fed to independent `RealtimePipeline` instances for ASR + diarization
/// 2. Written to a single mixed WAV file via `MixedWAVRecorder`
///
/// **Mic capture**: Uses `AudioInputStreamer` (Core Audio HAL Output Audio Unit)
/// for reliable device selection independent of system defaults. The user's
/// preferred mic (persisted as a UID in UserDefaults) is resolved at start time.
///
/// **Per-app capture**: Only captures audio from detected meeting apps
/// (Zoom, Teams, Chrome, etc.) via `SCContentFilter(including:)`,
/// avoiding music players, notification sounds, and other noise.
///
/// Reference: ScreenCaptureKit per-app audio
/// https://developer.apple.com/documentation/screencapturekit
/// WWDC22 "Meet ScreenCaptureKit"
@available(macOS 26.0, *)
final class DualAudioEngine: NSObject, @unchecked Sendable {

    // MARK: - Properties

    /// HAL Output-based mic streamer — replaces AVAudioEngine for mic capture.
    private let micStreamer = AudioInputStreamer()

    /// Task consuming the mic AsyncStream.
    private var micStreamTask: Task<Void, Never>?

    private let mixedRecorder = MixedWAVRecorder(filenamePrefix: "meeting", isMixer: true)
    private let localRecorder = MixedWAVRecorder(filenamePrefix: "local")
    private let remoteRecorder = MixedWAVRecorder(filenamePrefix: "remote")
    private var micPipeline: RealtimePipeline?
    private var meetingPipeline: RealtimePipeline?
    private var scStream: SCStream?
    private var meetingApps: [SCRunningApplication] = []
    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "DualAudioEngine")

    /// Serial queue for ScreenCaptureKit audio callbacks.
    private let scAudioQueue = DispatchQueue(label: "bot.djinn.app.dialog.sc-audio", qos: .userInteractive)

    /// Counter for mic buffer callbacks — used to log periodically without flooding.
    private var micBufferCount: Int = 0
    /// Counter for meeting buffer callbacks.
    private var meetingBufferCount: Int = 0

    // MARK: - Audio Levels

    /// Current microphone RMS level (0–1). Updated on every mic buffer callback.
    /// Read from the main thread; written from the audio thread.
    private(set) var micLevel: Float = 0

    /// Current meeting app RMS level (0–1). Updated on every meeting buffer callback.
    private(set) var meetingLevel: Float = 0

    // MARK: - Start

    /// Start capturing audio from mic and/or meeting apps.
    ///
    /// - Parameters:
    ///   - micEnabled: Whether to capture local microphone audio
    ///   - meetingEnabled: Whether to capture meeting app audio
    ///   - diarizationMode: Which diarization backend to use
    ///   - micDeviceUID: CoreAudio UID of the preferred microphone (from UserDefaults).
    ///                    If nil or not found, falls back to the system default.
    func start(
        micEnabled: Bool,
        meetingEnabled: Bool,
        diarizationMode: DiarizationMode = .pyannoteStreaming,
        micDeviceUID: String? = nil
    ) async throws {
        logger.info("Starting DualAudioEngine (mic: \(micEnabled), meeting: \(meetingEnabled), diarization: \(diarizationMode.rawValue))")
        LogStore.shared.log("Starting DualAudioEngine (mic: \(micEnabled), meeting: \(meetingEnabled), diarization: \(diarizationMode.rawValue))", category: .audio)

        // Prepare pipelines BEFORE starting the timeline clock.
        // Pipeline preparation loads ML models and can take several seconds.
        // If the timeline starts before the recorders, transcript timestamps
        // will be ahead of the audio file (e.g. transcript says 0:23 but
        // audio doesn't have that speech until 0:29).
        if micEnabled {
            LogStore.shared.log("Preparing mic pipeline (mode: \(diarizationMode.rawValue))", category: .audio)
            let mic = MicPipeline.createMic(mode: diarizationMode)
            try await mic.prepare()
            self.micPipeline = mic
            LogStore.shared.log("Mic pipeline prepared successfully", category: .audio)
        }

        if meetingEnabled {
            LogStore.shared.log("Detecting meeting apps for audio capture", category: .audio)
            meetingApps = await MeetingAppDetector.shared.runningMeetingApplications()
            if !meetingApps.isEmpty {
                let appNames = meetingApps.map(\.applicationName).joined(separator: ", ")
                LogStore.shared.log("Found meeting apps: \(appNames). Preparing meeting pipeline.", category: .audio)
                let meeting = MeetingPipeline.createMeeting(mode: diarizationMode)
                try await meeting.prepare()
                self.meetingPipeline = meeting
                try await setupMeetingSCStream()
                LogStore.shared.log("Meeting pipeline and SCStream configured", category: .audio)
            } else {
                logger.warning("No meeting apps detected; skipping meeting audio capture")
                LogStore.shared.log("No meeting apps detected; mic-only mode", category: .audio, level: .warning)
            }
        }

        // Start WAV recorders (mixed + per-stream)
        try await mixedRecorder.start()
        try await localRecorder.start()
        if meetingPipeline != nil {
            try await remoteRecorder.start()
        }

        // Select the user's preferred mic device via AudioInputStreamer.
        // Falls back to system default if the saved UID is not found.
        if micEnabled {
            try selectMicDevice(preferredUID: micDeviceUID)
        }

        // Start the timeline clock and all audio capture simultaneously.
        // Both mic (AudioInputStreamer) and meeting (SCStream) begin here so
        // WAV file position 0 = transcript time 0 for both streams.
        TimelineManager.shared.start()

        if micEnabled {
            try startMicCapture()
        }

        if let stream = scStream {
            try await stream.startCapture()
            LogStore.shared.log("SCStream capture started", category: .audio)
        }

        logger.info("DualAudioEngine started")
        LogStore.shared.log("DualAudioEngine fully started", category: .audio)
    }

    // MARK: - Mic Device Selection

    /// Resolve and select the preferred mic device on the AudioInputStreamer.
    private func selectMicDevice(preferredUID: String?) throws {
        if let uid = preferredUID, !uid.isEmpty,
           let device = micStreamer.deviceByUID(uid) {
            try micStreamer.selectDevice(device)
            LogStore.shared.log("Selected preferred mic: \(device.name) (UID: \(uid))", category: .audio)
        } else if let defaultDevice = micStreamer.defaultInputDevice() {
            try micStreamer.selectDevice(defaultDevice)
            if let uid = preferredUID, !uid.isEmpty {
                LogStore.shared.log("Preferred mic UID '\(uid)' not found; using default: \(defaultDevice.name)", category: .audio, level: .warning)
            } else {
                LogStore.shared.log("No mic preference set; using default: \(defaultDevice.name)", category: .audio)
            }
        } else {
            throw DualAudioEngineError.noMicrophoneAvailable
        }
    }

    // MARK: - Mic Capture via AudioInputStreamer

    /// Start mic capture using the AudioInputStreamer and consume its AsyncStream.
    private func startMicCapture() throws {
        let stream = try micStreamer.start(sampleRate: 16_000)
        let deviceName = micStreamer.currentDevice?.name ?? "unknown"
        LogStore.shared.log("Mic capture started via AudioInputStreamer (device: \(deviceName), 16kHz mono)", category: .audio)

        micStreamTask = Task { [weak self] in
            for await buffer in stream {
                guard let self, !Task.isCancelled else { break }
                self.handleMicBuffer(buffer)
            }
        }
    }

    // MARK: - ScreenCaptureKit Setup

    /// Configure ScreenCaptureKit to capture audio from detected meeting apps only.
    ///
    /// Uses `SCContentFilter(including:exceptingWindows:)` to scope capture
    /// to specific applications, producing clean meeting audio without
    /// system sounds or music.
    private func setupMeetingSCStream() async throws {
        guard !meetingApps.isEmpty else { return }

        let appNames = meetingApps.map(\.applicationName).joined(separator: ", ")
        logger.info("Setting up SCStream for apps: \(appNames)")

        // Get the main display for the content filter (required parameter)
        let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = shareable.displays.first else {
            throw DualAudioEngineError.screenCaptureSetupFailed("No display found")
        }

        // Per-app content filter: only capture audio from these applications
        let filter = SCContentFilter(
            display: display,
            including: meetingApps,
            exceptingWindows: []
        )

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1

        // We only want audio, not video — minimize video overhead
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 FPS minimum
        config.showsCursor = false

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        // Must add both .screen and .audio outputs; SCStream drops frames with errors if
        // the screen output handler is missing even when we only care about audio.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: scAudioQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: scAudioQueue)
        // Don't start capture here — capture is started in start() together
        // with the mic so both streams begin simultaneously.
        self.scStream = stream

        logger.info("SCStream configured for \(self.meetingApps.count) app(s) (capture not yet started)")
    }

    // MARK: - Audio Buffer Handling

    /// Process a microphone buffer: feed to mic pipeline + WAV recorders.
    ///
    /// Buffers arrive at 16 kHz mono Float32 from AudioInputStreamer —
    /// already at the target format, no conversion needed.
    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        micBufferCount += 1
        let time = TimelineManager.shared.currentAudioTime()
        TimelineManager.shared.advance(bySamples: buffer.frameLength)

        micPipeline?.processBuffer(buffer, at: time)

        // Compute RMS for the waveform visualization.
        micLevel = Self.rmsLevel(of: buffer)

        // Log every ~250 buffers (~4 seconds at 4096 samples / 16kHz) to track mic health
        if micBufferCount == 1 {
            LogStore.shared.log("First mic buffer received (frames: \(buffer.frameLength), level: \(String(format: "%.4f", micLevel)))", category: .audio)
        } else if micBufferCount % 250 == 0 {
            LogStore.shared.log("Mic buffer #\(micBufferCount) (level: \(String(format: "%.4f", micLevel)), time: \(String(format: "%.1f", time))s)", category: .audio, level: .debug)
        }
        // Warn if mic level drops to zero for an extended period
        if micBufferCount > 50, micBufferCount % 50 == 0, micLevel < 0.0001 {
            LogStore.shared.log("Mic level near zero at buffer #\(micBufferCount) (level: \(String(format: "%.6f", micLevel))). Mic may have stopped providing audio.", category: .audio, level: .warning)
        }

        // Write to WAV recorders — buffers are already 16 kHz mono Float32.
        let mixed = self.mixedRecorder
        let local = self.localRecorder
        let wavSamples = MeetingAudioConverter.toFloatArray(buffer)
        if !wavSamples.isEmpty {
            Task {
                await mixed.writeMicSamples(wavSamples)
                await local.writeSamples(wavSamples)
            }
        }
    }

    /// Process a meeting app audio buffer: feed to meeting pipeline + WAV recorders.
    private func handleMeetingBuffer(_ buffer: AVAudioPCMBuffer) {
        let time = TimelineManager.shared.currentAudioTime()
        if micPipeline == nil {
            TimelineManager.shared.advance(bySamples: buffer.frameLength)
        }

        meetingPipeline?.processBuffer(buffer, at: time)

        // Compute RMS for the waveform visualization.
        meetingLevel = Self.rmsLevel(of: buffer)

        // Convert to 16kHz mono before recording — SCStream is configured for
        // 16kHz but we convert defensively in case the format differs.
        let mixed = self.mixedRecorder
        let remote = self.remoteRecorder
        if let converted = MeetingAudioConverter.convertTo16kMono(buffer) {
            let wavSamples = MeetingAudioConverter.toFloatArray(converted)
            if !wavSamples.isEmpty {
                Task {
                    await mixed.writeMeetingSamples(wavSamples)
                    await remote.writeSamples(wavSamples)
                }
            }
        }
    }

    // MARK: - Audio Level Helpers

    /// Compute RMS (root mean square) amplitude from a PCM buffer, normalized to 0–1.
    /// Handles float32 (mic tap), int16, and int32 (SCStream) formats.
    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return 0 }

        var sumOfSquares: Float = 0

        if let floatData = buffer.floatChannelData {
            // Float32 — typical for AudioInputStreamer mic capture
            let samples = floatData[0]
            for i in 0..<frames {
                let s = samples[i]
                sumOfSquares += s * s
            }
        } else if let int16Data = buffer.int16ChannelData {
            // Int16 — typical for SCStream audio
            let samples = int16Data[0]
            let scale: Float = 1.0 / 32768.0
            for i in 0..<frames {
                let s = Float(samples[i]) * scale
                sumOfSquares += s * s
            }
        } else if let int32Data = buffer.int32ChannelData {
            // Int32 — sometimes used by SCStream
            let samples = int32Data[0]
            let scale: Float = 1.0 / 2_147_483_648.0
            for i in 0..<frames {
                let s = Float(samples[i]) * scale
                sumOfSquares += s * s
            }
        } else {
            return 0
        }

        let rms = sqrtf(sumOfSquares / Float(frames))
        // Scale: raw RMS of normal speech is ~0.01–0.1. Multiply by 3 and clamp
        // to get a usable 0–1 range for the waveform visualization.
        return min(rms * 3.0, 1.0)
    }

    // MARK: - Stop Result

    /// URLs for all recorded WAV files from a session.
    struct RecordingURLs {
        /// Mixed (mic + meeting) WAV for playback.
        let mixed: URL?
        /// Local microphone-only WAV for post-recording refinement.
        let local: URL?
        /// Remote meeting app audio-only WAV for post-recording refinement.
        let remote: URL?
    }

    // MARK: - Stop

    /// Stop all capture and return the recorded WAV file URLs.
    func stop() async -> RecordingURLs {
        logger.info("Stopping DualAudioEngine")
        LogStore.shared.log("Stopping DualAudioEngine (mic buffers processed: \(micBufferCount), meeting buffers: \(meetingBufferCount))", category: .audio)

        // Stop audio sources FIRST — no new buffers after this.
        micStreamTask?.cancel()
        micStreamTask = nil
        micStreamer.stop()

        if let stream = scStream {
            try? await stream.stopCapture()
            self.scStream = nil
        }

        // Signal all WAV recorders to reject pending writes.
        // This is critical: buffer handlers created hundreds of fire-and-forget
        // Tasks that are queued on the recorder actors. Without shutdown(),
        // stop() would have to wait for ALL of them to drain, causing a hang.
        await mixedRecorder.shutdown()
        await localRecorder.shutdown()
        await remoteRecorder.shutdown()

        // Stop pipelines (ASR emits final segments here)
        await micPipeline?.stop()
        await meetingPipeline?.stop()
        micPipeline = nil
        meetingPipeline = nil
        meetingApps = []

        // Now stop WAV recorders — pending writes bail instantly due to shutdown flag.
        let mixedURL = await mixedRecorder.stop()
        let localURL = await localRecorder.stop()
        let remoteURL = await remoteRecorder.stop()
        logger.info("DualAudioEngine stopped")
        return RecordingURLs(mixed: mixedURL, local: localURL, remote: remoteURL)
    }
}

// MARK: - SCStreamOutput

@available(macOS 26.0, *)
extension DualAudioEngine: SCStreamOutput {
    /// Called by ScreenCaptureKit when a new audio sample buffer arrives
    /// from the meeting application(s).
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }

        // Convert CMSampleBuffer → AVAudioPCMBuffer
        guard let pcmBuffer = MeetingAudioConverter.pcmBuffer(from: sampleBuffer) else {
            return
        }

        handleMeetingBuffer(pcmBuffer)
    }
}

// MARK: - Errors

enum DualAudioEngineError: Error, LocalizedError {
    case noMicrophoneAvailable
    case screenCaptureSetupFailed(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophoneAvailable:
            return "No microphone available. Check System Preferences > Sound > Input."
        case .screenCaptureSetupFailed(let reason):
            return "Failed to set up screen capture: \(reason)"
        }
    }
}
