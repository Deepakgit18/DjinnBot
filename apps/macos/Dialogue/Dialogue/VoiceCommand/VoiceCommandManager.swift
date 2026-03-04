import AppKit
import KeyboardShortcuts
import OSLog

// MARK: - Shortcut Registration

extension KeyboardShortcuts.Name {
    /// Global voice command hotkey. Default: Cmd+Shift+Space.
    static let voiceCommand = Self(
        "voiceCommand",
        default: .init(.space, modifiers: [.command, .shift])
    )
}

// MARK: - Voice Command Mode

/// Determines the behavior of the voice command hotkey based on context at activation time.
enum VoiceCommandMode {
    /// Cursor is active in a BlockNote editor — stream transcribed text word-by-word at cursor.
    case dictation
    /// Text is selected in any app — copy it, transcribe voice, send both to AI chat.
    case aiContext(selectedText: String)
    /// No selection and no active cursor — create a voice note (original behavior).
    case voiceNote
}

// MARK: - Voice Command Manager

/// Manages the global voice command hotkey lifecycle:
///
/// 1. Key-down: detects context (editor cursor / text selection / neither),
///    starts mic capture + live transcription, shows overlay
/// 2. Key-up: depending on mode, either finishes dictation, sends AI prompt,
///    or creates a voice note
@available(macOS 26.0, *)
@MainActor
final class VoiceCommandManager: ObservableObject {
    static let shared = VoiceCommandManager()

    /// Whether the voice command is currently active (hotkey held down).
    @Published private(set) var isActive = false

    /// Live transcript text from the current voice command session.
    @Published private(set) var transcript = ""

    /// Live mic audio level (0–1) for waveform animation.
    @Published private(set) var audioLevel: Float = 0

    /// The current mode (set on activation, nil when inactive).
    @Published private(set) var mode: VoiceCommandMode?

    /// The overlay window that displays the waveform + live transcript.
    private var overlayWindow: VoiceCommandOverlayWindow?

    /// The transcriber actor that handles mic → ASR.
    private let transcriber = VoiceCommandTranscriber()

    /// Timer that polls transcript/level from the transcriber actor.
    private var pollTimer: Timer?

