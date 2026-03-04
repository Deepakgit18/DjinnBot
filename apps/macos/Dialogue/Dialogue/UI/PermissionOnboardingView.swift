import SwiftUI

/// Full-screen onboarding view shown on first launch (or whenever required
/// permissions are missing). Walks the user through granting microphone and
/// screen recording access, with an optional accessibility step.
///
/// The view auto-refreshes permission statuses when the app regains focus
/// (e.g. after the user toggles a switch in System Settings).
struct PermissionOnboardingView: View {
    @ObservedObject private var permissions = PermissionManager.shared

    /// Dismiss callback — called when all required permissions are granted.
    var onComplete: () -> Void

    /// Tracks which step the user is on (0-based).
    @State private var currentStep = 0

    private let steps: [PermissionStep] = [
        PermissionStep(
            permission: .microphone,
            title: "Microphone Access",
            subtitle: "Dialogue needs your microphone to record meetings and transcribe voice commands.",
            systemImage: "mic.fill",
            buttonLabel: "Allow Microphone"
        ),
        PermissionStep(
            permission: .screenRecording,
            title: "Screen & Audio Capture",
            subtitle: "Dialogue captures audio from meeting apps (Zoom, Teams, etc.) using ScreenCaptureKit. No video is recorded.",
            systemImage: "rectangle.dashed.badge.record",
            buttonLabel: "Open System Settings"
        ),
        PermissionStep(
            permission: .accessibility,
            title: "Accessibility (Optional)",
            subtitle: "Allows voice commands to read selected text from other apps. You can skip this and enable it later in Settings.",
            systemImage: "hand.raised.fill",
            buttonLabel: "Enable Accessibility",
            isOptional: true
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // App icon + title
            VStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 96, height: 96)

                Text("Welcome to Dialogue")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("A few permissions are needed before we get started.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 40)

            // Permission cards
            VStack(spacing: 16) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    PermissionCard(
                        step: step,
                        status: status(for: step.permission),
                        isCurrent: index == currentStep,
                        onRequest: {
                            Task { await requestPermission(step.permission) }
                        },
                        onSkip: step.isOptional ? { advanceStep() } : nil,
                        onOpenSettings: {
                            permissions.openSystemSettings(for: step.permission)
                        }
                    )
                }
            }
            .frame(maxWidth: 500)

            Spacer()

            // Continue button — enabled when all required permissions are granted
            if permissions.allRequiredGranted {
                Button("Get Started") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Re-check permissions when user returns from System Settings
            Task {
                await permissions.refreshAll()
                autoAdvanceStep()
            }
        }
        .task {
            await permissions.refreshAll()
            autoAdvanceStep()
        }
    }

    // MARK: - Helpers

    private func status(for permission: PermissionManager.Permission) -> PermissionManager.Status {
        switch permission {
        case .microphone: return permissions.microphoneStatus
        case .screenRecording: return permissions.screenRecordingStatus
        case .accessibility: return permissions.accessibilityStatus
        }
    }

    private func requestPermission(_ permission: PermissionManager.Permission) async {
        switch permission {
        case .microphone:
            await permissions.requestMicrophone()
        case .screenRecording:
            permissions.requestScreenRecording()
        case .accessibility:
            permissions.requestAccessibility()
        }

        // Small delay then re-check and auto-advance
        try? await Task.sleep(for: .milliseconds(300))
        await permissions.refreshAll()
        autoAdvanceStep()
    }

    /// Move currentStep to the first non-granted required permission,
    /// or to accessibility if required ones are done.
    private func autoAdvanceStep() {
        for (index, step) in steps.enumerated() {
            let s = status(for: step.permission)
            if s != .granted && !step.isOptional {
                currentStep = index
                return
            }
        }
        // All required are granted — point to accessibility if not granted
        if permissions.accessibilityStatus != .granted {
            currentStep = steps.count - 1
        }
    }

    private func advanceStep() {
        if currentStep < steps.count - 1 {
            currentStep += 1
        }
    }
}

// MARK: - PermissionStep Model

struct PermissionStep {
    let permission: PermissionManager.Permission
    let title: String
    let subtitle: String
    let systemImage: String
    let buttonLabel: String
    var isOptional: Bool = false
}

// MARK: - PermissionCard

private struct PermissionCard: View {
    let step: PermissionStep
    let status: PermissionManager.Status
    let isCurrent: Bool
    let onRequest: () -> Void
    var onSkip: (() -> Void)?
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            // Icon
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(iconBackground)
                    .frame(width: 44, height: 44)

                Image(systemName: step.systemImage)
                    .font(.title3)
                    .foregroundStyle(iconForeground)
            }

            // Text
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(step.title)
                        .fontWeight(.semibold)

                    if step.isOptional {
                        Text("Optional")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                    }
                }

                Text(step.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer()

            // Status / Action
            if status == .granted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            } else if isCurrent {
                VStack(spacing: 6) {
                    if status == .denied {
                        // Already denied — need to go to System Settings
                        Button("Open Settings") {
                            onOpenSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    } else {
                        Button(step.buttonLabel) {
                            onRequest()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }

                    if let onSkip {
                        Button("Skip") {
                            onSkip()
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isCurrent && status != .granted
                      ? Color.accentColor.opacity(0.06)
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isCurrent && status != .granted
                        ? Color.accentColor.opacity(0.3)
                        : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 1
                )
        )
        .opacity(status == .granted ? 0.7 : 1.0)
    }

    private var iconBackground: Color {
        if status == .granted {
            return .green.opacity(0.15)
        } else if isCurrent {
            return .accentColor.opacity(0.15)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var iconForeground: Color {
        if status == .granted {
            return .green
        } else if isCurrent {
            return .accentColor
        }
        return .secondary
    }
}
