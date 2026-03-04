import SwiftUI

/// Shared state for in-document find (Cmd+F when a note or transcript is open).
///
/// Published by ContentView, consumed by MeetingDetailView and BlockNoteEditorView.
@MainActor
final class InDocumentSearch: ObservableObject {
    static let shared = InDocumentSearch()

    /// Whether the in-document search bar is visible.
    @Published var isActive = false

    /// The current search query.
    @Published var query = ""

    /// For transcript search: IDs of entries whose text matches the query.
    @Published var matchingEntryIDs: [UUID] = []

    /// Index into `matchingEntryIDs` for the currently focused match.
    @Published var currentMatchIndex: Int = 0

    /// Total number of matches (used for "N of M" display).
    var matchCount: Int { matchingEntryIDs.count }

    /// The ID of the currently focused match (for scroll-to).
    var currentMatchID: UUID? {
        guard !matchingEntryIDs.isEmpty,
              currentMatchIndex >= 0,
              currentMatchIndex < matchingEntryIDs.count else { return nil }
        return matchingEntryIDs[currentMatchIndex]
    }

    private init() {}

    func activate() {
        isActive = true
    }

    func dismiss() {
        isActive = false
        query = ""
        matchingEntryIDs = []
        currentMatchIndex = 0
    }

    func nextMatch() {
        guard !matchingEntryIDs.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matchingEntryIDs.count
    }

    func previousMatch() {
        guard !matchingEntryIDs.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matchingEntryIDs.count) % matchingEntryIDs.count
    }

    /// Update matches for transcript search based on entries and query.
    func updateTranscriptMatches(entries: [TranscriptEntry]) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else {
            matchingEntryIDs = []
            currentMatchIndex = 0
            return
        }
        matchingEntryIDs = entries.compactMap { entry in
            let text = "\(entry.speaker) \(entry.text)".lowercased()
            return text.contains(q) ? entry.id : nil
        }
        // Clamp current index
        if currentMatchIndex >= matchingEntryIDs.count {
            currentMatchIndex = 0
        }
    }
}

// MARK: - Overlay View

/// A floating semi-transparent search bar overlaid at the top-right of the content area.
/// Shows match count, prev/next buttons, and auto-focuses the text field.
struct InDocumentSearchBar: View {
    @ObservedObject var search: InDocumentSearch
    @FocusState private var isFocused: Bool

    /// Called when the query changes — the parent view decides what to do
    /// (transcript highlight vs. WKWebView find).
    var onQueryChanged: ((String) -> Void)?

    /// Called when prev/next is pressed (for WKWebView navigation).
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    /// Called when the search bar is dismissed (Escape or close button).
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 11))

            TextField("Find in document...", text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFocused)
                .onSubmit { search.nextMatch(); onNext?() }
                .onChange(of: search.query) { _, newValue in
                    onQueryChanged?(newValue)
                }

            // Match count
            if !search.query.isEmpty {
                if search.matchCount > 0 {
                    Text("\(search.currentMatchIndex + 1) of \(search.matchCount)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("No matches")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Prev / Next buttons
            Button {
                search.previousMatch()
                onPrevious?()
            } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(search.matchCount == 0)

            Button {
                search.nextMatch()
                onNext?()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(search.matchCount == 0)

            // Close button
            Button {
                dismissSearch()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .frame(maxWidth: 340)
        .onAppear {
            // Aggressive focus attempts since this is overlaid
            for delay in [0.05, 0.15, 0.3] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    isFocused = true
                }
            }
        }
        .onAppear {
            // Monitor Escape key globally while this bar is visible.
            // .onKeyPress(.escape) only works if the SwiftUI view has focus,
            // but focus may be in the NSTextField or the WKWebView.
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape
                    dismissSearch()
                    return nil // consume the event
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = escapeMonitor {
                NSEvent.removeMonitor(monitor)
                escapeMonitor = nil
            }
        }
    }

    @State private var escapeMonitor: Any?

    private func dismissSearch() {
        search.dismiss()
        onDismiss?()
    }
}