    /// Tracks how much finalized text has been inserted (for dictation mode).
    private var lastInsertedLength = 0

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "VoiceCommand")

    private init() {
        registerHotkey()
        // Pre-prepare the transcriber in the background
        Task {
            do {
                try await transcriber.prepare()
                logger.info("VoiceCommandTranscriber pre-prepared")
            } catch {
                logger.warning("VoiceCommandTranscriber pre-prepare failed (will retry on use): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Hotkey Registration

    private func registerHotkey() {
        KeyboardShortcuts.onKeyDown(for: .voiceCommand) { [weak self] in
            Task { @MainActor in
                self?.activate()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .voiceCommand) { [weak self] in
            Task { @MainActor in
                self?.deactivate()
            }
        }
    }

    // MARK: - Mode Detection

    /// Determines which mode to use based on the current context.
    private func detectMode() async -> VoiceCommandMode {
        // 1. Check if we're in the Dialogue app with the editor active and
        //    the WKWebView (or a subview) is the first responder.
        //
        //    We check the native AppKit responder chain instead of TipTap's
        //    JS-level `isFocused` because global hotkeys are intercepted at
        //    the system level before they reach the web view, which causes
        //    TipTap to report unfocused even though the cursor is in the note.
        if NSApp.isActive,
           case .editor = AppState.shared.activeScreen,
           let coordinator = BlockNoteEditorView.Coordinator.current,
           let webView = coordinator.webView,
           Self.webViewHasNativeFocus(webView) {

            // Editor is focused — but does the user have text selected?
            let selectedText = await withCheckedContinuation { cont in
                coordinator.getSelectedText { text in
                    cont.resume(returning: text)
                }
            }
            if !selectedText.isEmpty {
                // Text selected in editor → AI context mode
                return .aiContext(selectedText: selectedText)
            }
            // Cursor only, no selection → dictation mode
            return .dictation
        }

        // 2. Try to capture selected text from whatever app is active.
        //    Only attempt Cmd+C if another app is frontmost (avoids spurious
        //    copy sounds inside Dialogue when nothing is selected).
        if !NSApp.isActive {
            if let selectedText = await captureSelectedText(), !selectedText.isEmpty {
                return .aiContext(selectedText: selectedText)
            }
        }

        // 3. Default: create a voice note.
        return .voiceNote
    }

    /// Checks whether the WKWebView (or one of its internal subviews) is the
    /// window's first responder. This is more reliable than the JS-level
    /// `tiptap.isFocused` check when global hotkeys are involved.
    private static func webViewHasNativeFocus(_ webView: NSView) -> Bool {
        guard let firstResponder = webView.window?.firstResponder as? NSView else {
            return false
        }
        // The first responder might be the WKWebView itself, or (more commonly)
        // an internal WKContentView / WKWebInspectorView subview.
        return firstResponder === webView || firstResponder.isDescendant(of: webView)
    }

    /// Captures the currently selected text in any application by simulating Cmd+C.
    /// Returns nil if no text was captured, the pasteboard didn't change, or
    /// Accessibility permission hasn't been granted.
    private func captureSelectedText() async -> String? {
        // CGEvent posting requires Accessibility permission.
        PermissionManager.shared.checkAccessibility()
        guard PermissionManager.shared.accessibilityStatus == .granted else {
            return nil
        }

        let pb = NSPasteboard.general
        let previousChangeCount = pb.changeCount

        // Simulate Cmd+C via CGEvent
        let src = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true),  // 'c'
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false) else {
            return nil
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        // Brief wait for the pasteboard to update.
        // CGEvent posts are asynchronous; the target app needs time to handle the copy.
        try? await Task.sleep(nanoseconds: 80_000_000) // 80ms

        // Check if the pasteboard actually changed
        guard pb.changeCount != previousChangeCount else { return nil }

        return pb.string(forType: .string)
    }

    // MARK: - Activation

    private func activate() {
        guard !isActive else { return }

        // Check microphone permission before activating.
        // Don't prompt here — the onboarding flow handles initial permission grants.
        PermissionManager.shared.checkMicrophone()
        guard PermissionManager.shared.microphoneStatus == .granted else {
            logger.warning("Voice command skipped: microphone not authorized")
            return
        }

        isActive = true
        transcript = ""
        audioLevel = 0
        lastInsertedLength = 0

        // Detect mode and start transcription concurrently.
        // Show overlay immediately with a generic state; update once mode is determined.
        showOverlay()

        Task {
            // Detect mode first (may involve async JS call or pasteboard capture).
            let detectedMode = await detectMode()
            self.mode = detectedMode

            switch detectedMode {
            case .dictation:
                logger.info("Voice command activated — dictation mode")
            case .aiContext(let text):
                logger.info("Voice command activated — AI context mode (selected \(text.count) chars)")
            case .voiceNote:
                logger.info("Voice command activated — voice note mode")
            }

            // Start mic capture + transcription
            do {
                try await transcriber.start()
                startPolling()
            } catch {
                logger.error("Failed to start voice command transcription: \(error.localizedDescription)")
                isActive = false
                mode = nil
                hideOverlay()
            }
        }
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        stopPolling()

        let currentMode = mode
        mode = nil

        // Stop transcription and handle result based on mode
        Task {
            let finalText = await transcriber.stop()
            hideOverlay()

            let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)

            switch currentMode {
            case .dictation:
                // Insert any text that wasn't streamed in during the session.
                // For short utterances the speech recognizer doesn't finalize
                // text mid-session — it only finalizes when stop() calls
                // finalizeAndFinishThroughEndOfInput(). So `trimmed` (the
                // final transcript returned by stop()) is the authoritative
                // source. `lastInsertedLength` tracks how many characters
                // were already streamed into the editor during the session.
                if !trimmed.isEmpty && trimmed.count > lastInsertedLength {
                    let startIdx = trimmed.index(trimmed.startIndex, offsetBy: lastInsertedLength)
                    var remaining = String(trimmed[startIdx...])
                    // Add leading space if appending to previously inserted text
                    if lastInsertedLength > 0 && !remaining.hasPrefix(" ") {
                        remaining = " " + remaining
                    }
                    if !remaining.isEmpty {
                        insertTextIntoEditor(remaining)
                    }
                }
                logger.info("Voice command deactivated — dictation complete (\(trimmed.count) chars, \(self.lastInsertedLength) streamed)")

            case .aiContext(let selectedText):
                guard !trimmed.isEmpty,
                      trimmed.rangeOfCharacter(from: .alphanumerics) != nil else {
                    logger.info("Voice command deactivated — no voice command, skipping AI")
                    return
                }
                sendToAIChat(selectedText: selectedText, voiceCommand: trimmed)

            case .voiceNote:
                guard !trimmed.isEmpty,
                      trimmed.rangeOfCharacter(from: .alphanumerics) != nil else {
                    logger.info("Voice command deactivated — no substantive text, skipping note creation")
                    return
                }
                createVoiceNote(text: trimmed)

            case nil:
                // Mode detection may have failed; treat as voice note fallback.
                guard !trimmed.isEmpty else { return }
                createVoiceNote(text: trimmed)
            }
        }
    }

    // MARK: - Polling (transcript + audio level)

    /// Polls the transcriber actor for updated transcript text and audio level.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let newTranscript = await self.transcriber.transcript
                let newLevel = await self.transcriber.audioLevel
                self.transcript = newTranscript
                self.audioLevel = newLevel

                // In dictation mode, stream finalized words into the editor.
                if case .dictation = self.mode {
                    await self.streamDictationText()
                }
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Mode 1: Dictation (streaming text into editor)

    /// Called at ~30fps during dictation mode. Inserts any newly finalized text
    /// into the editor at cursor position.
    private func streamDictationText() async {
        let finalizedText = await transcriber.currentFinalizedText
        let currentLen = finalizedText.count

        guard currentLen > lastInsertedLength else { return }

        // Extract only the new portion
        let startIndex = finalizedText.index(finalizedText.startIndex, offsetBy: lastInsertedLength)
        var newText = String(finalizedText[startIndex...])

        // Add a leading space if we're appending to previous text
        if lastInsertedLength > 0 && !newText.hasPrefix(" ") {
            newText = " " + newText
        }

        insertTextIntoEditor(newText)
        lastInsertedLength = currentLen
    }

    private func insertTextIntoEditor(_ text: String) {
        guard let coordinator = BlockNoteEditorView.Coordinator.current else { return }
        coordinator.insertTextAtCursor(text)
    }

    // MARK: - Mode 2: AI Context (selected text + voice → chat)

    private func sendToAIChat(selectedText: String, voiceCommand: String) {
        logger.info("Sending to AI chat: command='\(voiceCommand.prefix(40))' context=\(selectedText.count) chars")

        // Build a prompt that includes the selected text as context and the voice command.
        let prompt = """
        I have the following text selected:

        ---
        \(selectedText)
        ---

        \(voiceCommand)
        """

        // Bring Dialogue to front and ensure the chat panel is visible.
        NSApp.activate(ignoringOtherApps: true)

        // Post the "show chat" notification (not toggle — we always want it open).
        NotificationCenter.default.post(name: .showChatPanel, object: nil)

        // Send the message via ChatSessionManager.
        // Use sendMessageWhenReady which handles session creation if needed.
        ChatSessionManager.shared.sendMessageWhenReady(prompt)
    }

    // MARK: - Mode 3: Voice Note (original behavior)

    /// Creates a voice note file named "voice-<datetime>" with the transcribed text.
    private func createVoiceNote(text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let title = "voice-\(timestamp)"

        // Build a BlockNoteFile with the transcript as a paragraph block
        let paragraphBlock = JSONValue.object([
            "id": .string(UUID().uuidString),
            "type": .string("paragraph"),
            "props": .object([
                "textColor": .string("default"),
                "backgroundColor": .string("default"),
                "textAlignment": .string("left"),
            ]),
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text),
                    "styles": .object([:]),
                ])
            ]),
            "children": .array([]),
        ])

        let file = BlockNoteFile(title: title, blocks: [paragraphBlock])
        guard let data = try? file.toJSON() else {
            logger.error("Failed to serialize voice note")
            return
        }

        let notesRoot = DocumentManager.dialogueFolder
            .appendingPathComponent("Notes", isDirectory: true)
        try? FileManager.default.createDirectory(at: notesRoot, withIntermediateDirectories: true)

        let fileURL = notesRoot
            .appendingPathComponent(title)
            .appendingPathExtension("blocknote")

        do {
            try data.write(to: fileURL, options: .atomic)
            logger.info("Voice note created: \(fileURL.lastPathComponent)")

            // Refresh sidebar and navigate to the new note
            DocumentManager.shared.refresh()
            AppState.shared.openDocument(at: fileURL)
        } catch {
            logger.error("Failed to write voice note: \(error.localizedDescription)")
        }
    }

    // MARK: - Overlay Window

    private func showOverlay() {
        if overlayWindow == nil {
            overlayWindow = VoiceCommandOverlayWindow(manager: self)
        }
        overlayWindow?.show()
    }

    private func hideOverlay() {
        overlayWindow?.dismiss()
    }
}

// MARK: - Fallback for older macOS

/// Stub for pre-macOS 26.0 that just registers the hotkey but does nothing.
/// Ensures the app compiles on older deployment targets.
@available(macOS, deprecated: 26.0, message: "Use the macOS 26.0+ VoiceCommandManager instead")
@MainActor
final class VoiceCommandManagerLegacy {
    static let shared = VoiceCommandManagerLegacy()
    private init() {}
}
