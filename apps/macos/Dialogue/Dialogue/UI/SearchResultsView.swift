import DialogueCore
import SwiftUI
import AppKit

// MARK: - Animated Search Bar (Toolbar)

/// A magnifying glass icon that expands into a search text field when tapped.
/// Lives in the toolbar to the left of the recording button.
///
/// Uses an NSViewRepresentable `NSTextField` because SwiftUI's `@FocusState`
/// does not reliably work inside NSToolbar hosting views.
struct ToolbarSearchBar: View {
    @Binding var isActive: Bool
    @Binding var query: String
    var onCommit: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if isActive {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))

                FocusableTextField(
                    text: $query,
                    placeholder: "Search notes & transcripts...",
                    onCommit: onCommit
                )
                .frame(height: 18)

                if !query.isEmpty {
                    Button {
                        query = ""
                        onCommit()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isActive = false
                        query = ""
                    }
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isActive = true
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Search (Cmd+Shift+F)")
            }
        }
        .padding(.horizontal, isActive ? 6 : 0)
        .padding(.vertical, isActive ? 2 : 0)
        .frame(width: isActive ? 220 : 20)
        // On macOS 26+, the toolbar automatically applies liquid glass
        // to its items — we don't add our own glass effect. The text
        // field has no border/background so it blends into the toolbar's
        // native glass seamlessly. On older macOS, fall back to a subtle
        // material capsule.
        .modifier(SearchBarBackgroundModifier(isActive: isActive))
    }
}

/// On pre-macOS 26, adds a subtle material background. On macOS 26+, does nothing —
/// the toolbar's native liquid glass handles the visual.
private struct SearchBarBackgroundModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
        } else {
            content
                .background {
                    if isActive {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
                            )
                    }
                }
        }
    }
}

// MARK: - NSTextField wrapper that reliably grabs focus

/// An `NSViewRepresentable` wrapping `NSTextField` that calls
/// `window.makeFirstResponder()` directly, bypassing SwiftUI's broken
/// `@FocusState` in toolbar contexts.
private struct FocusableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onCommit: () -> Void

    func makeNSView(context: Context) -> AutoFocusTextField {
        let field = AutoFocusTextField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.delegate = context.coordinator
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: AutoFocusTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        let parent: FocusableTextField

        init(parent: FocusableTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            parent.onCommit()
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                parent.onCommit()
                return true
            }
            return false
        }
    }
}

/// NSTextField subclass that grabs first responder when moved to a window.
private class AutoFocusTextField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // Delay slightly so the field is fully in the responder chain
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(self)
        }
    }
}

// MARK: - Search Results View (Detail Pane)

/// Displays search results grouped by type (notes, transcripts) with clear visual distinction.
struct SearchResultsView: View {
    let results: [SearchResult]
    let query: String
    var onSelectNote: (URL) -> Void
    var onSelectTranscript: (SavedMeeting, UUID) -> Void

