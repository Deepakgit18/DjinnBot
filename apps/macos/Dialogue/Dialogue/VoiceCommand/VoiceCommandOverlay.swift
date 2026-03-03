import AppKit
import SwiftUI

// MARK: - Overlay Window

/// A borderless, floating panel that displays the waveform pill + live transcript
/// when the voice command hotkey is held. Anchored near the bottom-center
/// of the main screen (like a dictation HUD).
///
/// The window auto-resizes its height to accommodate the transcript text.
@available(macOS 26.0, *)
final class VoiceCommandOverlayWindow: NSPanel {
    private let hostingView: NSHostingView<VoiceCommandOverlayContent>

    init(manager: VoiceCommandManager) {
        let content = VoiceCommandOverlayContent(manager: manager)
        hostingView = NSHostingView(rootView: content)

        // Start with a reasonable size — will grow with transcript
        let size = NSSize(width: 340, height: 100)

        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true

        contentView = hostingView

        // Let the hosting view drive the window size
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        if let cv = contentView {
            NSLayoutConstraint.activate([
                hostingView.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
                hostingView.topAnchor.constraint(equalTo: cv.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: cv.bottomAnchor),
            ])
        }
    }

    /// Positions the panel near the bottom-center of the main screen and fades in.
    func show() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let origin = NSPoint(
            x: screenFrame.midX - frame.width / 2,
            y: screenFrame.minY + 60
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

    /// Re-center horizontally when content height changes.
    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool) {
        var adjusted = frameRect
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            adjusted.origin.x = screenFrame.midX - adjusted.width / 2
            adjusted.origin.y = screenFrame.minY + 60
        }
        super.setFrame(adjusted, display: displayFlag)
    }
}

// MARK: - Overlay Content

/// The SwiftUI content rendered inside the overlay window.
/// Shows the waveform pill on top, live transcript text below.
@available(macOS 26.0, *)
struct VoiceCommandOverlayContent: View {
    @ObservedObject var manager: VoiceCommandManager

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 10) {
            // Waveform pill
            WaveformPillView(audioLevel: manager.audioLevel, isRecording: manager.isActive)

            // Live transcript
            if !manager.transcript.isEmpty {
                Text(manager.transcript)
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: 300)
                    .background {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(.ultraThinMaterial)
                    }
            }
        }
        .padding(20)
        .animation(.easeInOut(duration: 0.15), value: manager.transcript.isEmpty)
    }
}

#Preview {
    if #available(macOS 26.0, *) {
        VoiceCommandOverlayContent(manager: VoiceCommandManager.shared)
            .frame(width: 340, height: 200)
            .background(.black.opacity(0.5))
    }
}
