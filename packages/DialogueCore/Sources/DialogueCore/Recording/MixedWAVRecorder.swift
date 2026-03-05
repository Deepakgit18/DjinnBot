import AVFoundation
import Foundation
import OSLog

/// Records a 16 kHz mono WAV file from one or two audio streams.
///
/// Can be used as:
/// - **Mixed recorder**: receives buffers from both mic and meeting streams,
///   accumulates them in separate internal buffers, and sums (mixes) aligned
///   samples before writing to disk. This avoids the stuttering caused by
///   naively interleaving chunks from two independent streams.
/// - **Per-stream recorder**: receives buffers from a single stream (local or remote)
///
/// The output is suitable for archival and post-hoc re-processing (e.g. full
/// Pyannote diarization for speaker re-attribution).
public actor MixedWAVRecorder {

    // MARK: - Properties

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "WAVRecorder")
    private var audioFile: AVAudioFile?
    private(set) var outputURL: URL?
    private var totalFramesWritten: AVAudioFrameCount = 0

    /// When true, write calls bail immediately. Set by `shutdown()`
    /// so that hundreds of queued write tasks drain instantly without blocking `stop()`.
    private var isShutdown = false

    /// Optional filename prefix (e.g. "local", "remote"). When nil, uses "meeting".
    private let filenamePrefix: String

    /// Target format for the output WAV file.
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    // MARK: - Mixing Buffers

    /// Accumulated samples from the mic (local) stream, not yet flushed.
    private var micBuffer: [Float] = []
    /// Accumulated samples from the meeting (remote) stream, not yet flushed.
    private var meetingBuffer: [Float] = []
    /// Whether this recorder is operating in mixing mode (two input streams).
    private let isMixer: Bool

    // MARK: - Init

    /// Create a recorder.
    /// - Parameters:
    ///   - filenamePrefix: Prefix for the output filename.
    ///   - isMixer: When true, the recorder expects two input streams (mic + meeting)
    ///     and sums them before writing. When false, it writes a single stream directly.
    public init(filenamePrefix: String = "meeting", isMixer: Bool = false) {
        self.filenamePrefix = filenamePrefix
        self.isMixer = isMixer
    }

    // MARK: - Lifecycle

    /// Begin recording to a new WAV file in the app's recordings directory.
    public func start() throws {
        let recordingsDir = Self.recordingsDirectory()
        try FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "\(filenamePrefix)_\(formatter.string(from: Date())).wav"
        let url = recordingsDir.appendingPathComponent(filename)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        audioFile = try AVAudioFile(forWriting: url, settings: settings)
        outputURL = url
        totalFramesWritten = 0
        isShutdown = false
        micBuffer.removeAll(keepingCapacity: true)
        meetingBuffer.removeAll(keepingCapacity: true)
        logger.info("WAV recording started: \(url.lastPathComponent) (mixer: \(self.isMixer))")
    }

    // MARK: - Single-stream Writing

    /// Write pre-extracted Float32 samples to the WAV file (Sendable-safe entry point).
    ///
    /// For single-stream recorders (local, remote). Writes directly to the file.
    /// **Do not use on a mixer recorder** — use `writeMicSamples` / `writeMeetingSamples` instead.
    public func writeSamples(_ samples: [Float]) {
        guard !isShutdown, !samples.isEmpty, audioFile != nil else { return }
        assert(!isMixer, "writeSamples called on a mixer recorder — use writeMicSamples/writeMeetingSamples")
        flushSamplesToFile(samples)
    }

    // MARK: - Mixer Writing

    /// Append mic (local) samples to the mixing buffer.
    /// Aligned samples are mixed and flushed to disk automatically.
    public func writeMicSamples(_ samples: [Float]) {
        guard !isShutdown, !samples.isEmpty, audioFile != nil else { return }
        micBuffer.append(contentsOf: samples)
        flushMixedSamples()
    }

    /// Append meeting (remote) samples to the mixing buffer.
    /// Aligned samples are mixed and flushed to disk automatically.
    public func writeMeetingSamples(_ samples: [Float]) {
        guard !isShutdown, !samples.isEmpty, audioFile != nil else { return }
        meetingBuffer.append(contentsOf: samples)
        flushMixedSamples()
    }

    /// Sum aligned samples from both buffers and write them to the file.
    ///
    /// After each write call from either stream, we flush however many samples
    /// are available from BOTH buffers (the aligned portion). This ensures
    /// the output is a proper additive mix rather than interleaved chunks.
    private func flushMixedSamples() {
        let count = min(micBuffer.count, meetingBuffer.count)
        guard count > 0 else { return }

        // Sum the two streams, clamping to [-1, 1]
        var mixed = [Float](repeating: 0, count: count)
        for i in 0..<count {
            mixed[i] = max(-1.0, min(1.0, micBuffer[i] + meetingBuffer[i]))
        }

        // Remove flushed samples from both buffers
        micBuffer.removeFirst(count)
        meetingBuffer.removeFirst(count)

        flushSamplesToFile(mixed)
    }

    // MARK: - Shared File Writing

    /// Write Float32 samples to the AVAudioFile.
    private func flushSamplesToFile(_ samples: [Float]) {
        guard let file = audioFile else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData else { return }
        samples.withUnsafeBufferPointer { src in
            channelData[0].update(from: src.baseAddress!, count: samples.count)
        }
        do {
            try file.write(from: buffer)
            totalFramesWritten += buffer.frameLength
        } catch {
            logger.error("WAV write error: \(error.localizedDescription)")
        }
    }

    // MARK: - Shutdown / Stop

    /// Signal the recorder to stop accepting new writes.
    /// Pending write tasks on the actor queue will bail immediately
    /// instead of writing, allowing `stop()` to run without waiting for a backlog.
    public func shutdown() {
        isShutdown = true
    }

    /// Stop recording and return the file URL.
    ///
    /// For mixer recorders, flushes any remaining samples from either buffer
    /// (the other stream is assumed to be silence for those trailing samples).
    public func stop() -> URL? {
        // Flush any remaining unaligned samples from the mixer buffers.
        // One stream may have delivered more samples than the other —
        // write those out as-is (the missing stream is silence / zero).
        if isMixer {
            if !micBuffer.isEmpty {
                flushSamplesToFile(micBuffer)
                micBuffer.removeAll()
            }
            if !meetingBuffer.isEmpty {
                flushSamplesToFile(meetingBuffer)
                meetingBuffer.removeAll()
            }
        }

        let url = outputURL
        let frames = totalFramesWritten
        audioFile = nil
        outputURL = nil
        totalFramesWritten = 0

        if let url {
            let durationSec = Double(frames) / 16_000.0
            logger.info("WAV recording stopped: \(url.lastPathComponent) (\(String(format: "%.1f", durationSec))s)")
        }
        return url
    }

    // MARK: - Legacy

    /// Write an audio buffer to the WAV file.
    ///
    /// The buffer is first converted to 16 kHz mono if needed.
    public func write(_ buffer: AVAudioPCMBuffer) {
        guard let converted = MeetingAudioConverter.convertTo16kMono(buffer) else { return }
        guard let file = audioFile else { return }

        do {
            try file.write(from: converted)
            totalFramesWritten += converted.frameLength
        } catch {
            logger.error("WAV write error: \(error.localizedDescription)")
        }
    }

    // MARK: - Directory

    public static func recordingsDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Dialogue", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }
}
