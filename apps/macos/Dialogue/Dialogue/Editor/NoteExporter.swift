import DialogueCore
import AppKit
import UniformTypeIdentifiers
import WebKit

/// Exports .blocknote documents to Markdown or HTML by calling the BlockNote
/// editor's JS conversion APIs via the embedded WKWebView.
///
/// The `BlockNoteEditorView.Coordinator` sets `webView` when the editor is ready.
/// Context menu actions call the export/copy methods with a file URL.
@MainActor
final class NoteExporter {
    static let shared = NoteExporter()

    /// The active BlockNote WKWebView. Set by the editor coordinator.
    weak var webView: WKWebView?

    private init() {}

    // MARK: - Export Formats

    enum Format: String {
        case markdown
        case html
        case htmlFull
    }

    // MARK: - Public API

    /// Export a .blocknote file to a chosen format and let the user pick a save location.
    func exportToFile(_ fileURL: URL, format: Format) {
        Task {
            do {
                let content = try await convert(fileURL: fileURL, format: format)
                presentSavePanel(content: content, format: format, sourceFileName: fileURL.deletingPathExtension().lastPathComponent)
            } catch {
                showError("Export failed: \(error.localizedDescription)")
            }
        }
    }

    /// Convert a .blocknote file and copy the result to the clipboard.
    func copyToClipboard(_ fileURL: URL, format: Format) {
        Task {
            do {
                let content = try await convert(fileURL: fileURL, format: format)
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(content, forType: .string)
            } catch {
                showError("Copy failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Conversion

    private func convert(fileURL: URL, format: Format) async throws -> String {
        guard let webView else {
            throw ExportError.editorNotReady
        }

        // Read the .blocknote file and extract the blocks JSON array
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? BlockNoteFile.fromJSON(data),
              let blocksJSON = file.blocksJSONString() else {
            throw ExportError.fileReadFailed
        }

        let jsFunction: String
        switch format {
        case .markdown:  jsFunction = "exportMarkdown"
        case .html:      jsFunction = "exportHTML"
        case .htmlFull:  jsFunction = "exportFullHTML"
        }

        // Use callAsyncJavaScript which properly awaits JS Promises.
        // The blocksJSON is passed as a named argument to avoid escaping issues.
        let js = """
        if (!window.\(jsFunction)) return null;
        return await window.\(jsFunction)(blocksJSON);
        """

        let result = try await webView.callAsyncJavaScript(
            js,
            arguments: ["blocksJSON": blocksJSON],
            contentWorld: .page
        )

        guard let content = result as? String else {
            throw ExportError.conversionReturnedNil
        }
        return content
    }

    // MARK: - Save Panel

    private func presentSavePanel(content: String, format: Format, sourceFileName: String) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = sourceFileName

        switch format {
        case .markdown:
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.nameFieldStringValue += ".md"
        case .html, .htmlFull:
            panel.allowedContentTypes = [.html]
            panel.nameFieldStringValue += ".html"
        }

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                self.showError("Failed to save file: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Error Handling

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Export Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    enum ExportError: Error, LocalizedError {
        case editorNotReady
        case fileReadFailed
        case conversionReturnedNil

        var errorDescription: String? {
            switch self {
            case .editorNotReady:
                return "The editor is not loaded. Open any note first, then try again."
            case .fileReadFailed:
                return "Could not read the .blocknote file."
            case .conversionReturnedNil:
                return "The editor returned no content for the conversion."
            }
        }
    }
}
