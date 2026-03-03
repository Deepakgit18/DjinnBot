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

// MARK: - Voice Command Manager

/// Manages the global voice command hotkey lifecycle:
///
/// 1. Key-down: starts mic capture + live transcription, shows waveform overlay
/// 2. Key-up: stops transcription, creates a voice note with the transcript,
///    navigates to it in the editor
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

    /// The overlay window that displays the waveform + live transcript.
    private var overlayWindow: VoiceCommandOverlayWindow?

    /// The transcriber actor that handles mic → ASR.
    private let transcriber = VoiceCommandTranscriber()

    /// Timer that polls transcript/level from the transcriber actor.
    private var pollTimer: Timer?

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

    // MARK: - Activation

    private func activate() {
        guard !isActive else { return }
        isActive = true
        transcript = ""
        audioLevel = 0
        showOverlay()

        // Start mic capture + transcription
        Task {
            do {
                try await transcriber.start()
                startPolling()
                logger.info("Voice command activated — recording")
            } catch {
                logger.error("Failed to start voice command transcription: \(error.localizedDescription)")
                isActive = false
                hideOverlay()
            }
        }
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        stopPolling()

        // Stop transcription and create the note
        Task {
            let finalText = await transcriber.stop()
            hideOverlay()

            // Only create a note if we got actual content
            let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  trimmed.rangeOfCharacter(from: .alphanumerics) != nil else {
                logger.info("Voice command deactivated — no substantive text, skipping note creation")
                return
            }

            createVoiceNote(text: trimmed)
        }
    }

    // MARK: - Polling (transcript + audio level)

    /// Polls the transcriber actor for updated transcript text and audio level.
    /// Uses a timer because the transcriber is an actor and we want smooth
    /// 30fps updates without blocking the hotkey response.
    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.transcript = await self.transcriber.transcript
                self.audioLevel = await self.transcriber.audioLevel
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    // MARK: - Note Creation

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
