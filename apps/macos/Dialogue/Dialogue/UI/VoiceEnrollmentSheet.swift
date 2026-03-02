import SwiftUI

/// Sheet for enrolling a new speaker voice.
///
/// Flow:
/// 1. User enters a name.
/// 2. Presses "Start Recording" and speaks for 5–10 seconds.
/// 3. Presses "Stop" — embedding is extracted.
/// 4. Presses "Save" to persist the profile.
@available(macOS 26.0, *)
struct VoiceEnrollmentSheet: View {

    @StateObject private var manager = VoiceEnrollmentManager()
    @Environment(\.dismiss) private var dismiss

    /// Called after a successful enrollment so the parent can refresh.
    var onComplete: () -> Void = {}

    @State private var speakerName: String = ""
    @State private var extractedEmbedding: [Float]?

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 4) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                Text("Enroll Voice")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Record 5-10 seconds of clear speech to create a voice profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider()

            // Name field
            TextField("Speaker Name (e.g. your name)", text: $speakerName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            // Recording UI
            VStack(spacing: 12) {
                switch manager.state {
                case .idle, .preparingModels:
                    ProgressView("Preparing models...")
                        .controlSize(.small)

                case .ready:
                    if extractedEmbedding != nil {
                        extractedState
                    } else {
                        readyState
                    }

                case .recording(let duration):
                    recordingState(duration: duration)

                case .processing:
                    ProgressView("Extracting voice profile...")
                        .controlSize(.small)

                case .done(let name):
                    doneState(name: name)

                case .error(let message):
                    errorState(message: message)
                }
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    manager.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if extractedEmbedding != nil && !speakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Save Profile") {
                        Task {
                            if let emb = extractedEmbedding {
                                let success = await manager.saveProfile(name: speakerName, embedding: emb)
                                if success {
                                    onComplete()
                                    dismiss()
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 400)
        .task {
            await manager.prepare()
        }
        .onDisappear {
            manager.cancel()
        }
    }

    // MARK: - State Views

    private var extractedState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.green)
            Text("Voice profile extracted. Click Save Profile below.")
                .font(.callout)
                .multilineTextAlignment(.center)

            Button {
                extractedEmbedding = nil
                manager.startRecording()
            } label: {
                Label("Re-record", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var readyState: some View {
        VStack(spacing: 8) {
            levelMeter(level: 0)

            Button {
                manager.startRecording()
            } label: {
                Label("Start Recording", systemImage: "mic.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(speakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if speakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Enter a name first")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func recordingState(duration: TimeInterval) -> some View {
        VStack(spacing: 8) {
            levelMeter(level: manager.peakLevel)

            HStack(spacing: 12) {
                // Pulsing red dot
                Circle()
                    .fill(Color.red)
                    .frame(width: 10, height: 10)
                    .opacity(0.8)
                    .animation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true), value: duration)

                Text(formatDuration(duration))
                    .font(.system(.title3, design: .monospaced))
                    .fontWeight(.medium)
            }

            // Duration guidance
            if duration < manager.minimumDuration {
                Text("Keep speaking... (\(Int(manager.minimumDuration - duration))s more needed)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if duration < manager.recommendedDuration {
                Text("Good! A bit more for best accuracy...")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else {
                Text("Excellent! You can stop now.")
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            Button {
                Task {
                    extractedEmbedding = await manager.stopRecording()
                }
            } label: {
                Label("Stop Recording", systemImage: "stop.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(duration < manager.minimumDuration)
        }
    }

    private func doneState(name: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.green)
            Text("Profile saved for \"\(name)\"")
                .font(.callout)
        }
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title)
                .foregroundStyle(.yellow)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                extractedEmbedding = nil
                if case .error = manager.state {
                    Task { await manager.prepare() }
                }
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Helpers

    private func levelMeter(level: Float) -> some View {
        GeometryReader { geo in
            let barWidth = max(0, CGFloat(level) * geo.size.width)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.gray.opacity(0.15))
                RoundedRectangle(cornerRadius: 3)
                    .fill(level > 0.8 ? Color.red : Color.green)
                    .frame(width: barWidth)
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: 6)
        .frame(maxWidth: 300)
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        let s = Int(t)
        let ms = Int((t - Double(s)) * 10)
        return String(format: "%d.%d s", s, ms)
    }
}
