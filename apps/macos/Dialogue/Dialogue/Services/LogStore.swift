import Foundation
import OSLog
import SwiftUI

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
final class LogStore: ObservableObject {
    static let shared = LogStore()

    // MARK: - Types

    enum Level: String, CaseIterable, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"

        var color: Color {
            switch self {
            case .debug: return .secondary
            case .info: return .primary
            case .warning: return .orange
            case .error: return .red
            }
        }

        var icon: String {
            switch self {
            case .debug: return "ant"
            case .info: return "info.circle"
            case .warning: return "exclamationmark.triangle"
            case .error: return "xmark.circle"
            }
        }
    }

    enum Category: String, CaseIterable, Sendable {
        case audio = "Audio"
        case recording = "Recording"
        case voiceEnrollment = "VoiceEnrollment"
        case voiceID = "VoiceID"
        case pipeline = "Pipeline"
        case diarization = "Diarization"
        case app = "App"
        case meeting = "Meeting"

        var color: Color {
            switch self {
            case .audio: return .blue
            case .recording: return .red
            case .voiceEnrollment: return .purple
            case .voiceID: return .indigo
            case .pipeline: return .cyan
            case .diarization: return .teal
            case .app: return .gray
            case .meeting: return .green
            }
        }
    }

    struct Entry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let category: Category
        let message: String

        var formattedTimestamp: String {
            Self.formatter.string(from: timestamp)
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    // MARK: - State

    @Published private(set) var entries: [Entry] = []
    @Published var filterLevel: Level? = nil
    @Published var filterCategory: Category? = nil
    @Published var searchText: String = ""

    private let maxEntries = 5000

    var filteredEntries: [Entry] {
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
    nonisolated func log(
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
    func clear() {
        entries.removeAll()
    }

    /// Export all entries as a plain text string.
    func exportText() -> String {
        filteredEntries.map { entry in
            "[\(entry.formattedTimestamp)] [\(entry.level.rawValue)] [\(entry.category.rawValue)] \(entry.message)"
        }.joined(separator: "\n")
    }
}
