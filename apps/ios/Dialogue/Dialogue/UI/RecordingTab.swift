import DialogueCore
import ReplayKit
import SwiftUI

/// Recording tab with ReplayKit broadcast picker and status display.
struct RecordingTab: View {
    @StateObject private var coordinator = RecordingCoordinator.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Status indicator
                statusIndicator

                // Duration
                if coordinator.isRecording {
                    Text(coordinator.formattedDuration)
                        .font(.system(size: 48, weight: .light, design: .monospaced))
                        .foregroundStyle(.primary)
                }

                Text(coordinator.statusMessage)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                if coordinator.isRecording {
                    // Stop button when recording
                    Button(role: .destructive) {
                        coordinator.stopBroadcast()
                    } label: {
                        Label("Stop Recording", systemImage: "stop.circle.fill")
                            .font(.title3.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .padding(.horizontal, 40)
                } else {
                    // ReplayKit broadcast picker (start)
                    BroadcastPickerRepresentable()
                        .frame(width: 80, height: 80)

                    Text("Long press to start recording")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Record")
            .onAppear {
                coordinator.startMonitoring()
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        Circle()
            .fill(coordinator.isRecording ? Color.red : Color.gray.opacity(0.3))
            .frame(width: 16, height: 16)
            .overlay {
                if coordinator.isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.4), lineWidth: 3)
                        .scaleEffect(1.8)
                        .opacity(coordinator.isRecording ? 1 : 0)
                        .animation(
                            .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                            value: coordinator.isRecording
                        )
                }
            }
    }
}

// MARK: - RPSystemBroadcastPickerView wrapper

struct BroadcastPickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        picker.preferredExtension = "bot.djinn.ios.dialogue.BroadcastUpload"
        picker.showsMicrophoneButton = true
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
}
