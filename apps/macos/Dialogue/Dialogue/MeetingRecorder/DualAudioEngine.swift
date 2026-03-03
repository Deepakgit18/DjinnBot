import AVFoundation
import Foundation
import OSLog
import ScreenCaptureKit

/// Manages dual audio capture: local microphone (AVAudioEngine) and
/// meeting app audio (ScreenCaptureKit per-app SCStream).
///
/// Audio from both sources is:
/// 1. Fed to independent `RealtimePipeline` instances for ASR + diarization
/// 2. Written to a single mixed WAV file via `MixedWAVRecorder`
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

    private let audioEngine = AVAudioEngine()
    private let mixedRecorder = MixedWAVRecorder(filenamePrefix: "meeting", isMixer: true)
    private let localRecorder = MixedWAVRecorder(filenamePrefix: "local")
    private let remoteRecorder = MixedWAVRecorder(filenamePrefix: "remote")
    private var micPipeline: RealtimePipeline?
    private var meetingPipeline: RealtimePipeline?
    private var scStream: SCStream?
    private var meetingApps: [SCRunningApplication] = []
    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "DualAudioEngine")

    /// Persistent converter for mic 48 kHz → 16 kHz mono.
    ///
    /// CRITICAL: Must be created once and reused across all mic tap callbacks.
    /// Creating a new `AVAudioConverter` per buffer loses the resampling
    /// filter's internal state (fractional samples, filter delay), causing
    /// ~7% cumulative sample loss over long recordings. This makes the mic
    /// stream progressively shorter than the meeting stream, and the
    /// sample-count-aligned mixer produces audible cross-talk overlap.
    private var micConverter: AVAudioConverter?
    /// Pre-allocated output buffer for the persistent mic converter.
    /// Sized for the worst-case output from a single tap callback.
    private var micConvertBuffer: AVAudioPCMBuffer?

    /// Serial queue for ScreenCaptureKit audio callbacks.
    private let scAudioQueue = DispatchQueue(label: "bot.djinn.app.dialog.sc-audio", qos: .userInteractive)

    // MARK: - Start

    /// Start capturing audio from mic and/or meeting apps.
    ///
    /// - Parameters:
    ///   - micEnabled: Whether to capture local microphone audio
    ///   - meetingEnabled: Whether to capture meeting app audio
    ///   - diarizationMode: Which diarization backend to use
    func start(
        micEnabled: Bool,
        meetingEnabled: Bool,
        diarizationMode: DiarizationMode = .pyannoteStreaming
    ) async throws {
        logger.info("Starting DualAudioEngine (mic: \(micEnabled), meeting: \(meetingEnabled), diarization: \(diarizationMode.rawValue))")

        // Prepare pipelines BEFORE starting the timeline clock.
        // Pipeline preparation loads ML models and can take several seconds.
        // If the timeline starts before the recorders, transcript timestamps
        // will be ahead of the audio file (e.g. transcript says 0:23 but
        // audio doesn't have that speech until 0:29).
        if micEnabled {
            let mic = MicPipeline.createMic(mode: diarizationMode)
            try await mic.prepare()
            self.micPipeline = mic
        }

        if meetingEnabled {
            meetingApps = await MeetingAppDetector.shared.runningMeetingApplications()
            if !meetingApps.isEmpty {
                let meeting = MeetingPipeline.createMeeting(mode: diarizationMode)
                try await meeting.prepare()
                self.meetingPipeline = meeting
                // Configure SCStream but DON'T start capture yet.
                // Capture is started below together with the mic so both
                // streams begin at the same time — no meeting-audio preamble
                // that would offset transcript timestamps from the WAV file.
                try await setupMeetingSCStream()
            } else {
                logger.warning("No meeting apps detected; skipping meeting audio capture")
            }
        }

        // Start WAV recorders (mixed + per-stream)
        try await mixedRecorder.start()
        try await localRecorder.start()
        if meetingPipeline != nil {
            try await remoteRecorder.start()
        }

        // Install mic tap at hardware format, but convert with a PERSISTENT
        // AVAudioConverter that maintains resampling filter state across calls.
        //
        // CRITICAL: Do NOT create a new AVAudioConverter per buffer (as
        // MeetingAudioConverter.convertTo16kMono() does). Resampling filters
        // carry fractional samples and filter delay between calls. Recreating
        // the converter discards that state, losing ~7% of samples over a
        // 30+ minute recording. This makes the mic stream progressively
        // shorter than the meeting stream, and the sample-count-aligned mixer
        // produces audible cross-talk overlap (~30s drift per 8 minutes).
        if micEnabled {
            let inputNode = audioEngine.inputNode
            let hwFormat = inputNode.inputFormat(forBus: 0)
            guard hwFormat.sampleRate > 0, hwFormat.channelCount > 0 else {
                throw DualAudioEngineError.noMicrophoneAvailable
            }

            let targetFmt = MeetingAudioConverter.targetFormat
            if hwFormat.sampleRate == targetFmt.sampleRate,
               hwFormat.channelCount == targetFmt.channelCount,
               hwFormat.commonFormat == targetFmt.commonFormat {
                // Already at target — no converter needed (unlikely for mic hardware).
                micConverter = nil
                micConvertBuffer = nil
            } else {
                // Create ONE converter that lives for the entire recording session.
                let converter = AVAudioConverter(from: hwFormat, to: targetFmt)
                self.micConverter = converter
                // Pre-allocate an output buffer large enough for any tap callback.
                // Tap bufferSize is 4096 at hwRate; output is at most
                // ceil(4096 * 16000/hwRate) + margin.
                let maxOut = AVAudioFrameCount(ceil(Double(8192) * targetFmt.sampleRate / hwFormat.sampleRate)) + 64
                self.micConvertBuffer = AVAudioPCMBuffer(pcmFormat: targetFmt, frameCapacity: maxOut)
            }

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: hwFormat) { [weak self] buffer, _ in
                self?.handleMicBuffer(buffer)
            }
        }

        audioEngine.prepare()

        // Start the timeline clock and all audio capture simultaneously.
        // Both mic (audioEngine) and meeting (SCStream) begin here so
        // WAV file position 0 = transcript time 0 for both streams.
        TimelineManager.shared.start()
        try audioEngine.start()

        if let stream = scStream {
            try await stream.startCapture()
        }

        logger.info("DualAudioEngine started")
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
    /// The buffer arrives at the hardware format (typically 48 kHz).
    /// We convert to 16 kHz mono using the **persistent** `micConverter`
    /// which maintains proper resampling state across all callbacks.
    private func handleMicBuffer(_ buffer: AVAudioPCMBuffer) {
        let time = TimelineManager.shared.currentAudioTime()
        TimelineManager.shared.advance(bySamples: buffer.frameLength)

        micPipeline?.processBuffer(buffer, at: time)

        // Convert to 16 kHz mono using the persistent converter.
        let converted: AVAudioPCMBuffer
        if let converter = micConverter, let outBuf = micConvertBuffer {
            outBuf.frameLength = 0
            var error: NSError?
            var consumed = false
            converter.convert(to: outBuf, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if let error {
                logger.error("Mic converter error: \(error.localizedDescription)")
                return
            }
            guard outBuf.frameLength > 0 else { return }
            converted = outBuf
        } else {
            // No converter needed (already at target format).
            converted = buffer
        }

        let mixed = self.mixedRecorder
        let local = self.localRecorder
        let wavSamples = MeetingAudioConverter.toFloatArray(converted)
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

        // Stop audio sources FIRST — no new buffers after this.
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
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
        micConverter = nil
        micConvertBuffer = nil

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
