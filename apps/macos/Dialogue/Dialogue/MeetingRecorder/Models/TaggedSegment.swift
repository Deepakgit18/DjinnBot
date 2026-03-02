import CoreMedia
import Foundation
import SwiftData

// MARK: - Word Timing

/// A single word (or run of text) with its precise audio time range.
///
/// Extracted from `SpeechTranscriber.Result.text` — each `AttributedString.Run`
/// carries an `audioTimeRange` attribute (`CMTimeRange`). We convert those into
/// these lightweight structs so they survive the pipeline and can be persisted.
struct WordTiming: Codable, Sendable {
    let word: String
    let start: TimeInterval
    let end: TimeInterval
}

// MARK: - Stream Type

/// Identifies which audio stream a segment originated from.
enum StreamType: String, Codable, Sendable {
    case mic = "Local"
    case meeting = "Remote"
}

// MARK: - Tagged Segment

/// A single diarized + transcribed segment on the shared audio timeline.
///
/// Combines speaker identity from diarization with transcript text from ASR,
/// tagged by which audio stream (mic vs. meeting app) it came from.
struct TaggedSegment: Identifiable, Sendable {
    let id: UUID
    let stream: StreamType
    var speaker: String
    var start: TimeInterval
    var end: TimeInterval
    var text: String
    var embedding: [Float]
    var isFinal: Bool
    /// Per-word (per-run) timing from ASR. Empty for diarization-only segments
    /// or when ASR didn't produce word-level timing.
    var wordTimings: [WordTiming]

    init(
        id: UUID = UUID(),
        stream: StreamType,
        speaker: String,
        start: TimeInterval,
        end: TimeInterval,
        text: String = "",
        embedding: [Float] = [],
        isFinal: Bool = false,
        wordTimings: [WordTiming] = []
    ) {
        self.id = id
        self.stream = stream
        self.speaker = speaker
        self.start = start
        self.end = end
        self.text = text
        self.embedding = embedding
        self.isFinal = isFinal
        self.wordTimings = wordTimings
    }

    var duration: TimeInterval { end - start }

    /// Display-friendly label combining stream prefix and speaker ID.
    var displayLabel: String { "\(stream.rawValue)-\(speaker)" }

    /// Whether the text contains at least one letter or digit.
    /// Filters out noise artefacts from ASR (e.g. " .", " ,", whitespace-only).
    var hasSubstantialContent: Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }
}

// MARK: - ASR Result Wrapper

/// Lightweight container for an ASR result on the shared timeline.
struct ASRSegment: Sendable {
    let stream: StreamType
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let isFinal: Bool
    /// Per-word timing extracted from the SpeechTranscriber AttributedString runs.
    let wordTimings: [WordTiming]
}
