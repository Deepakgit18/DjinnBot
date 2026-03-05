import SwiftUI

/// One-time permission request screen shown only when microphone access
/// has not yet been granted. Clean, minimal, single-purpose.
struct MicrophonePermissionView: View {
    @ObservedObject var manager: MicrophonePermissionManager

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image(systemName: "mic.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.tint)

            Text("Microphone Access")
                .font(.title.bold())

            Text("Dialogue needs microphone access to record meetings. Audio is processed on-device and never leaves your phone without your consent.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button {
                Task { await manager.requestPermission() }
            } label: {
                Text("Grant Microphone Access")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)

            Spacer()
            Spacer()
        }
    }
}
