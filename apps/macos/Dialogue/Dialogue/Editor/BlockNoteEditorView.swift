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

        // Inject early CSS so the page body is transparent while loading,
        // preventing a white flash when switching views in dark mode.
        let earlyCSS = WKUserScript(
            source: """
                document.addEventListener('DOMContentLoaded', function() {
                    var s = document.createElement('style');
                    s.textContent = 'html, body { background: transparent !important; }';
                    document.head.prepend(s);
                });
                // Also set it immediately for the current document
                var s = document.createElement('style');
                s.textContent = 'html, body { background: transparent !important; }';
                (document.head || document.documentElement).prepend(s);
                """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(earlyCSS)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        
        // Transparent background to match native app chrome
        webView.setValue(false, forKey: "drawsBackground")

        // Prevent white flash in dark mode: the under-page color shows
        // behind web content while the HTML/CSS is still loading.
        webView.underPageBackgroundColor = .windowBackgroundColor

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

        /// Perform a find-in-page search. Highlights all matches in the WebView.
        func findInPage(_ query: String) {
            guard let webView else { return }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                clearFind()
                return
            }
            // Use CSS + JS custom highlight approach for robust counting.
            // Mark all matches with a <mark> tag, count them, and scroll to current.
            let escaped = trimmed
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            let js = """
            (function() {
                // Remove previous highlights by unwrapping mark elements
                document.querySelectorAll('mark[data-dialogue-find]').forEach(function(m) {
                    var parent = m.parentNode;
                    while (m.firstChild) parent.insertBefore(m.firstChild, m);
                    parent.removeChild(m);
                    parent.normalize();
                });
                var query = '\(escaped)'.toLowerCase();
                if (!query) return JSON.stringify({count: 0});
                // Find the editor content area (ProseMirror or fallback to body)
                var root = document.querySelector('.ProseMirror') ||
                           document.querySelector('.bn-editor') ||
                           document.querySelector('[contenteditable]') ||
                           document.body;
                var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
                var matches = [];
                while (walker.nextNode()) {
                    var node = walker.currentNode;
                    var text = node.textContent.toLowerCase();
                    var idx = 0;
                    while ((idx = text.indexOf(query, idx)) !== -1) {
                        matches.push({node: node, idx: idx});
                        idx += query.length;
                    }
                }
                // Process in reverse to preserve text node offsets
                for (var i = matches.length - 1; i >= 0; i--) {
                    var m = matches[i];
                    var node = m.node;
                    var idx = m.idx;
                    // Split: [before][match][after]
                    var afterNode = node.splitText(idx + query.length);
                    var matchNode = node.splitText(idx);
                    var mark = document.createElement('mark');
                    mark.setAttribute('data-dialogue-find', '');
                    mark.style.backgroundColor = 'rgba(255,200,0,0.45)';
                    mark.style.borderRadius = '2px';
                    mark.style.padding = '1px 0';
                    matchNode.parentNode.insertBefore(mark, matchNode);
                    mark.appendChild(matchNode);
                }
                var allMarks = document.querySelectorAll('mark[data-dialogue-find]');
                if (allMarks.length > 0) {
                    allMarks[0].style.backgroundColor = 'rgba(255,140,0,0.65)';
                    allMarks[0].scrollIntoView({block:'center', behavior:'smooth'});
                    document.body.setAttribute('data-find-idx', '0');
                }
                return JSON.stringify({count: allMarks.length});
            })()
            """
            webView.evaluateJavaScript(js) { result, _ in
                if let json = result as? String,
                   let data = json.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let count = dict["count"] as? Int {
                    DispatchQueue.main.async {
                        let search = InDocumentSearch.shared
                        // Use matchingEntryIDs as a count proxy (store dummy UUIDs)
                        search.matchingEntryIDs = (0..<count).map { _ in UUID() }
                        search.currentMatchIndex = 0
                    }
                }
            }
        }

        /// Navigate to the next find match in the WebView.
        func findNext() {
            guard let webView else { return }
            let js = """
            (function() {
                const marks = document.querySelectorAll('mark[data-dialogue-find]');
                if (marks.length === 0) return;
                let cur = parseInt(document.body.getAttribute('data-find-idx') || '0');
                marks[cur].style.backgroundColor = 'rgba(255,200,0,0.45)';
                cur = (cur + 1) % marks.length;
                marks[cur].style.backgroundColor = 'rgba(255,140,0,0.65)';
                marks[cur].scrollIntoView({block:'center'});
                document.body.setAttribute('data-find-idx', cur.toString());
            })()
            """
            webView.evaluateJavaScript(js)
        }

        /// Navigate to the previous find match in the WebView.
        func findPrevious() {
            guard let webView else { return }
            let js = """
            (function() {
                const marks = document.querySelectorAll('mark[data-dialogue-find]');
                if (marks.length === 0) return;
                let cur = parseInt(document.body.getAttribute('data-find-idx') || '0');
                marks[cur].style.backgroundColor = 'rgba(255,200,0,0.45)';
                cur = (cur - 1 + marks.length) % marks.length;
                marks[cur].style.backgroundColor = 'rgba(255,140,0,0.65)';
                marks[cur].scrollIntoView({block:'center'});
                document.body.setAttribute('data-find-idx', cur.toString());
            })()
            """
            webView.evaluateJavaScript(js)
        }

        /// Clear all find highlights.
        func clearFind() {
            guard let webView else { return }
            let js = """
            document.querySelectorAll('mark[data-dialogue-find]').forEach(function(m) {
                var parent = m.parentNode;
                while (m.firstChild) parent.insertBefore(m.firstChild, m);
                parent.removeChild(m);
                parent.normalize();
            });
            document.body.removeAttribute('data-find-idx');
            """
            webView.evaluateJavaScript(js)
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
