import Foundation

// MARK: - JS → Swift Messages

/// Messages sent from the BlockNote web editor to Swift via `window.webkit.messageHandlers.editorBridge.postMessage`.
enum BridgeMessageFromJS {
    case ready
    case contentChange(blocksJSON: String, title: String?)
    case aiRequest(requestId: String, messages: String, options: String)
    case titleChange(title: String)

    /// Parse a raw dictionary from WKScriptMessage into a typed message.
    static func parse(_ body: Any) -> BridgeMessageFromJS? {
        guard let dict = body as? [String: Any],
              let type = dict["type"] as? String else {
            return nil
        }

        switch type {
        case "ready":
            return .ready

        case "contentChange":
            guard let blocksJSON = dict["blocksJSON"] as? String else { return nil }
            let title = dict["title"] as? String
            return .contentChange(blocksJSON: blocksJSON, title: title)

        case "aiRequest":
            guard let requestId = dict["requestId"] as? String,
                  let messages = dict["messages"] as? String,
                  let options = dict["options"] as? String else { return nil }
            return .aiRequest(requestId: requestId, messages: messages, options: options)

        case "titleChange":
            guard let title = dict["title"] as? String else { return nil }
            return .titleChange(title: title)

        default:
            print("[Dialogue] Unknown bridge message type: \(type)")
            return nil
        }
    }
}

// MARK: - Swift → JS Commands

/// Commands sent from Swift to the BlockNote web editor via `evaluateJavaScript`.
enum BridgeCommandToJS {
    case loadDocument(blocksJSON: String)
    case injectAPIKey(key: String)
    case setTheme(dark: Bool)
    case dispatchAIChunk(requestId: String, chunk: String, done: Bool)
    case aiRequestError(requestId: String, error: String)
    case insertTextAtCursor(text: String)
    case loadMarkdown(markdown: String)

    /// Generate the JavaScript string to evaluate.
    var javaScript: String {
        switch self {
        case .loadDocument(let blocksJSON):
            return "window.loadDocument && window.loadDocument(\(blocksJSON));"

        case .injectAPIKey(let key):
            // Escape single quotes in the key
            let escaped = key.replacingOccurrences(of: "'", with: "\\'")
                             .replacingOccurrences(of: "\\", with: "\\\\")
            return "window.AI_API_KEY = '\(escaped)';"

        case .setTheme(let dark):
            return "window.setTheme && window.setTheme('\(dark ? "dark" : "light")');"

        case .dispatchAIChunk(let requestId, let chunk, let done):
            let escapedChunk = chunk
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "window.dispatchAIChunk && window.dispatchAIChunk({requestId: '\(requestId)', chunk: '\(escapedChunk)', done: \(done)});"

        case .aiRequestError(let requestId, let error):
            let escapedError = error
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "window.dispatchAIError && window.dispatchAIError({requestId: '\(requestId)', error: '\(escapedError)'});"

        case .insertTextAtCursor(let text):
            let escaped = text
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "window.insertTextAtCursor && window.insertTextAtCursor('\(escaped)');"

        case .loadMarkdown(let markdown):
            // Escape for JS single-quoted string. The JS function is async
            // (calls tryParseMarkdownToBlocks) so we invoke it without await —
            // the WKWebView will handle the Promise internally.
            let escaped = markdown
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            return "window.loadMarkdown && window.loadMarkdown('\(escaped)');"
        }
    }
}
