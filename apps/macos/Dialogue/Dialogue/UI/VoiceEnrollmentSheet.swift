import SwiftUI

/// Sheet for enrolling a new speaker voice via 3 recording clips.
///
/// Flow:
/// 1. User enters a name.
/// 2. For each of 3 clips, a reading prompt is displayed.
/// 3. User presses "Start Recording", reads the prompt aloud (~10 seconds).
/// 4. User presses "Stop" — clip is stored.
/// 5. After 3 clips, presses "Save" to enroll via VoiceID.
@available(macOS 26.0, *)
struct VoiceEnrollmentSheet: View {

    @StateObject private var manager = VoiceEnrollmentManager()
    @Environment(\.dismiss) private var dismiss

    /// Called after a successful enrollment so the parent can refresh.
    var onComplete: () -> Void = {}

    @State private var speakerName: String = ""
    @State private var selectedColorIndex: Int = 0

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
                Text("Record 3 clips of clear speech (~10 seconds each) to create a voice profile.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Divider()

            // Name field
            TextField("Speaker Name (e.g. your name)", text: $speakerName)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)

            // Color picker
            VStack(spacing: 4) {
                Text("Speaker Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                speakerColorPicker
            }

            // Progress indicator
            clipProgressView

            // Recording UI
            VStack(spacing: 12) {
                switch manager.state {
                case .idle:
                    ProgressView("Preparing...")
                        .controlSize(.small)

                case .ready:
                    if manager.allClipsRecorded {
                        allClipsRecordedState
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

                if manager.allClipsRecorded,
                   !speakerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Save Profile") {
                        Task {
                            let success = await manager.saveProfile(name: speakerName, colorIndex: selectedColorIndex)
                            if success {
                                onComplete()
                                dismiss()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .task {
            await manager.prepare()
        }
        .onDisappear {
            manager.cleanup()
        }
    }

    // MARK: - Clip Progress

    private var clipProgressView: some View {
        HStack(spacing: 8) {
            ForEach(0..<manager.requiredClipCount, id: \.self) { index in
                Circle()
                    .fill(index < manager.clipCount ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 10, height: 10)
            }
            Text("Clip \(min(manager.clipCount + 1, manager.requiredClipCount)) of \(manager.requiredClipCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Color Picker

    private var speakerColorPicker: some View {
        let columns = Array(repeating: GridItem(.fixed(24), spacing: 6), count: 7)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(0..<CatppuccinSpeaker.palette.count, id: \.self) { index in
                Button {
                    selectedColorIndex = index
                } label: {
                    ZStack {
                        Circle()
                            .fill(CatppuccinSpeaker.palette[index])
                            .frame(width: 22, height: 22)
                        if selectedColorIndex == index {
                            Circle()
                                .strokeBorder(Color.primary, lineWidth: 2)
                                .frame(width: 22, height: 22)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(CatppuccinSpeaker.paletteNames[index])
            }
        }
        .frame(maxWidth: 220)
    }

    // MARK: - State Views

    private var allClipsRecordedState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title)
                .foregroundStyle(.green)
            Text("All \(manager.requiredClipCount) clips recorded. Click Save Profile below.")
                .font(.callout)
                .multilineTextAlignment(.center)
        }
    }

    private var readyState: some View {
        VStack(spacing: 12) {
            // Reading prompt
            VStack(alignment: .leading, spacing: 6) {
                Text("Read this aloud:")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                Text(manager.currentPrompt)
                    .font(.system(.body, design: .serif))
                    .italic()
                    .lineSpacing(4)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.04))
                    )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

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
            // Reading prompt (visible during recording)
            Text(manager.currentPrompt)
                .font(.system(.body, design: .serif))
                .italic()
                .lineSpacing(4)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.04))
                )
                .frame(maxWidth: .infinity, alignment: .leading)

            levelMeter(level: manager.peakLevel)

            HStack(spacing: 12) {
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
                    _ = await manager.stopRecording()
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
