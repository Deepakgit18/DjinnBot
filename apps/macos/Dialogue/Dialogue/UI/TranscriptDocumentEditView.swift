import SwiftUI
import AppKit

/// Full-document transcript editing view.
///
/// Presents the entire transcript as a single editable plain-text document
/// using marker-delimited segments. On save, the edited text is parsed back
/// into `TranscriptEntry` values. Parse errors are shown inline with
/// highlighting, allowing the user to fix problems without losing work.
struct TranscriptDocumentEditView: View {
    let originalEntries: [TranscriptEntry]
    let onSave: ([TranscriptEntry]) -> Void

    @Environment(\.dismiss) private var dismiss

    /// The raw edited text — preserved across error/fix cycles.
    @State private var documentText: String = ""
    /// Whether we've initialized the text from originalEntries.
    @State private var didInitialize = false

    /// Parse result from the most recent save attempt.
    @State private var parseResult: ParseResult?
    /// Whether to show the error detail panel.
    @State private var showErrors = false

    /// Deletion confirmation.
    @State private var pendingDeletions: [TranscriptEntry] = []
    @State private var showDeleteConfirm = false

    /// Whether an unsaved-changes warning is needed.
    @State private var showDiscardConfirm = false

    /// Track whether user has made changes.
    @State private var hasChanges = false

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            toolbar
            Divider()

            if showErrors, let result = parseResult, result.hasErrors {
                // Split view: editor + error panel
                HSplitView {
                    editorPane
                    errorPanel(result: result)
                        .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
                }
            } else {
                editorPane
            }

