import AVFoundation
import OSLog
import ReplayKit

/// Broadcast Upload Extension — receives audio sample buffers from ReplayKit.
///
/// Writes proper WAV files (16kHz mono 16-bit) directly using AVAssetWriter,
/// so the main app can feed them straight to PostRecordingRefiner without
/// any manual PCM conversion.
class SampleHandler: RPBroadcastSampleHandler {

    private let logger = Logger(subsystem: "bot.djinn.ios.dialogue.BroadcastUpload", category: "SampleHandler")

    static let appGroupID = "group.bot.djinn.dialogue"

    private var micWriter: AVAssetWriter?
    private var micInput: AVAssetWriterInput?
    private var appWriter: AVAssetWriter?
    private var appInput: AVAssetWriterInput?

    private var micStarted = false
    private var appStarted = false

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        logger.info("Broadcast started")

        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else {
            logger.error("Cannot access App Group container")
            return
        }

        let dir = container.appendingPathComponent("AudioChunks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Remove stale files
        for name in ["mic_audio.wav", "app_audio.wav", "mic_audio.pcm", "app_audio.pcm", "audio_format.json"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
        }

        // Output settings: 16kHz mono 16-bit PCM WAV — exactly what the refiner expects
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        // Set up AVAssetWriters for mic and app audio
        do {
            let micURL = dir.appendingPathComponent("mic_audio.wav")
            micWriter = try AVAssetWriter(outputURL: micURL, fileType: .wav)
            micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
            micInput!.expectsMediaDataInRealTime = true
            micWriter!.add(micInput!)
            micStarted = false

            let appURL = dir.appendingPathComponent("app_audio.wav")
            appWriter = try AVAssetWriter(outputURL: appURL, fileType: .wav)
            appInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
            appInput!.expectsMediaDataInRealTime = true
            appWriter!.add(appInput!)
            appStarted = false

            logger.info("AVAssetWriters configured for 16kHz mono WAV output")
        } catch {
            logger.error("Failed to create AVAssetWriters: \(error)")
        }

        // Signal to main app
        let activeFile = container.appendingPathComponent("broadcast_active")
        FileManager.default.createFile(atPath: activeFile.path, contents: Data())
        let pendingFile = container.appendingPathComponent("recording_pending")
        FileManager.default.createFile(atPath: pendingFile.path, contents: Data())

        logger.info("Broadcast setup complete")
    }

    override func broadcastPaused() {
        logger.info("Broadcast paused")
    }

    override func broadcastResumed() {
        logger.info("Broadcast resumed")
    }

    override func broadcastFinished() {
        logger.info("Broadcast finishing — finalizing writers")

        // Finalize writers
        let group = DispatchGroup()

        if let micInput, let micWriter, micStarted {
            micInput.markAsFinished()
            group.enter()
            micWriter.finishWriting { [weak self] in
                if let error = micWriter.error {
                    self?.logger.error("Mic writer error: \(error)")
                } else {
                    self?.logger.info("Mic WAV finalized")
                }
                group.leave()
            }
        }

        if let appInput, let appWriter, appStarted {
            appInput.markAsFinished()
            group.enter()
            appWriter.finishWriting { [weak self] in
                if let error = appWriter.error {
                    self?.logger.error("App writer error: \(error)")
                } else {
                    self?.logger.info("App WAV finalized")
                }
                group.leave()
            }
        }

        // Wait briefly for writers to finish
        _ = group.wait(timeout: .now() + 5.0)

        micWriter = nil
        micInput = nil
        appWriter = nil
        appInput = nil

        // Remove active signal, keep recording_pending
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) {
            try? FileManager.default.removeItem(at: container.appendingPathComponent("broadcast_active"))
            try? FileManager.default.removeItem(at: container.appendingPathComponent("broadcast_stop_request"))
        }

        logger.info("Broadcast finished")
    }

    private var sampleCount = 0

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        sampleCount += 1
        if sampleCount % 100 == 0 {
            checkForStopRequest()
        }

        switch sampleBufferType {
        case .video:
            break

        case .audioApp:
            appendToWriter(sampleBuffer, writer: appWriter, input: appInput, started: &appStarted, label: "app")

        case .audioMic:
            appendToWriter(sampleBuffer, writer: micWriter, input: micInput, started: &micStarted, label: "mic")

        @unknown default:
            break
        }
    }

    private func appendToWriter(_ sampleBuffer: CMSampleBuffer, writer: AVAssetWriter?, input: AVAssetWriterInput?, started: inout Bool, label: String) {
        guard let writer, let input else { return }

        if !started {
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startWriting()
            writer.startSession(atSourceTime: time)
            started = true

            // Log the source format for debugging
            if let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
               let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) {
                logger.info("\(label) audio format: \(asbd.pointee.mSampleRate)Hz, \(asbd.pointee.mChannelsPerFrame)ch, \(asbd.pointee.mBitsPerChannel)bit")
            }
        }

        if input.isReadyForMoreMediaData {
            input.append(sampleBuffer)
        }
    }

    private func checkForStopRequest() {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) else { return }
        let stopFile = container.appendingPathComponent("broadcast_stop_request")
        if FileManager.default.fileExists(atPath: stopFile.path) {
            try? FileManager.default.removeItem(at: stopFile)
            logger.info("Stop request received from main app")
            let error = NSError(domain: "bot.djinn.ios.dialogue", code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Recording stopped by user"
            ])
            finishBroadcastWithError(error)
        }
    }
}
