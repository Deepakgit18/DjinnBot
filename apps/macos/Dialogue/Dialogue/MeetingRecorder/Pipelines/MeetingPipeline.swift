import Foundation

/// Thin wrapper that creates a `RealtimePipeline` configured for the
/// meeting app audio stream (speaker prefix: "Remote-").
@available(macOS 26.0, *)
typealias MeetingPipeline = RealtimePipeline

extension MeetingPipeline {
    /// Convenience factory for the meeting audio pipeline.
    ///
    /// - Parameter mode: Diarization backend to use (Sortformer or Pyannote).
    static func createMeeting(mode: DiarizationMode = .pyannoteStreaming) -> RealtimePipeline {
        RealtimePipeline(streamType: .meeting, mode: mode)
    }
}
