import Foundation
import OSLog

/// Central in-memory log store that collects structured debug entries
/// from across the app. Entries are displayed in the Debug Log window.
///
/// Usage:
///   LogStore.shared.log("Starting mic capture", category: .audio)
///   LogStore.shared.log("Error: \(err)", category: .audio, level: .error)
///
/// The store keeps a rolling buffer of the most recent entries (capped at
/// `maxEntries`) to avoid unbounded memory growth during long sessions.
@MainActor
public final class LogStore: ObservableObject {
    public static let shared = LogStore()

    // MARK: - Types

    public enum Level: String, CaseIterable, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"

        public var icon: String {
            switch self {
            case .debug: return "ant"
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.circle"
            }
        }
    }

    public enum Category: String, CaseIterable, Sendable {
        case audio = "Audio"
        case recording = "Recording"
        case voiceEnrollment = "VoiceEnrollment"
        case voiceID = "VoiceID"
        case pipeline = "Pipeline"
        case diarization = "Diarization"
        case app = "App"
        case meeting = "Meeting"

    }

    public struct Entry: Identifiable {
        public let id = UUID()
        public let timestamp: Date
        public let level: Level
        public let category: Category
        public let message: String

        public var formattedTimestamp: String {
            Self.formatter.string(from: timestamp)
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    // MARK: - State

    @Published public private(set) var entries: [Entry] = []
    @Published public var filterLevel: Level? = nil
    @Published public var filterCategory: Category? = nil
    @Published public var searchText: String = ""

    private let maxEntries = 5000

    public var filteredEntries: [Entry] {
        entries.filter { entry in
            if let level = filterLevel, entry.level != level { return false }
            if let category = filterCategory, entry.category != category { return false }
            if !searchText.isEmpty,
               !entry.message.localizedCaseInsensitiveContains(searchText) {
                return false
            }
            return true
        }
    }

    // MARK: - Logging

    /// Add a log entry. Safe to call from any context — dispatches to main if needed.
    nonisolated public func log(
        _ message: String,
        category: Category,
        level: Level = .info
    ) {
        let entry = Entry(timestamp: Date(), level: level, category: category, message: message)
        Task { @MainActor in
            self.append(entry)
        }
    }

    private func append(_ entry: Entry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    /// Clear all entries.
    public func clear() {
        entries.removeAll()
    }

    /// Export all entries as a plain text string.
    public func exportText() -> String {
        filteredEntries.map { entry in
            "[\(entry.formattedTimestamp)] [\(entry.level.rawValue)] [\(entry.category.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
    }
}
