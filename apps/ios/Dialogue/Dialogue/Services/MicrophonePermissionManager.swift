import AVFoundation
import Foundation

/// Manages microphone permission state for the iOS app.
/// - If already granted, proceeds silently with no UI.
/// - If not granted, surfaces a one-time permission request screen.
@MainActor
final class MicrophonePermissionManager: ObservableObject {
    @Published var micGranted = false
    @Published var hasChecked = false

    /// Silent check on launch — no UI unless permission is missing.
    func checkPermission() async {
        let status = AVAudioApplication.shared.recordPermission
        switch status {
        case .granted:
            micGranted = true
        case .denied, .undetermined:
            micGranted = false
        @unknown default:
            micGranted = false
        }
        hasChecked = true
    }

    /// Request microphone access (called from the permission screen button).
    func requestPermission() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        micGranted = granted
    }
}
