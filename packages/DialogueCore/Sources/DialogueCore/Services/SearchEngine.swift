import Foundation
import FuzzyMatch

/// A search result from the unified search engine covering both notes and meeting transcripts.
public struct SearchResult: Identifiable {
    public let id = UUID()
    public let kind: Kind
    public let title: String
    public let snippet: String
    public let score: Double
    public let date: Date

    public enum Kind {
        /// A .blocknote note file. `url` is the file path.
        case note(url: URL)
        /// A meeting transcript entry. Contains the meeting and entry ID for scroll-to.
        case transcript(meeting: SavedMeeting, entryID: UUID)
    }
}

/// Indexes all notes and meeting transcripts, provides fuzzy search via FuzzyMatch.
///
/// Usage:
/// ```
/// let engine = SearchEngine()
/// engine.reindex()
/// let results = engine.search("my query")
/// ```
@MainActor
public final class SearchEngine: ObservableObject {
    public static let shared = SearchEngine()

    @Published public var results: [SearchResult] = []
    @Published public var isIndexing = false

    private var noteEntries: [NoteEntry] = []
    private var transcriptEntries: [TranscriptSearchEntry] = []

    private let matcher = FuzzyMatcher(config: MatchConfig(
        minScore: 0.3,
        algorithm: .editDistance(EditDistanceConfig(
            maxEditDistance: 3,
            prefixWeight: 2.0,
            substringWeight: 1.0,
            wordBoundaryBonus: 0.1,
            consecutiveBonus: 0.05
        ))
    ))

    private init() {}

    // MARK: - Internal Types

    private struct NoteEntry {
        let url: URL
        let title: String
        let text: String  // Full extracted text for searching
        let date: Date
    }

    private struct TranscriptSearchEntry {
        let meeting: SavedMeeting
        let entry: TranscriptEntry
        let searchText: String  // "speaker: text"
    }

    // MARK: - Indexing

    /// Rebuild the search index from all notes and meetings.
    public func reindex() {
        isIndexing = true
        indexNotes()
        indexTranscripts()
        isIndexing = false
    }

    private func indexNotes() {
        noteEntries = []
        let dm = DocumentManager.shared
        collectNotes(from: dm.rootFolder)
    }

    private func collectNotes(from directory: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for item in contents {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                collectNotes(from: item)
            } else if item.pathExtension == "blocknote" {
                guard let data = try? Data(contentsOf: item),
                      let file = try? BlockNoteFile.fromJSON(data) else { continue }

                let text = extractText(from: file)
                let modDate = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                // Use the filename (without extension) as the title — matches sidebar display
                let title = item.deletingPathExtension().lastPathComponent

                noteEntries.append(NoteEntry(
                    url: item,
                    title: title,
                    text: text,
                    date: modDate
                ))
            }
        }
    }

    /// Extract all user-visible text from a BlockNoteFile's blocks.
    private func extractText(from file: BlockNoteFile) -> String {
        var parts: [String] = []
        if !file.title.isEmpty {
            parts.append(file.title)
        }
        for block in file.blocks {
            collectStrings(from: block, into: &parts)
        }
        return parts.joined(separator: " ")
    }

    /// Walk a JSONValue tree and collect all string values that appear as "text" keys
    /// in objects, which is how BlockNote stores inline text content.
    private func collectStrings(from value: JSONValue, into parts: inout [String]) {
        switch value {
        case .string:
            // Only collect strings when they're values of "text" keys (handled in .object case)
            break
        case .object(let dict):
            // If this object has a "text" key with a string value, collect it
            if case .string(let s) = dict["text"], !s.trimmingCharacters(in: .whitespaces).isEmpty {
                parts.append(s)
            }
            // Recurse into all values (content arrays, children, etc.)
            for (_, v) in dict {
                collectStrings(from: v, into: &parts)
            }
        case .array(let arr):
            for item in arr {
                collectStrings(from: item, into: &parts)
            }
        default:
            break
        }
    }

    private func indexTranscripts() {
        transcriptEntries = []
        let store = MeetingStore.shared
        for meeting in store.meetings {
            guard let entries = store.loadTranscript(for: meeting) else { continue }
            for entry in entries {
                let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                transcriptEntries.append(TranscriptSearchEntry(
                    meeting: meeting,
                    entry: entry,
                    searchText: "\(entry.speaker): \(trimmed)"
                ))
            }
        }
    }

    // MARK: - Search

    /// Perform a fuzzy search across all indexed content.
    ///
    /// Notes are searched by title AND by individual text chunks (sentences/paragraphs),
    /// taking the best score. This avoids the problem of matching a short query against
    /// an entire document body. Each transcript entry is scored individually.
    /// Results are sorted by score descending, limited to top 50.
    public func search(_ query: String) -> [SearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let prepared = matcher.prepare(trimmed)
        var buffer = matcher.makeBuffer()
        var results: [SearchResult] = []

        // Search notes — match against title and individual text chunks
        for note in noteEntries {
            var bestScore: Double = 0
            var bestSnippet = ""

            // Score the title
            if let titleMatch = matcher.score(note.title, against: prepared, buffer: &buffer) {
                bestScore = titleMatch.score
                bestSnippet = note.title
            }

            // Split text into chunks (sentences/short paragraphs) for better matching
            let chunks = splitIntoChunks(note.text)
            for chunk in chunks {
                if let chunkMatch = matcher.score(chunk, against: prepared, buffer: &buffer) {
                    if chunkMatch.score > bestScore {
                        bestScore = chunkMatch.score
                        bestSnippet = chunk.count > 140 ? String(chunk.prefix(140)) + "..." : chunk
                    }
                }
            }

            guard bestScore > 0 else { continue }

            results.append(SearchResult(
                kind: .note(url: note.url),
                title: note.title,
                snippet: bestSnippet,
                score: bestScore,
                date: note.date
            ))
        }

        // Search transcript entries — match against the combined "speaker: text"
        for tEntry in transcriptEntries {
            guard let match = matcher.score(tEntry.searchText, against: prepared, buffer: &buffer) else {
                continue
            }

            let text = tEntry.entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = text.count > 120 ? String(text.prefix(120)) + "..." : text

            results.append(SearchResult(
                kind: .transcript(meeting: tEntry.meeting, entryID: tEntry.entry.id),
                title: tEntry.meeting.displayName,
                snippet: "\(tEntry.entry.speaker): \(snippet)",
                score: match.score,
                date: tEntry.meeting.date
            ))
        }

        // Sort by score descending, then by date descending for ties
        results.sort { a, b in
            if abs(a.score - b.score) > 0.001 {
                return a.score > b.score
            }
            return a.date > b.date
        }

        // Limit to top 50 results for performance
        return Array(results.prefix(50))
    }

    /// Split text into manageable chunks for matching.
    /// Produces sentence-level chunks capped at ~200 chars each.
    private func splitIntoChunks(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        // Split by sentence-ending punctuation or newlines
        let separators = CharacterSet(charactersIn: ".!?\n")
        let parts = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // If we got reasonable chunks, return them
        if parts.count > 1 { return parts }

        // Fallback: split long text into ~200 char windows
        if text.count > 200 {
            var chunks: [String] = []
            var start = text.startIndex
            while start < text.endIndex {
                let end = text.index(start, offsetBy: 200, limitedBy: text.endIndex) ?? text.endIndex
                chunks.append(String(text[start..<end]))
                start = end
            }
            return chunks
        }

        return [text]
    }

    // (snippet building is now inline in the search method)
}
