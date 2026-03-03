import AppKit
import KeyboardShortcuts

// MARK: - Shortcut Registration

extension KeyboardShortcuts.Name {
    /// Global voice command hotkey. Default: Cmd+Shift+Space.
    static let voiceCommand = Self(
        "voiceCommand",
        default: .init(.space, modifiers: [.command, .shift])
    )
}

// MARK: - Voice Command Manager

/// Manages the global voice command hotkey lifecycle: listens for key-down/key-up,
/// shows/hides the loading overlay, and (later) triggers recording.
@MainActor
final class VoiceCommandManager: ObservableObject {
    static let shared = VoiceCommandManager()

    /// Whether the voice command is currently active (hotkey held down).
    @Published private(set) var isActive = false

    /// The overlay window that displays the loading animation.
    private var overlayWindow: VoiceCommandOverlayWindow?

    private init() {
        registerHotkey()
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
        showOverlay()
    }

    private func deactivate() {
        guard isActive else { return }
        isActive = false
        hideOverlay()
    }

    // MARK: - Overlay Window

    private func showOverlay() {
        if overlayWindow == nil {
            overlayWindow = VoiceCommandOverlayWindow()
        }
        overlayWindow?.show()
    }

    private func hideOverlay() {
        overlayWindow?.dismiss()
    }
}
