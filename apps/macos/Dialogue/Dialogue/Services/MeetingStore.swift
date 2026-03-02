import Foundation
import Combine
import OSLog

/// Represents a single saved meeting on disk.
struct SavedMeeting: Identifiable, Hashable {
    let id: String           // Folder name (meetingName or timestamp)
    let folderURL: URL
    let displayName: String
    let date: Date
    let hasRecording: Bool
    let hasTranscript: Bool

    var recordingURL: URL { folderURL.appendingPathComponent("recording.wav") }
    var localRecordingURL: URL { folderURL.appendingPathComponent("local.wav") }
    var remoteRecordingURL: URL { folderURL.appendingPathComponent("remote.wav") }
    var transcriptURL: URL { folderURL.appendingPathComponent("transcript.json") }
    var wordTimingsURL: URL { folderURL.appendingPathComponent("word_timings.json") }

    func hash(into hasher: inout Hasher) { hasher.combine(folderURL) }
    static func == (lhs: SavedMeeting, rhs: SavedMeeting) -> Bool { lhs.folderURL == rhs.folderURL }
}

/// Transcript entry stored in transcript.json.
struct TranscriptEntry: Codable, Identifiable {
    var id: String { "\(start)-\(speaker)-\(text.prefix(20))" }
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
    let text: String
    let stream: String       // "Local" or "Remote"
    let isFinal: Bool
}

/// Per-segment word-level timing data stored in word_timings.json.
///
/// Keyed by segment start time + stream to allow correlation with transcript.json
/// entries. The refiner uses these to split segments at speaker boundaries.
struct WordTimingEntry: Codable {
    let segmentStart: TimeInterval
    let segmentEnd: TimeInterval
    let stream: String
    let speaker: String
    let words: [WordTiming]
}

/// Manages the ~/Documents/Dialog/Meetings directory.
///
/// Responsible for:
/// - Saving recordings (WAV + transcript JSON) into per-meeting folders
/// - Scanning the directory and publishing the list of saved meetings
/// - Loading transcript data for display
final class MeetingStore: ObservableObject {
    static let shared = MeetingStore()

    /// All discovered meetings, sorted newest first.
    @Published var meetings: [SavedMeeting] = []