    /// The individual words from the query, used for highlighting matches in results.
    private var queryTerms: [String] {
        query.lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                Text("Results for \"\(query)\"")
                    .font(.headline)
                Spacer()
                Text("\(results.count) found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if results.isEmpty {
                emptyState
            } else {
                resultsList
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("No results found")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Try different keywords or check spelling")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Results List

    private var resultsList: some View {
        let noteResults = results.filter {
            if case .note = $0.kind { return true }
            return false
        }
        let transcriptResults = results.filter {
            if case .transcript = $0.kind { return true }
            return false
        }

        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !noteResults.isEmpty {
                    sectionHeader("Notes", count: noteResults.count, icon: "doc.text")
                    ForEach(noteResults) { result in
                        NoteResultRow(result: result, queryTerms: queryTerms) {
                            if case .note(let url) = result.kind {
                                onSelectNote(url)
                            }
                        }
                    }
                }

                if !transcriptResults.isEmpty {
                    if !noteResults.isEmpty {
                        Divider().padding(.vertical, 8)
                    }
                    sectionHeader("Meeting Transcripts", count: transcriptResults.count, icon: "text.bubble")
                    ForEach(transcriptResults) { result in
                        TranscriptResultRow(result: result, queryTerms: queryTerms) {
                            if case .transcript(let meeting, let entryID) = result.kind {
                                onSelectTranscript(meeting, entryID)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func sectionHeader(_ title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("(\(count))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

// MARK: - Note Result Row

private struct NoteResultRow: View {
    let result: SearchResult
    let queryTerms: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                // Type badge
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.blue.opacity(0.12))
                    Image(systemName: "doc.text")
                        .foregroundStyle(.blue)
                        .font(.system(size: 12))
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    highlightedText(result.title, terms: queryTerms)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    if !result.snippet.isEmpty {
                        highlightedText(result.snippet, terms: queryTerms)
                            .font(.caption)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        Text("Note")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.blue)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))

                        Text(result.date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // Score indicator
                scoreIndicator(result.score)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.001)) // Ensure hit testing
    }
}

// MARK: - Transcript Result Row

private struct TranscriptResultRow: View {
    let result: SearchResult
    let queryTerms: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                // Type badge
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.12))
                    Image(systemName: "text.bubble")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    highlightedText(result.title, terms: queryTerms)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)

                    if !result.snippet.isEmpty {
                        highlightedText(result.snippet, terms: queryTerms)
                            .font(.caption)
                            .lineLimit(2)
                    }

                    HStack(spacing: 8) {
                        Text("Transcript")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 3))

                        Text(result.date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                Spacer()

                // Score indicator
                scoreIndicator(result.score)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.001))
    }
}

// MARK: - Score Indicator

private func scoreIndicator(_ score: Double) -> some View {
    let bars: Int
    if score >= 0.9 { bars = 4 }
    else if score >= 0.7 { bars = 3 }
    else if score >= 0.5 { bars = 2 }
    else { bars = 1 }

    let activeColor = Color.blue
    let inactiveColor = Color.primary.opacity(0.1)

    return HStack(spacing: 1.5) {
        ForEach(0..<4, id: \.self) { i in
            RoundedRectangle(cornerRadius: 1)
                .fill(i < bars ? activeColor : inactiveColor)
                .frame(width: 3, height: CGFloat(6 + i * 2))
        }
    }
    .frame(width: 20)
    .help(String(format: "Match: %.0f%%", score * 100))
}

// MARK: - Highlighted Text Helper

/// Builds a `Text` view where all occurrences of the query terms are highlighted
/// with a yellow/orange background and bold weight using `AttributedString`.
///
/// Performs case-insensitive matching of each query term independently.
private func highlightedText(_ text: String, terms: [String]) -> Text {
    guard !terms.isEmpty, !text.isEmpty else {
        return Text(text)
    }

    var attributed = AttributedString(text)

    for term in terms {
        guard !term.isEmpty else { continue }
        // Find all case-insensitive occurrences of this term
        var searchRange = attributed.startIndex..<attributed.endIndex
        while let found = attributed[searchRange].range(of: term, options: .caseInsensitive) {
            attributed[found].backgroundColor = .yellow.opacity(0.35)
            attributed[found].inlinePresentationIntent = .stronglyEmphasized
            // Advance past this match
            if found.upperBound < attributed.endIndex {
                searchRange = found.upperBound..<attributed.endIndex
            } else {
                break
            }
        }
    }

    return Text(attributed)
}

// MARK: - Back to Search Banner

/// A thin banner shown below the title bar when navigating from a search result.
/// Allows the user to return to their search results without re-typing.
struct BackToSearchBanner: View {
    let query: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.left")
                .font(.caption.weight(.semibold))
                .foregroundColor(.blue)
            Text("Back to search results for \"\(query)\"")
                .font(.caption)
                .foregroundColor(.blue)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }
}
