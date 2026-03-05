import DialogueCore
import SwiftUI
import WebKit

/// Displays an AI-generated meeting summary inside a BlockNote editor.
///
/// The summary is stored as raw Markdown in `summary.json` (inside the meeting folder).
/// On first load, the Markdown is parsed into BlockNote blocks via the JS bridge function
/// `window.loadMarkdown()` which calls `editor.tryParseMarkdownToBlocks()`.
///
/// The editor is **editable** so users can check action-item checkboxes, add notes, etc.
/// Changes are auto-saved back to `summary.json` as updated markdown.
struct MeetingSummaryView: View {
    let meeting: SavedMeeting

    /// The raw markdown loaded from summary.json.
    @State private var markdown: String?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let error = loadError {
                errorState(error)
            } else if let markdown {
                SummaryEditorWebView(markdown: markdown, meeting: meeting)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView("Loading summary...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadSummary()
        }
    }

    private func loadSummary() {
        if let md = MeetingIngestService.loadSummaryMarkdown(for: meeting) {
            markdown = md
        } else {
            loadError = "Could not read summary.json"
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text("Failed to Load Summary")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Summary Editor WebView

/// A standalone WKWebView that loads the BlockNote editor and injects the summary
/// markdown via `window.loadMarkdown()`.
///
/// Intentionally separate from `BlockNoteEditorView` because:
/// - It uses `loadMarkdown` (not `loadDocument`) to parse markdown into blocks
/// - It auto-saves changes back to `summary.json` via a blocks→markdown export
/// - It has no binding to `BlockNoteDocument` or `AppState.currentDocument`
struct SummaryEditorWebView: NSViewRepresentable {
    let markdown: String
    let meeting: SavedMeeting

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = WKProcessPool()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // Register the bridge handler so we know when "ready" fires
        let controller = config.userContentController
        controller.add(context.coordinator, name: "editorBridge")

        // Inject theme before React renders so BlockNote starts in the
        // correct theme on the very first frame — no light→dark flash.
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark ? "#1e1e1e" : "#ffffff"
        let earlyTheme = WKUserScript(
            source: """
                window.initialTheme = '\(isDark ? "dark" : "light")';
                var s = document.createElement('style');
                s.textContent = 'html, body { background: \(bgColor) !important; }';
                (document.head || document.documentElement).prepend(s);
                """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(earlyTheme)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .windowBackgroundColor

        // Start hidden — reveal once the editor is ready and themed.
        webView.alphaValue = 0

        context.coordinator.markdown = markdown
        context.coordinator.meeting = meeting
        context.coordinator.webView = webView

        // Load the single-file HTML from the bundle — use loadHTMLString
        // exactly like BlockNoteEditorView does (the known-working path).
        if let url = Bundle.main.url(forResource: "index", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            webView.loadHTMLString(html, baseURL: nil)
        }

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // If navigating to a different meeting's summary
        if context.coordinator.markdown != markdown {
            context.coordinator.markdown = markdown
            context.coordinator.meeting = meeting
            if context.coordinator.isReady {
                context.coordinator.injectMarkdown()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var markdown: String = ""
        var meeting: SavedMeeting?
        weak var webView: WKWebView?
        var isReady = false
        private var autosaveTimer: Timer?

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let dict = message.body as? [String: Any],
                  let type = dict["type"] as? String else { return }

            switch type {
            case "ready":
                isReady = true
                onEditorReady()
            case "contentChange":
                // The editor content changed (user checked a box, edited text, etc.)
                // Schedule an autosave to persist changes.
                scheduleAutosave()
            default:
                break
            }
        }

        private func onEditorReady() {
            guard let webView else { return }

            // Set theme (also set via initialTheme, but this syncs the React state)
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let themeCmd = BridgeCommandToJS.setTheme(dark: isDark)
            webView.evaluateJavaScript(themeCmd.javaScript)

            // Load the markdown content
            injectMarkdown()

            // Reveal the editor now that it's themed and content is loaded.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                webView.animator().alphaValue = 1
            }
        }

        func injectMarkdown() {
            guard let webView, !markdown.isEmpty else { return }
            let cmd = BridgeCommandToJS.loadMarkdown(markdown: markdown)
            webView.evaluateJavaScript(cmd.javaScript)
        }

        // MARK: - Autosave

        /// Debounced autosave — waits 1.5s after the last change before saving.
        /// Exports the current editor blocks back to markdown and overwrites summary.json.
        private func scheduleAutosave() {
            autosaveTimer?.invalidate()
            autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                self?.performAutosave()
            }
        }

        private func performAutosave() {
            guard let webView, let meeting else { return }

            // Get the current blocks as JSON, then export to markdown
            let js = """
            (async function() {
                var editor = window.blocknoteEditor;
                if (!editor) return null;
                var md = await editor.blocksToMarkdownLossy(editor.document);
                return md;
            })()
            """

            webView.callAsyncJavaScript(
                js,
                arguments: [:],
                in: nil,
                in: .page
            ) { result in
                switch result {
                case .success(let value):
                    guard let updatedMarkdown = value as? String,
                          !updatedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

                    // Persist back to summary.json
                    let summaryData: [String: Any] = [
                        "version": 1,
                        "format": "markdown",
                        "content": updatedMarkdown,
                    ]
                    guard let data = try? JSONSerialization.data(
                        withJSONObject: summaryData,
                        options: [.prettyPrinted, .sortedKeys]
                    ) else { return }

                    let url = meeting.folderURL.appendingPathComponent("summary.json")
                    try? data.write(to: url, options: .atomic)

                case .failure(let error):
                    print("[Dialogue] Summary autosave failed: \(error.localizedDescription)")
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Navigation finished — editor JS will fire "ready" message
        }
    }
}