            Divider()
            bottomBar
        }
        .frame(minWidth: 700, idealWidth: 900, minHeight: 500, idealHeight: 700)
        .onAppear {
            if !didInitialize {
                documentText = TranscriptDocumentEditor.serialize(originalEntries)
                didInitialize = true
            }
        }
        .alert("Discard Changes?", isPresented: $showDiscardConfirm) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You have unsaved edits. Discarding will lose all changes.")
        }
        .alert("Delete Segments?", isPresented: $showDeleteConfirm) {
            Button("Delete \(pendingDeletions.count) Segment\(pendingDeletions.count == 1 ? "" : "s")", role: .destructive) {
                applyWithDeletions()
            }
            Button("Cancel", role: .cancel) {
                // Don't apply — let user re-add the segments
            }
        } message: {
            let names = pendingDeletions.prefix(5).map { entry in
                let time = formatTimestamp(entry.start)
                return "\(time) \(entry.speaker): \(String(entry.text.prefix(40)))\(entry.text.count > 40 ? "..." : "")"
            }
            let extra = pendingDeletions.count > 5 ? "\n...and \(pendingDeletions.count - 5) more" : ""
            Text("The following segments were removed:\n\n\(names.joined(separator: "\n"))\(extra)")
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Edit Transcript")
                .font(.headline)

            Spacer()

            if let result = parseResult {
                if result.hasErrors {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("\(result.errors.count) error\(result.errors.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("All segments valid")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button("Reset") {
                documentText = TranscriptDocumentEditor.serialize(originalEntries)
                parseResult = nil
                showErrors = false
                hasChanges = false
            }
            .buttonStyle(.bordered)
            .help("Reset to original transcript")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Editor Pane

    private var editorPane: some View {
        DocumentNSTextView(
            text: $documentText,
            parseErrors: parseResult?.errors ?? [],
            onTextChange: {
                hasChanges = true
                // Clear stale parse results when user edits
                if parseResult != nil {
                    parseResult = nil
                    showErrors = false
                }
            }
        )
    }

    // MARK: - Error Panel

    private func errorPanel(result: ParseResult) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Parse Errors")
                    .font(.headline)
                Spacer()
                Button {
                    showErrors = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(result.errors) { error in
                        errorCard(error)
                    }
                }
                .padding(12)
            }

            Divider()

            // Apply valid changes only
            if !result.matches.isEmpty {
                HStack {
                    Spacer()
                    Button("Apply Valid Changes Only") {
                        applyPartial(result: result)
                    }
                    .buttonStyle(.bordered)
                    .help("Save changes for \(result.matches.count) valid segments; leave errored segments unchanged")
                    Spacer()
                }
                .padding(8)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func errorCard(_ error: SegmentError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Error reason
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.caption)
                Text(error.reason.localizedDescription)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The problematic marker
            Text(error.markerLine)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.red)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))

            // Location
            Text("Line \(error.lineRange.lowerBound + 1)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            // Format guide
            Text("Segment markers look like: «seg:XXXXXXXX | 0:12 Speaker [Local]» — don't modify the seg: codes")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer()

            Button("Cancel") {
                if hasChanges {
                    showDiscardConfirm = true
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.cancelAction)

            if showErrors, let result = parseResult, result.hasErrors {
                Button("Re-parse") {
                    attemptSave()
                }
                .buttonStyle(.borderedProminent)
                .help("Re-parse the document after fixing errors")
            } else {
                Button("Save") {
                    attemptSave()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Save Logic

    private func attemptSave() {
        let result = TranscriptDocumentEditor.parse(documentText, original: originalEntries)
        parseResult = result

        if result.hasErrors {
            showErrors = true
            return
        }

        // Check for deletions
        if !result.deletedEntryIDs.isEmpty {
            pendingDeletions = originalEntries.filter { result.deletedEntryIDs.contains($0.id) }
            showDeleteConfirm = true
            return
        }

        // Clean save — no errors, no deletions
        let entries = result.buildEntries()
        onSave(entries)
        dismiss()
    }

    private func applyWithDeletions() {
        guard let result = parseResult else { return }
        let entries = result.buildEntries()
        onSave(entries)
        dismiss()
    }

    private func applyPartial(result: ParseResult) {
        // Build entries using only matched segments + keep errored ones from original
        var entriesByID: [UUID: TranscriptEntry] = [:]
        for orig in originalEntries {
            entriesByID[orig.id] = orig
        }

        // Apply matched edits
        for match in result.matches {
            if let orig = entriesByID[match.entryID] {
                entriesByID[match.entryID] = TranscriptEntry(
                    id: orig.id,
                    speaker: match.newSpeaker,
                    start: orig.start,
                    end: orig.end,
                    text: match.newText,
                    stream: match.stream,
                    isFinal: orig.isFinal
                )
            }
        }

        // Don't remove any deletions in partial mode — keep everything
        let entries = entriesByID.values.sorted { $0.start < $1.start }
        onSave(entries)
        dismiss()
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let totalSeconds = Int(time)
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

// MARK: - DocumentNSTextView (NSViewRepresentable)

/// A large NSTextView for editing the full transcript document.
/// Highlights lines that contain parse errors with a red background.
private struct DocumentNSTextView: NSViewRepresentable {
    @Binding var text: String
    let parseErrors: [SegmentError]
    let onTextChange: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text
        textView.delegate = context.coordinator

        // Style marker lines
        applyMarkerStyling(textView)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        // Don't update text while user is editing (causes cursor jump)
        if !context.coordinator.isEditing && textView.string != text {
            textView.string = text
        }

        // Apply error highlighting
        applyMarkerStyling(textView)
        applyErrorHighlighting(textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    /// Style marker lines differently (dimmer, slightly smaller) so they
    /// visually recede and the body text stands out.
    private func applyMarkerStyling(_ textView: NSTextView) {
        guard let textStorage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let string = textStorage.string as NSString

        // Reset to default style
        let defaultFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let defaultColor = NSColor.labelColor
        textStorage.beginEditing()
        textStorage.addAttribute(.font, value: defaultFont, range: fullRange)
        textStorage.addAttribute(.foregroundColor, value: defaultColor, range: fullRange)
        textStorage.removeAttribute(.backgroundColor, range: fullRange)

        // Find marker lines and style them
        let markerFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let markerColor = NSColor.secondaryLabelColor

        string.enumerateSubstrings(in: fullRange, options: .byLines) { substring, range, _, _ in
            guard let line = substring?.trimmingCharacters(in: .whitespaces) else { return }
            if line.hasPrefix("«") && line.hasSuffix("»") {
                textStorage.addAttribute(.font, value: markerFont, range: range)
                textStorage.addAttribute(.foregroundColor, value: markerColor, range: range)
            }
        }

        textStorage.endEditing()
    }

    /// Highlight error lines with a red background tint.
    private func applyErrorHighlighting(_ textView: NSTextView) {
        guard let textStorage = textView.textStorage, !parseErrors.isEmpty else { return }
        let string = textStorage.string as NSString

        // Build a set of error line numbers
        var errorLines = Set<Int>()
        for error in parseErrors {
            for line in error.lineRange {
                errorLines.insert(line)
            }
        }

        guard !errorLines.isEmpty else { return }

        // Walk lines and highlight error ones
        let fullRange = NSRange(location: 0, length: string.length)
        var lineNumber = 0
        let errorBg = NSColor.systemRed.withAlphaComponent(0.15)

        textStorage.beginEditing()
        string.enumerateSubstrings(in: fullRange, options: .byLines) { _, range, enclosingRange, _ in
            if errorLines.contains(lineNumber) {
                textStorage.addAttribute(.backgroundColor, value: errorBg, range: enclosingRange)
            }
            lineNumber += 1
        }
        textStorage.endEditing()
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: DocumentNSTextView
        var isEditing = false

        init(parent: DocumentNSTextView) {
            self.parent = parent
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.onTextChange()
        }
    }
}
