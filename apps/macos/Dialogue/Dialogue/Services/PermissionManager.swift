import DialogueCore
import AVFoundation
import AppKit
import OSLog
import ScreenCaptureKit

/// Centralized manager for all OS-level permissions the app requires.
///
/// Permissions managed:
/// - **Microphone**: Required for meeting recording and voice commands.
/// - **Screen Recording**: Required for ScreenCaptureKit per-app audio capture.
/// - **Accessibility**: Optional, used for voice command text selection (Cmd+C simulation).
///
/// Usage:
/// - Call `PermissionManager.shared.refreshAll()` on app launch.
/// - Show `PermissionOnboardingView` when `allRequiredGranted` is false.
/// - Individual subsystems should call `PermissionManager.shared.microphoneStatus` etc.
///   instead of checking permissions directly.
@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "Permissions")

    // MARK: - Permission Status

    enum Status: Equatable {
        case unknown
        case granted
        case denied
        case notDetermined
    }

    @Published private(set) var microphoneStatus: Status = .unknown
    @Published private(set) var screenRecordingStatus: Status = .unknown
    @Published private(set) var accessibilityStatus: Status = .unknown

    /// True when both required permissions (mic + screen recording) are granted.
    var allRequiredGranted: Bool {
        microphoneStatus == .granted && screenRecordingStatus == .granted
    }

    /// True when all permissions including optional ones are granted.
    var allGranted: Bool {
        allRequiredGranted && accessibilityStatus == .granted
    }

    private init() {}

    // MARK: - Refresh All

    /// Re-check all permission statuses. Call on app launch and when returning
    /// from System Settings.
    func refreshAll() async {
        checkMicrophone()
        await checkScreenRecording()
        checkAccessibility()
        logger.info("Permissions: mic=\(self.microphoneStatus == .granted), screen=\(self.screenRecordingStatus == .granted), accessibility=\(self.accessibilityStatus == .granted)")
    }

    // MARK: - Microphone

    /// Check current microphone authorization without prompting.
    func checkMicrophone() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphoneStatus = .granted
        case .denied, .restricted:
            microphoneStatus = .denied
        case .notDetermined:
            microphoneStatus = .notDetermined
        @unknown default:
            microphoneStatus = .unknown
        }
    }

    /// Request microphone access. Only prompts if status is `.notDetermined`.
    func requestMicrophone() async {
        checkMicrophone()
        guard microphoneStatus == .notDetermined else { return }

        logger.info("Requesting microphone permission")
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphoneStatus = granted ? .granted : .denied
        logger.info("Microphone permission \(granted ? "granted" : "denied")")
    }

    // MARK: - Screen Recording (ScreenCaptureKit)

    /// Check screen recording permission by attempting to enumerate shareable content.
    ///
    /// ScreenCaptureKit doesn't have a simple `authorizationStatus` API.
    /// On macOS 15+, `SCShareableContent` throws an error if permission isn't granted.
    /// On earlier versions, we use `CGPreflightScreenCaptureAccess()`.
    func checkScreenRecording() async {
        // Try ScreenCaptureKit enumeration — if it succeeds, we have permission.
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            screenRecordingStatus = .granted
        } catch {
            // SCShareableContent throws if screen recording is not authorized.
            // The error code varies by macOS version, so treat any failure as denied/not-determined.
            let nsError = error as NSError
            if nsError.domain == "com.apple.ScreenCaptureKit.SCStreamError" {
                // User has explicitly denied or hasn't been prompted yet.
                screenRecordingStatus = .denied
            } else {
                // Fallback: use the CG preflight check
                if CGPreflightScreenCaptureAccess() {
                    screenRecordingStatus = .granted
                } else {
                    screenRecordingStatus = .denied
                }
            }
        }
    }

    /// Request screen recording access.
    ///
    /// On macOS, this opens the Screen Recording pane in System Settings.
    /// The user must manually toggle the switch. After they return to the app,
    /// call `refreshAll()` to re-check.
    func requestScreenRecording() {
        logger.info("Requesting screen recording permission")
        // CGRequestScreenCaptureAccess opens System Settings on first call,
        // or returns the current status on subsequent calls.
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Accessibility

    /// Check if the app has Accessibility (trusted) access.
    /// Used for CGEvent posting (voice command Cmd+C simulation).
    func checkAccessibility() {
        accessibilityStatus = AXIsProcessTrusted() ? .granted : .denied
    }

    /// Prompt the user to grant Accessibility access.
    /// Opens the Accessibility pane in System Settings with our app highlighted.
    func requestAccessibility() {
        logger.info("Requesting accessibility permission")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        // Re-check after a brief delay (the prompt is async)
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            checkAccessibility()
        }
    }

    // MARK: - Open System Settings

    /// Open the relevant System Settings pane for a given permission.
    func openSystemSettings(for permission: Permission) {
        let urlString: String
        switch permission {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .screenRecording:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        case .accessibility:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    enum Permission {
        case microphone
        case screenRecording
        case accessibility
    }
}