    private let fileManager = FileManager.default
    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "MeetingStore")
    private var watcher: DispatchSourceFileSystemObject?

    /// Root directory: ~/Documents/Dialog/Meetings
    let rootFolder: URL

    private init() {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        rootFolder = docs.appendingPathComponent("Dialog/Meetings", isDirectory: true)
        try? fileManager.createDirectory(at: rootFolder, withIntermediateDirectories: true)
        refresh()
        startWatching()
    }

    // MARK: - Save a Meeting

    /// Save a completed meeting recording and transcript to disk.
    ///
    /// Creates ~/Documents/Dialog/Meetings/{name}/recording.wav, local.wav,
    /// remote.wav, and transcript.json.
    ///
    /// - Parameters:
    ///   - name: Optional meeting name. Falls back to a timestamp.
    ///   - wavSourceURL: The temporary mixed WAV file to move into the meeting folder.
    ///   - localWavSourceURL: The temporary local (mic) WAV file.
    ///   - remoteWavSourceURL: The temporary remote (meeting app) WAV file.
    ///   - segments: The transcript segments to serialize.
    /// - Returns: The created SavedMeeting, or nil on failure.
    @discardableResult
    func saveMeeting(
        name: String? = nil,
        wavSourceURL: URL?,
        localWavSourceURL: URL? = nil,
        remoteWavSourceURL: URL? = nil,
        segments: [TaggedSegment]
    ) -> SavedMeeting? {
        let folderName = sanitizedFolderName(name)
        let meetingFolder = rootFolder.appendingPathComponent(folderName, isDirectory: true)

        do {
            try fileManager.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

            // Move mixed WAV file
            var hasRecording = false
            if let sourceURL = wavSourceURL, fileManager.fileExists(atPath: sourceURL.path) {
                let destWAV = meetingFolder.appendingPathComponent("recording.wav")
                if fileManager.fileExists(atPath: destWAV.path) {
                    try fileManager.removeItem(at: destWAV)
                }
                try fileManager.moveItem(at: sourceURL, to: destWAV)
                hasRecording = true
                logger.info("Saved recording to \(meetingFolder.lastPathComponent)/recording.wav")
            }

            // Move per-stream WAV files (for post-recording refinement)
            for (sourceURL, destName) in [(localWavSourceURL, "local.wav"), (remoteWavSourceURL, "remote.wav")] {
                if let sourceURL, fileManager.fileExists(atPath: sourceURL.path) {
                    let dest = meetingFolder.appendingPathComponent(destName)
                    if fileManager.fileExists(atPath: dest.path) {
                        try fileManager.removeItem(at: dest)
                    }
                    try fileManager.moveItem(at: sourceURL, to: dest)
                    logger.info("Saved \(destName) to \(meetingFolder.lastPathComponent)/\(destName)")
                }
            }

            // Write transcript JSON
            var hasTranscript = false
            if !segments.isEmpty {
                let entries = segments.map { seg in
                    TranscriptEntry(
                        speaker: seg.speaker,
                        start: seg.start,
                        end: seg.end,
                        text: seg.text,
                        stream: seg.stream.rawValue,
                        isFinal: seg.isFinal
                    )
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(entries)
                let transcriptURL = meetingFolder.appendingPathComponent("transcript.json")
                try data.write(to: transcriptURL, options: Data.WritingOptions.atomic)

                // Write plain-text transcript (time-sorted, one line per segment)
                let sortedEntries = entries.sorted { $0.start < $1.start }
                let lines = sortedEntries.map { entry in
                    let minutes = Int(entry.start) / 60
                    let seconds = Int(entry.start) % 60
                    return String(format: "%d:%02d %@: %@", minutes, seconds, entry.speaker, entry.text)
                }
                let txtURL = meetingFolder.appendingPathComponent("transcript.txt")
                try lines.joined(separator: "\n").write(to: txtURL, atomically: true, encoding: .utf8)

                // Write word-level timings for post-recording refinement
                let wordTimingEntries = segments.compactMap { seg -> WordTimingEntry? in
                    guard !seg.wordTimings.isEmpty else { return nil }
                    return WordTimingEntry(
                        segmentStart: seg.start,
                        segmentEnd: seg.end,
                        stream: seg.stream.rawValue,
                        speaker: seg.speaker,
                        words: seg.wordTimings
                    )
                }
                if !wordTimingEntries.isEmpty {
                    let wtData = try encoder.encode(wordTimingEntries)
                    let wtURL = meetingFolder.appendingPathComponent("word_timings.json")
                    try wtData.write(to: wtURL, options: .atomic)
                    logger.info("Saved word timings for \(wordTimingEntries.count) segments")
                }

                hasTranscript = true
                logger.info("Saved transcript with \(segments.count) segments")
            }

            let meeting = SavedMeeting(
                id: folderName,
                folderURL: meetingFolder,
                displayName: displayName(from: folderName),
                date: Date(),
                hasRecording: hasRecording,
                hasTranscript: hasTranscript
            )

            refresh()
            return meeting

        } catch {
            logger.error("Failed to save meeting: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Update Transcript

    /// Overwrite a saved meeting's transcript with refined segments.
    ///
    /// Called by post-recording refinement after offline diarization
    /// produces better speaker attribution.
    func updateTranscript(for meeting: SavedMeeting, segments: [TaggedSegment]) {
        guard !segments.isEmpty else { return }

        do {
            let entries = segments.map { seg in
                TranscriptEntry(
                    speaker: seg.speaker,
                    start: seg.start,
                    end: seg.end,
                    text: seg.text,
                    stream: seg.stream.rawValue,
                    isFinal: seg.isFinal
                )
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entries)
            try data.write(to: meeting.transcriptURL, options: .atomic)

            // Also update word timings
            let wordTimingEntries = segments.compactMap { seg -> WordTimingEntry? in
                guard !seg.wordTimings.isEmpty else { return nil }
                return WordTimingEntry(
                    segmentStart: seg.start,
                    segmentEnd: seg.end,
                    stream: seg.stream.rawValue,
                    speaker: seg.speaker,
                    words: seg.wordTimings
                )
            }
            if !wordTimingEntries.isEmpty {
                let wtData = try encoder.encode(wordTimingEntries)
                try wtData.write(to: meeting.wordTimingsURL, options: .atomic)
            }

            // Also update the plain-text version
            let sortedEntries = entries.sorted { $0.start < $1.start }
            let lines = sortedEntries.map { entry in
                let minutes = Int(entry.start) / 60
                let seconds = Int(entry.start) % 60
                return String(format: "%d:%02d %@: %@", minutes, seconds, entry.speaker, entry.text)
            }
            let txtURL = meeting.folderURL.appendingPathComponent("transcript.txt")
            try lines.joined(separator: "\n").write(to: txtURL, atomically: true, encoding: .utf8)

            logger.info("Updated transcript with \(segments.count) refined segments")
        } catch {
            logger.warning("Failed to update transcript: \(error.localizedDescription)")
        }
    }

    // MARK: - Load Transcript

    /// Load transcript entries from a saved meeting's transcript.json.
    func loadTranscript(for meeting: SavedMeeting) -> [TranscriptEntry]? {
        let url = meeting.transcriptURL
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([TranscriptEntry].self, from: data)
    }

    /// Load word-level timing data from a saved meeting's word_timings.json.
    func loadWordTimings(for meeting: SavedMeeting) -> [WordTimingEntry]? {
        let url = meeting.wordTimingsURL
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([WordTimingEntry].self, from: data)
    }

    // MARK: - Refresh / Scan

    /// Re-scan the Meetings directory and update the published list.
    func refresh() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootFolder,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            meetings = []
            return
        }

        var result: [SavedMeeting] = []
        for item in contents {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDir else { continue }

            let folderName = item.lastPathComponent
            let recordingExists = fileManager.fileExists(
                atPath: item.appendingPathComponent("recording.wav").path
            )
            let transcriptExists = fileManager.fileExists(
                atPath: item.appendingPathComponent("transcript.json").path
            )

            // Only show folders that contain at least one artifact
            guard recordingExists || transcriptExists else { continue }

            let creationDate = (try? item.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast

            result.append(SavedMeeting(
                id: folderName,
                folderURL: item,
                displayName: displayName(from: folderName),
                date: creationDate,
                hasRecording: recordingExists,
                hasTranscript: transcriptExists
            ))
        }

        // Sort newest first
        meetings = result.sorted { $0.date > $1.date }
    }

    // MARK: - File Watching

    private func startWatching() {
        let fd = open(rootFolder.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    // MARK: - Helpers

    private func sanitizedFolderName(_ name: String?) -> String {
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            // Remove filesystem-unsafe characters
            let safe = name.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_")).inverted).joined()
            let uniqueName = uniqueFolderName(safe.isEmpty ? "Meeting" : safe)
            return uniqueName
        }
        // Fallback to timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: Date())
    }

    private func uniqueFolderName(_ base: String) -> String {
        var name = base
        var counter = 1
        while fileManager.fileExists(atPath: rootFolder.appendingPathComponent(name).path) {
            name = "\(base) \(counter)"
            counter += 1
        }
        return name
    }

    private func displayName(from folderName: String) -> String {
        // Try parsing as timestamp format: yyyy-MM-dd_HH-mm-ss
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        if let date = formatter.date(from: folderName) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        // Otherwise use the folder name as-is
        return folderName
    }
}
