import Foundation

/// Thin wrapper that creates a `RealtimePipeline` configured for the
/// local microphone stream (speaker prefix: "Local-").
@available(macOS 26.0, *)
typealias MicPipeline = RealtimePipeline

extension MicPipeline {
    /// Convenience factory for the mic pipeline.
    ///
    /// - Parameter mode: Diarization backend to use (Sortformer or Pyannote).
    static func createMic(mode: DiarizationMode = .pyannoteStreaming) -> RealtimePipeline {
        RealtimePipeline(streamType: .mic, mode: mode)
    }
}
