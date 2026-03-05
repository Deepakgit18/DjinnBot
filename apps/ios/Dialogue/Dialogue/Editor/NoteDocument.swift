import DialogueCore
import Foundation
import OSLog

/// A lightweight note document for iOS that wraps a `BlockNoteFile`.
/// Manages loading/saving to the app's documents directory.
@MainActor
final class NoteDocument: ObservableObject, Identifiable, Hashable {
    nonisolated static func == (lhs: NoteDocument, rhs: NoteDocument) -> Bool { lhs.id == rhs.id }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: UUID
    let createdAt: Date
    @Published var file: BlockNoteFile
    @Published var hasUnsavedChanges = false

    private let logger = Logger(subsystem: "bot.djinn.ios.dialogue", category: "NoteDocument")

    var title: String { file.title }

    init(id: UUID = UUID(), file: BlockNoteFile = .empty, createdAt: Date = Date()) {
        self.id = id
        self.file = file
        self.createdAt = createdAt
    }

    // MARK: - Update from editor bridge

    func updateBlocks(from jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let blocks = try? JSONDecoder().decode([JSONValue].self, from: data) else { return }
        file.blocks = blocks
        hasUnsavedChanges = true
    }

    func updateTitle(_ title: String) {
        file.title = title
        hasUnsavedChanges = true
    }

    // MARK: - Persistence

    static var notesDirectory: URL {
        DocumentManager.dialogueFolder.appendingPathComponent("Notes", isDirectory: true)
    }

    func save() {
        let dir = Self.notesDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(id.uuidString).blocknote")
        do {
            let wrapper = NoteWrapper(id: id, createdAt: createdAt, file: file)
            let data = try JSONEncoder().encode(wrapper)
            try data.write(to: url, options: .atomic)
            hasUnsavedChanges = false
            logger.info("Saved note: \(self.file.title)")
        } catch {
            logger.error("Failed to save note: \(error)")
        }
    }

    func delete() {
        let url = Self.notesDirectory.appendingPathComponent("\(id.uuidString).blocknote")
        try? FileManager.default.removeItem(at: url)
    }

    static func loadAll() -> [NoteDocument] {
        let dir = notesDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "blocknote" }) else { return [] }

        return files.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let wrapper = try? JSONDecoder().decode(NoteWrapper.self, from: data) else { return nil }
            return NoteDocument(id: wrapper.id, file: wrapper.file, createdAt: wrapper.createdAt)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
}

// MARK: - Persistence wrapper

private struct NoteWrapper: Codable {
    let id: UUID
    let createdAt: Date
    let file: BlockNoteFile
}
