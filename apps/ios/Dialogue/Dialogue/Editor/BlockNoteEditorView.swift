import DialogueCore
import SwiftUI
import WebKit

/// A SwiftUI wrapper around WKWebView that hosts the BlockNote editor on iOS.
struct BlockNoteEditorView: UIViewRepresentable {
    @ObservedObject var document: NoteDocument

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.processPool = WKProcessPool()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // Register the JS -> Swift message handler
        let controller = config.userContentController
        controller.add(context.coordinator, name: "editorBridge")

        // Inject theme before React renders
        let isDark = UITraitCollection.current.userInterfaceStyle == .dark
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

        // Inject viewport meta for proper mobile scaling
        let viewport = WKUserScript(
            source: """
                var meta = document.createElement('meta');
                meta.name = 'viewport';
                meta.content = 'width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no';
                (document.head || document.documentElement).appendChild(meta);
                """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        controller.addUserScript(viewport)

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.scrollView.keyboardDismissMode = .interactive
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.alpha = 0 // Hidden until ready

        context.coordinator.document = document
        context.coordinator.webView = webView

        loadEditor(webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let previousDocument = context.coordinator.document
        context.coordinator.document = document

        if previousDocument !== document {
            context.coordinator.loadDocumentIntoEditor()
        }
    }

    // MARK: - Loading

    func loadEditor(_ webView: WKWebView) {
        guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else {
            print("[Dialogue] Could not find BlockNote index.html in app bundle")
            return
        }
        // Use loadFileURL so relative resource references (CSS, JS, images)
        // resolve correctly against the bundle directory.
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Coordinator

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var document: NoteDocument?
        weak var webView: WKWebView?

        private var reloadAttempts = 0
        private let maxReloadAttempts = 3
        private var autosaveTimer: Timer?
        private var pendingAutosave = false
        private var isEditorReady = false

        /// Push the current document's content into the WebView editor.
        func loadDocumentIntoEditor() {
            guard isEditorReady, let webView else { return }
            guard let blocksJSON = document?.file.blocksJSONString() else { return }
            let loadCmd = BridgeCommandToJS.loadDocument(blocksJSON: blocksJSON)
            webView.evaluateJavaScript(loadCmd.javaScript)
        }

        // MARK: - JS -> Swift messages

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let msg = BridgeMessageFromJS.parse(message.body) else { return }

            switch msg {
            case .ready:
                print("[Dialogue iOS] BlockNote editor ready")
                onEditorReady()

            case .contentChange(let blocksJSON, let title):
                Task { @MainActor in
                    document?.updateBlocks(from: blocksJSON)
                    if let title { document?.updateTitle(title) }
                    scheduleAutosave()
                }

            case .aiRequest(let requestId, let messages, let options):
                handleAIRequest(requestId: requestId, messages: messages, options: options)

            case .titleChange(let title):
                Task { @MainActor in
                    document?.updateTitle(title)
                }
            }
        }

        // MARK: - Editor ready

        private func onEditorReady() {
            isEditorReady = true
            guard let webView else { return }

            // Inject API key
            if let key = try? KeychainManager.shared.getAPIKey() {
                let cmd = BridgeCommandToJS.injectAPIKey(key: key)
                webView.evaluateJavaScript(cmd.javaScript)
            }

            // Sync theme
            let isDark = UITraitCollection.current.userInterfaceStyle == .dark
            let themeCmd = BridgeCommandToJS.setTheme(dark: isDark)
            webView.evaluateJavaScript(themeCmd.javaScript)

            // Load document content
            Task { @MainActor in
                if let blocksJSON = document?.file.blocksJSONString() {
                    let loadCmd = BridgeCommandToJS.loadDocument(blocksJSON: blocksJSON)
                    webView.evaluateJavaScript(loadCmd.javaScript)
                }
            }

            // Fade in
            UIView.animate(withDuration: 0.15) {
                webView.alpha = 1
            }
        }

        // MARK: - Autosave

        private func scheduleAutosave() {
            pendingAutosave = true
            autosaveTimer?.invalidate()
            autosaveTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [weak self] _ in
                self?.performAutosave()
            }
        }

        private func performAutosave() {
            guard pendingAutosave else { return }
            pendingAutosave = false
            Task { @MainActor in
                document?.save()
            }
        }

        // MARK: - AI proxy

        private func handleAIRequest(requestId: String, messages: String, options: String) {
            guard let key = try? KeychainManager.shared.getAPIKey(), !key.isEmpty else {
                sendAIError(requestId: requestId, error: "No API key configured. Set one in Settings.")
                return
            }

            guard let optionsData = options.data(using: .utf8),
                  let optionsDict = try? JSONSerialization.jsonObject(with: optionsData) as? [String: Any],
                  let endpoint = optionsDict["endpoint"] as? String,
                  let url = URL(string: endpoint) else {
                sendAIError(requestId: requestId, error: "Invalid AI request configuration")
                return
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = messages.data(using: .utf8)

            URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
                DispatchQueue.main.async {
                    if let error {
                        self?.sendAIError(requestId: requestId, error: error.localizedDescription)
                        return
                    }
                    guard let data, let body = String(data: data, encoding: .utf8) else {
                        self?.sendAIError(requestId: requestId, error: "Empty response")
                        return
                    }
                    self?.sendAIChunk(requestId: requestId, chunk: body, done: true)
                }
            }.resume()
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
            print("[Dialogue iOS] WebView didFinish navigation")
            reloadAttempts = 0
            // Safety fallback: if the editor doesn't send "ready" within 3s,
            // make it visible anyway so the user doesn't see a black screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self, !self.isEditorReady else { return }
                print("[Dialogue iOS] Editor ready timeout — forcing visible")
                UIView.animate(withDuration: 0.15) {
                    webView.alpha = 1
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            attemptReload(webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            attemptReload(webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            attemptReload(webView)
        }

        private func attemptReload(_ webView: WKWebView) {
            guard reloadAttempts < maxReloadAttempts else { return }
            reloadAttempts += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                guard let url = Bundle.main.url(forResource: "index", withExtension: "html") else { return }
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            }
        }
    }
}
