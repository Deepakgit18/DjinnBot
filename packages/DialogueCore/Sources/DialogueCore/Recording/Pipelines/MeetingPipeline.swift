import Foundation

/// Thin wrapper that creates a `RealtimePipeline` configured for the
/// meeting app audio stream (speaker prefix: "Remote-").
public typealias MeetingPipeline = RealtimePipeline

extension MeetingPipeline {
    /// Convenience factory for the meeting audio pipeline.
    ///
    /// - Parameter mode: Diarization backend to use (Sortformer or Pyannote).
    public static func createMeeting(mode: DiarizationMode = .pyannoteStreaming) -> RealtimePipeline {
        RealtimePipeline(streamType: .meeting, mode: mode)
    }
}
