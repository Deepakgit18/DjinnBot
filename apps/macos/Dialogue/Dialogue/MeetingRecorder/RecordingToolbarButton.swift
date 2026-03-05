import DialogueCore
import SwiftUI

/// A toolbar button for the title bar: red circle when idle, red square when recording.
/// Shows a spinner when preparing to record.
/// Tapping toggles recording on/off via the shared MeetingRecorderController.
///
/// No custom glass effect — the toolbar's native liquid glass wraps this
/// automatically. When recording, a subtle red glow pulses behind the stop
/// square, clipped to the button's frame so it stays within the toolbar glass.
@available(macOS 26.0, *)
struct RecordingToolbarButton: View {
    @ObservedObject var recorder: MeetingRecorderController
    @ObservedObject private var preloader = ModelPreloader.shared

    /// Drives the pulsing glow animation when recording.
    @State private var isPulsing = false

    var body: some View {
        Button {
            Task {
                if recorder.isRecording {
                    await recorder.stop()
                } else {
                    await recorder.start()
                }
            }
        } label: {
            ZStack {
                if recorder.isStarting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14, height: 14)
                } else if recorder.isRecording {
                    // Pulsing red glow, clipped to the frame
                    Circle()
                        .fill(Color.red.opacity(isPulsing ? 0.25 : 0.1))
                        .frame(width: 20, height: 20)

                    // Stop square
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.red)
                        .frame(width: 12, height: 12)
                } else {
                    // Record circle
                    Circle()
                        .fill(Color.red)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 20, height: 20)
            .clipShape(Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onChange(of: recorder.isRecording) { _, isRecording in
            if isRecording {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    isPulsing = false
                }
            }
        }
        .disabled(recorder.isStarting || !preloader.state.isReady)
        .opacity(!preloader.state.isReady ? 0.4 : 1.0)
        .help(
            recorder.isStarting ? "Preparing..." :
            recorder.isRecording ? "Stop Recording" : "Start Recording"
        )
    }
}
