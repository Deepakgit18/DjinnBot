import DialogueCore
import SwiftUI
import WebKit

/// A SwiftUI wrapper around WKWebView that hosts the BlockNote editor.
/// Communicates bidirectionally with the JS layer via the bridge protocol.
struct BlockNoteEditorView: NSViewRepresentable {
    @ObservedObject var document: BlockNoteDocument
    
    /// Whether the initial document has been loaded into the editor.
    @State private var documentLoaded = false

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = WKProcessPool()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // Register the JS → Swift message handler
        let controller = config.userContentController
        controller.add(context.coordinator, name: "editorBridge")

        // 1. Inject the theme before React renders so BlockNote starts in the
        //    correct theme on the very first frame — no light→dark flash.
        // 2. Set html/body background to match the native window background.
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

        // Start hidden — the coordinator will fade in once the editor is
        // ready and themed, preventing any light-mode flash in dark mode.
        webView.alphaValue = 0

        context.coordinator.document = document
        context.coordinator.webView = webView

        // Load the single-file HTML from the bundle
        loadEditor(webView)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let previousDocument = context.coordinator.document
        context.coordinator.document = document

        // When the document instance changes (user opened a different file),
        // push the new content into the already-running WebView editor.
        if previousDocument !== document {
            context.coordinator.loadDocumentIntoEditor()
        }
    }

    // MARK: - Loading

    func loadEditor(_ webView: WKWebView) {
        if let html = loadBundledHTML() {
            webView.loadHTMLString(html, baseURL: nil)
            return
        }
        if let url = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        print("[Dialogue] Could not find BlockNote index.html in app bundle")
    }

    private func loadBundledHTML() -> String? {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        /// Shared reference so other views can call find methods.
        static weak var current: Coordinator?

        weak var document: BlockNoteDocument?
        weak var webView: WKWebView?
        
        private var reloadAttempts = 0
        private let maxReloadAttempts = 3
        private var autosaveTimer: Timer?
        private var pendingAutosave = false
        private var isEditorReady = false

        // MARK: - In-Document Find
        //
        // Uses the CSS Custom Highlight API (supported in WebKit/Safari 17.2+).
        // This creates visual highlights via Range objects WITHOUT modifying the
        // DOM, which is critical because ProseMirror (BlockNote's engine) owns
        // the DOM and reverts any direct modifications on re-render.

        /// Inject the CSS rule for `::highlight()` once when the editor is ready.
        func injectFindHighlightCSS() {
            guard let webView else { return }
            let css = """
            (function() {
                if (document.getElementById('dialogue-find-css')) return;
                var style = document.createElement('style');
                style.id = 'dialogue-find-css';
                style.textContent = `
                    ::highlight(dialogue-find) {
                        background-color: rgba(255, 200, 0, 0.4);
                        color: inherit;
                    }
                    ::highlight(dialogue-find-current) {
                        background-color: rgba(255, 140, 0, 0.7);
                        color: inherit;
                    }
                `;
                document.head.appendChild(style);
            })()
            """
            webView.evaluateJavaScript(css)
        }

        /// Perform a find-in-page search using the CSS Custom Highlight API.
        func findInPage(_ query: String) {
            guard let webView else { return }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                clearFind()
                return
            }
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            let js = """
            (function() {
                CSS.highlights.delete('dialogue-find');
                CSS.highlights.delete('dialogue-find-current');

                var query = '\(escaped)'.toLowerCase();
                if (!query) return JSON.stringify({count: 0, idx: 0});

                var root = document.querySelector('.ProseMirror')
                        || document.querySelector('.bn-editor')
                        || document.querySelector('[contenteditable]')
                        || document.body;

                var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
                var ranges = [];
                while (walker.nextNode()) {
                    var node = walker.currentNode;
                    var text = node.textContent.toLowerCase();
                    var idx = 0;
                    while ((idx = text.indexOf(query, idx)) !== -1) {
                        var range = new Range();
                        range.setStart(node, idx);
                        range.setEnd(node, idx + query.length);
                        ranges.push(range);
                        idx += query.length;
                    }
                }

                if (ranges.length === 0) return JSON.stringify({count: 0, idx: 0});

                // Store ranges globally for prev/next navigation
                window._dialogueFindRanges = ranges;
                window._dialogueFindIdx = 0;

                // All matches highlight
                var highlight = new Highlight(...ranges);
                CSS.highlights.set('dialogue-find', highlight);

                // Current match highlight (first one)
                var currentHL = new Highlight(ranges[0]);
                CSS.highlights.set('dialogue-find-current', currentHL);

                // Scroll first match into view using Range.getBoundingClientRect
                // (no DOM mutation — safe with ProseMirror)
                var rect = ranges[0].getBoundingClientRect();
                var scrollEl = root.closest('.bn-container') || root.parentElement || window;
                if (scrollEl === window) {
                    window.scrollTo({top: rect.top + window.scrollY - window.innerHeight / 2, behavior: 'smooth'});
                } else {
                    scrollEl.scrollTo({top: rect.top + scrollEl.scrollTop - scrollEl.clientHeight / 2, behavior: 'smooth'});
                }

                return JSON.stringify({count: ranges.length, idx: 0});
            })()
            """
            webView.evaluateJavaScript(js) { [weak self] result, error in
                if let err = error {
                    print("[Dialogue] findInPage JS error: \(err.localizedDescription)")
                }
                guard let json = result as? String,
                      let data = json.data(using: .utf8),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let count = dict["count"] as? Int else { return }
                DispatchQueue.main.async {
                    let search = InDocumentSearch.shared
                    search.matchingEntryIDs = (0..<count).map { _ in UUID() }
                    search.currentMatchIndex = 0
                }
            }
        }

        /// Navigate to the next find match.
        func findNext() {
            guard let webView else { return }
            let js = """
            (function() {
                var ranges = window._dialogueFindRanges;
                if (!ranges || ranges.length === 0) return;
                var idx = ((window._dialogueFindIdx || 0) + 1) % ranges.length;
                window._dialogueFindIdx = idx;

                var currentHL = new Highlight(ranges[idx]);
                CSS.highlights.set('dialogue-find-current', currentHL);

                var rect = ranges[idx].getBoundingClientRect();
                var root = document.querySelector('.ProseMirror')
                        || document.querySelector('[contenteditable]')
                        || document.body;
                var scrollEl = root.closest('.bn-container') || root.parentElement || window;
                if (scrollEl === window) {
                    window.scrollTo({top: rect.top + window.scrollY - window.innerHeight / 2, behavior: 'smooth'});
                } else {
                    scrollEl.scrollTo({top: rect.top + scrollEl.scrollTop - scrollEl.clientHeight / 2, behavior: 'smooth'});
                }
            })()
            """
            webView.evaluateJavaScript(js)
        }

        /// Navigate to the previous find match.
        func findPrevious() {
            guard let webView else { return }
            let js = """
            (function() {
                var ranges = window._dialogueFindRanges;
                if (!ranges || ranges.length === 0) return;
                var idx = ((window._dialogueFindIdx || 0) - 1 + ranges.length) % ranges.length;
                window._dialogueFindIdx = idx;

                var currentHL = new Highlight(ranges[idx]);
                CSS.highlights.set('dialogue-find-current', currentHL);

                var rect = ranges[idx].getBoundingClientRect();
                var root = document.querySelector('.ProseMirror')
                        || document.querySelector('[contenteditable]')
                        || document.body;
                var scrollEl = root.closest('.bn-container') || root.parentElement || window;
                if (scrollEl === window) {
                    window.scrollTo({top: rect.top + window.scrollY - window.innerHeight / 2, behavior: 'smooth'});
                } else {
                    scrollEl.scrollTo({top: rect.top + scrollEl.scrollTop - scrollEl.clientHeight / 2, behavior: 'smooth'});
                }
            })()
            """
            webView.evaluateJavaScript(js)
        }

        /// Clear all find highlights and force WebKit to repaint.
        func clearFind() {
            guard let webView else { return }
            let js = """
            (function() {
                CSS.highlights.delete('dialogue-find');
                CSS.highlights.delete('dialogue-find-current');
                delete window._dialogueFindRanges;
                delete window._dialogueFindIdx;
                // Force WebKit to repaint the previously-highlighted regions.
                // CSS Custom Highlight API removals don't always trigger
                // an immediate compositor update.
                var root = document.querySelector('.ProseMirror')
                        || document.querySelector('[contenteditable]')
                        || document.body;
                root.style.display = 'none';
                void root.offsetHeight;
                root.style.display = '';
            })()
            """
            webView.evaluateJavaScript(js) { _, _ in
                // Belt-and-suspenders: tell the NSView layer to redraw
                webView.setNeedsDisplay(webView.bounds)
            }
        }

        // MARK: - Voice Dictation (insert at cursor)

        /// Insert text at the current cursor position in the editor.
        /// Used by voice command dictation mode to stream words in.
        func insertTextAtCursor(_ text: String) {
            guard let webView else { return }
            let cmd = BridgeCommandToJS.insertTextAtCursor(text: text)
            webView.evaluateJavaScript(cmd.javaScript) { _, error in
                if let error {
                    print("[Dialogue] insertTextAtCursor error: \(error.localizedDescription)")
                }
            }
        }

        /// Checks whether the BlockNote editor currently has focus.
        /// Calls the JS bridge function and returns the result via completion.
        func checkEditorHasFocus(completion: @escaping (Bool) -> Void) {
            guard let webView else {
                completion(false)
                return
            }
            webView.evaluateJavaScript("window.editorHasFocus ? window.editorHasFocus() : false") { result, _ in
                completion((result as? Bool) ?? false)
            }
        }

        /// Gets the currently selected text in the editor (empty string if cursor only).
        func getSelectedText(completion: @escaping (String) -> Void) {
            guard let webView else {
                completion("")
                return
            }
            webView.evaluateJavaScript("window.getSelectedText ? window.getSelectedText() : ''") { result, _ in
                completion((result as? String) ?? "")
            }
        }

        /// Push the current document's content into the WebView editor.
        /// Called when the user switches to a different file.
        func loadDocumentIntoEditor() {
            guard isEditorReady, let webView = webView else { return }
            guard let blocksJSON = document?.file.blocksJSONString() else { return }
            let loadCmd = BridgeCommandToJS.loadDocument(blocksJSON: blocksJSON)
            webView.evaluateJavaScript(loadCmd.javaScript)
        }

        // MARK: - JS → Swift messages

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let msg = BridgeMessageFromJS.parse(message.body) else { return }

            switch msg {
            case .ready:
                print("[Dialogue] BlockNote editor ready")
                onEditorReady()

            case .contentChange(let blocksJSON, let title):
                document?.updateBlocks(from: blocksJSON)
                if let title = title {
                    document?.updateTitle(title)
                }
                scheduleAutosave()

            case .aiRequest(let requestId, let messages, let options):
                handleAIRequest(requestId: requestId, messages: messages, options: options)

            case .titleChange(let title):
                document?.updateTitle(title)
            }
        }

        // MARK: - Editor ready → inject document + API key

        private func onEditorReady() {
            isEditorReady = true
            guard let webView = webView else { return }

            // Set shared reference for in-document find
            Coordinator.current = self

            // Inject CSS rules for the Custom Highlight API (find-in-page)
            injectFindHighlightCSS()

            // Expose the WebView to NoteExporter for export/copy operations
            NoteExporter.shared.webView = webView

            // Inject API key if available
            if let key = try? KeychainManager.shared.getAPIKey() {
                let cmd = BridgeCommandToJS.injectAPIKey(key: key)
                webView.evaluateJavaScript(cmd.javaScript)
            }

            // Sync theme with system appearance
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let themeCmd = BridgeCommandToJS.setTheme(dark: isDark)
            webView.evaluateJavaScript(themeCmd.javaScript)

            // Load the document content
            if let blocksJSON = document?.file.blocksJSONString() {
                let loadCmd = BridgeCommandToJS.loadDocument(blocksJSON: blocksJSON)
                webView.evaluateJavaScript(loadCmd.javaScript)
            }

            // Reveal the editor now that it's themed and loaded.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                webView.animator().alphaValue = 1
            }
        }

        // MARK: - Autosave

        private func scheduleAutosave() {
            pendingAutosave = true
            autosaveTimer?.invalidate()
            autosaveTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
                self?.performAutosave()
            }
        }

        private func performAutosave() {
            guard pendingAutosave else { return }
            pendingAutosave = false
            // Write the current document to disk
            AppState.shared.saveCurrentDocument()
        }

        // MARK: - AI proxy (bridge transport fallback)

        private func handleAIRequest(requestId: String, messages: String, options: String) {
            guard let key = try? KeychainManager.shared.getAPIKey(), !key.isEmpty else {
                sendAIError(requestId: requestId, error: "No API key configured. Set one in Settings.")
                return
            }

            // Parse the options to get the endpoint URL
            guard let optionsData = options.data(using: .utf8),
                  let optionsDict = try? JSONSerialization.jsonObject(with: optionsData) as? [String: Any],
                  let endpoint = optionsDict["endpoint"] as? String,
                  let url = URL(string: endpoint) else {
                sendAIError(requestId: requestId, error: "Invalid AI request configuration")
                return
            }

            // Build the request
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = messages.data(using: .utf8)

            // Stream the response
            let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                DispatchQueue.main.async {
                    if let error = error {
                        self?.sendAIError(requestId: requestId, error: error.localizedDescription)
                        return
                    }
                    guard let data = data, let body = String(data: data, encoding: .utf8) else {
                        self?.sendAIError(requestId: requestId, error: "Empty response from AI backend")
                        return
                    }
                    self?.sendAIChunk(requestId: requestId, chunk: body, done: true)
                }
            }
            task.resume()
        }

        private func sendAIChunk(requestId: String, chunk: String, done: Bool) {
            let cmd = BridgeCommandToJS.dispatchAIChunk(requestId: requestId, chunk: chunk, done: done)
            webView?.evaluateJavaScript(cmd.javaScript)
        }

        private func sendAIError(requestId: String, error: String) {
            let cmd = BridgeCommandToJS.aiRequestError(requestId: requestId, error: error)
            webView?.evaluateJavaScript(cmd.javaScript)
        }

        // MARK: - Navigation delegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            print("[Dialogue] BlockNote editor loaded")
            reloadAttempts = 0
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            print("[Dialogue] Navigation failed: \(error.localizedDescription)")
            attemptReload(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            print("[Dialogue] Provisional navigation failed: \(error.localizedDescription)")
            attemptReload(webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            print("[Dialogue] WebProcess terminated - attempting recovery")
            attemptReload(webView)
        }

        private func attemptReload(_ webView: WKWebView) {
            guard reloadAttempts < maxReloadAttempts else {
                print("[Dialogue] Max reload attempts reached")
                return
            }
            reloadAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let html = self?.loadBundledHTML(webView) else { return }
                webView.loadHTMLString(html, baseURL: nil)
            }
        }

        private func loadBundledHTML(_ webView: WKWebView) -> String? {
            guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
    }
}
