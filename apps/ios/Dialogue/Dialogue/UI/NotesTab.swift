import DialogueCore
import SwiftUI

/// Notes tab — lists saved notes and opens the BlockNote editor.
struct NotesTab: View {
    @State private var notes: [NoteDocument] = []
    @State private var selectedNote: NoteDocument?

    var body: some View {
        NavigationStack {
            Group {
                if notes.isEmpty {
                    ContentUnavailableView(
                        "No Notes",
                        systemImage: "doc.text",
                        description: Text("Tap + to create a new note.")
                    )
                } else {
                    List {
                        ForEach(notes) { note in
                            Button {
                                selectedNote = note
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(note.title)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(note.createdAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                        .onDelete(perform: deleteNotes)
                    }
                }
            }
            .navigationTitle("Notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        createNewNote()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fullScreenCover(item: $selectedNote) { note in
                NoteEditorScreen(document: note) {
                    note.save()
                    loadNotes()
                }
            }
            .onAppear {
                loadNotes()
            }
        }
    }

    private func createNewNote() {
        let note = NoteDocument()
        note.save()
        notes.insert(note, at: 0)
        selectedNote = note
    }

    private func deleteNotes(at offsets: IndexSet) {
        for index in offsets {
            notes[index].delete()
        }
        notes.remove(atOffsets: offsets)
    }

    private func loadNotes() {
        notes = NoteDocument.loadAll()
    }
}

// MARK: - Full-screen editor

struct NoteEditorScreen: View {
    @ObservedObject var document: NoteDocument
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            BlockNoteEditorView(document: document)
                .ignoresSafeArea(.container, edges: .bottom)
                .navigationTitle(document.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Done") {
                            document.save()
                            onDismiss()
                            dismiss()
                        }
                    }
                }
        }
    }
}
