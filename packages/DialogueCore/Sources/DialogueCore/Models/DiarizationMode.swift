import Foundation

/// Selects which FluidAudio diarization backend to use.
///
/// - `sortformer`: NVIDIA Sortformer end-to-end neural diarization.
///   Fast, handles noise/overlap well, but limited to 4 speakers and no
///   cross-session speaker memory.
/// - `pyannoteStreaming`: Pyannote segmentation + WeSpeaker embeddings.
///   Higher accuracy, supports 6+ speakers, and remembers speakers across
///   recordings via `SpeakerManager` + `initializeKnownSpeakers`.
///
/// Reference: FluidAudio v0.12.1 – Sortformer.md, GettingStarted.md
public enum DiarizationMode: String, CaseIterable, Codable, Sendable {
    case sortformer
    case pyannoteStreaming

    public var displayName: String {
        switch self {
        case .sortformer:
            return "Sortformer (Fast, max 4 speakers)"
        case .pyannoteStreaming:
            return "Pyannote Streaming (Higher accuracy, 6+ speakers)"
        }
    }

    /// Chunk duration in seconds for streaming diarization.
    ///
    /// **Pyannote**: Must match `DiarizerConfig.chunkDuration` (default 10.0s).
    /// The Pyannote segmentation model expects exactly 160,000 samples (10s at 16kHz).
    /// Sending shorter chunks causes zero-padding which corrupts segmentation
    /// and produces incomparable embeddings.
    ///
    /// **Sortformer**: frame-level streaming handles its own buffering;
    /// this value is used only as a fallback.
    public var chunkSeconds: Double {
        switch self {
        case .sortformer: return 3.0
        case .pyannoteStreaming: return 10.0
        }
    }

    /// Duration between successive chunk starts (seconds).
    ///
    /// Controls how often new diarization results are produced.
    /// For Pyannote with 10s chunks and 5s skip, each chunk overlaps
    /// 50% with the previous one — standard sliding window.
    public var chunkSkipSeconds: Double {
        switch self {
        case .sortformer: return 1.5
        case .pyannoteStreaming: return 5.0
        }
    }
}
