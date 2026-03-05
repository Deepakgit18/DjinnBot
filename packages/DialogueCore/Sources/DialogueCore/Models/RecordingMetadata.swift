import Foundation

/// Metadata for a completed meeting recording.
public struct RecordingMetadata: Codable, Sendable {
    public let id: UUID
    public let startDate: Date
    public let endDate: Date
    public let durationSeconds: TimeInterval
    public let wavFileURL: URL?
    public let detectedApps: [String]
    public let speakerCount: Int
    public let segmentCount: Int

    public init(
        id: UUID = UUID(),
        startDate: Date,
        endDate: Date = .now,
        durationSeconds: TimeInterval,
        wavFileURL: URL?,
        detectedApps: [String],
        speakerCount: Int,
        segmentCount: Int
    ) {
        self.id = id
        self.startDate = startDate
        self.endDate = endDate
        self.durationSeconds = durationSeconds
        self.wavFileURL = wavFileURL
        self.detectedApps = detectedApps
        self.speakerCount = speakerCount
        self.segmentCount = segmentCount
    }

    /// Persist metadata as JSON sidecar next to the WAV file.
    public func writeSidecar() throws {
        guard let wavURL = wavFileURL else { return }
        let sidecarURL = wavURL.deletingPathExtension().appendingPathExtension("json")
        let data = try JSONEncoder().encode(self)
        try data.write(to: sidecarURL, options: .atomic)
    }
}
