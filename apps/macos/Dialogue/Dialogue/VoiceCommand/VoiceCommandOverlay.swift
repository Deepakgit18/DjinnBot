import AppKit
import SwiftUI

// MARK: - Overlay Window

/// A borderless, floating panel that displays the waveform pill
/// when the voice command hotkey is held. Anchored near the bottom-center
/// of the main screen (like a dictation HUD).
final class VoiceCommandOverlayWindow: NSPanel {
    private let hostingView: NSHostingView<VoiceCommandOverlayContent>

    init() {
        let content = VoiceCommandOverlayContent()
        hostingView = NSHostingView(rootView: content)

        // Wide enough for the pill + shadow padding
        let size = NSSize(width: 240, height: 80)

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // The pill draws its own shadows
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true

        contentView = hostingView
    }

    /// Positions the panel near the bottom-center of the main screen and fades in.
    func show() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let origin = NSPoint(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.minY + 60 // ~60pt above the bottom
        )
        setFrameOrigin(origin)
        alphaValue = 0
        orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    /// Fades out and removes from screen.
    func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.orderOut(nil)
        })
    }
}

// MARK: - Overlay Content

/// The SwiftUI content rendered inside the overlay window.
/// Shows the waveform pill in its idle/recording state.
struct VoiceCommandOverlayContent: View {
    var body: some View {
        WaveformPillView(audioLevel: 0, isRecording: true)
    }
}

#Preview {
    VoiceCommandOverlayContent()
        .frame(width: 240, height: 80)
        .background(.black.opacity(0.5))
}
