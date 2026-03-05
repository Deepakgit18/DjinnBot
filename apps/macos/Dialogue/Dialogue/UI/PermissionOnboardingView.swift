import DialogueCore
import SwiftUI

/// Full-screen onboarding view shown on first launch (or whenever required
/// permissions are missing). Walks the user through granting microphone and
/// screen recording access, with an optional accessibility step.
///
/// **When all permissions are already granted** the view plays a quick
/// staggered check-mark animation (each card checks in sequence) then
/// auto-dismisses — giving the user visual confirmation without a jarring flash.
///
/// **When some permissions are missing** the view stops at the first
/// un-granted required permission and waits for the user to grant it.
/// The view auto-refreshes when the app regains focus (e.g. after
/// toggling a switch in System Settings).
struct PermissionOnboardingView: View {
    @ObservedObject private var permissions = PermissionManager.shared

    /// Dismiss callback — called when all required permissions are granted.
    var onComplete: () -> Void

    /// Tracks which step the user is on (0-based).
    @State private var currentStep = 0

    /// Controls the initial staggered reveal of permission statuses.
    /// Each element flips from `.unknown` to the real status after a delay,
    /// creating a sequential check-in animation on launch.
    @State private var revealedStatuses: [PermissionManager.Status] = [.unknown, .unknown, .unknown]

    /// Whether the initial permission check sequence has finished.
    @State private var initialCheckDone = false

    /// Whether the header content has appeared (for entrance animation).
    @State private var headerVisible = false

    /// Per-card appearance flag for staggered entrance.
    @State private var cardVisible: [Bool] = [false, false, false]

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
            .opacity(headerVisible ? 1 : 0)
            .offset(y: headerVisible ? 0 : 10)
            .padding(.bottom, 40)

            // Permission cards
            VStack(spacing: 16) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    PermissionCard(
                        step: step,
                        status: revealedStatuses[index],
                        isCurrent: initialCheckDone && index == currentStep,
                        onRequest: {
                            Task { await requestPermission(step.permission) }
                        },
                        onSkip: step.isOptional ? { advanceStep() } : nil,
                        onOpenSettings: {
                            permissions.openSystemSettings(for: step.permission)
                        }
                    )
                    .opacity(cardVisible[index] ? 1 : 0)
                    .offset(y: cardVisible[index] ? 0 : 12)
                }
            }
            .frame(maxWidth: 500)

            Spacer()

            // Continue button — enabled when all required permissions are granted
            // and the initial check animation has finished.
            if initialCheckDone && permissions.allRequiredGranted {
                Button("Get Started") {
                    onComplete()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 32)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard initialCheckDone else { return }
            // Re-check permissions when user returns from System Settings
            Task {
                await permissions.refreshAll()
                syncRevealedStatuses()
                autoAdvanceStep()
            }
        }
        .task {
            await runInitialCheckSequence()
        }
    }

    // MARK: - Initial Check Sequence

    /// Checks each permission in sequence with staggered delays,
    /// animating each card's status reveal one at a time.
    /// If everything is granted, auto-dismisses after the animation.
    private func runInitialCheckSequence() async {
        // 1. Fade in header
        withAnimation(.easeOut(duration: 0.4)) {
            headerVisible = true
        }
        try? await Task.sleep(for: .milliseconds(200))

        // 2. Fetch all permissions up front (so we know the real statuses)
        await permissions.refreshAll()

        // 3. Stagger-reveal each card
        for index in steps.indices {
            // Fade the card in
            withAnimation(.easeOut(duration: 0.35)) {
                cardVisible[index] = true
            }
            try? await Task.sleep(for: .milliseconds(150))

            // Reveal the real status with a spring animation
            let realStatus = liveStatus(for: steps[index].permission)
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                revealedStatuses[index] = realStatus
            }

            // Pause between cards — longer if it's a checkmark (let it land)
            let delay: Duration = realStatus == .granted ? .milliseconds(400) : .milliseconds(200)
            try? await Task.sleep(for: delay)
        }

        // 4. Mark the initial check as done
        initialCheckDone = true
        autoAdvanceStep()

        // 5. If everything required is already granted, auto-dismiss after a beat
        if permissions.allRequiredGranted {
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(.easeInOut(duration: 0.35)) {
                onComplete()
            }
        }
    }

    // MARK: - Helpers

    /// Returns the live permission status (not the revealed/animated one).
    private func liveStatus(for permission: PermissionManager.Permission) -> PermissionManager.Status {
        switch permission {
        case .microphone: return permissions.microphoneStatus
        case .screenRecording: return permissions.screenRecordingStatus
        case .accessibility: return permissions.accessibilityStatus
        }
    }

    /// Syncs revealed statuses with the live permission state (used after
    /// returning from System Settings).
    private func syncRevealedStatuses() {
        for (index, step) in steps.enumerated() {
            let live = liveStatus(for: step.permission)
            if revealedStatuses[index] != live {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                    revealedStatuses[index] = live
                }
            }
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

        // Small delay then re-check and animate
        try? await Task.sleep(for: .milliseconds(300))
        await permissions.refreshAll()
        syncRevealedStatuses()
        autoAdvanceStep()
    }

    /// Move currentStep to the first non-granted required permission,
    /// or to accessibility if required ones are done.
    private func autoAdvanceStep() {
        for (index, step) in steps.enumerated() {
            let s = liveStatus(for: step.permission)
            if s != .granted && !step.isOptional {
                withAnimation(.easeInOut(duration: 0.25)) {
                    currentStep = index
                }
                return
            }
        }
        // All required are granted — point to accessibility if not granted
        if permissions.accessibilityStatus != .granted {
            withAnimation(.easeInOut(duration: 0.25)) {
                currentStep = steps.count - 1
            }
        }
    }

    private func advanceStep() {
        if currentStep < steps.count - 1 {
            withAnimation(.easeInOut(duration: 0.25)) {
                currentStep += 1
            }
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
            Group {
                if status == .unknown {
                    // Checking — subtle spinner
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                } else if status == .granted {
                    // Animated checkmark
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else if isCurrent {
                    VStack(spacing: 6) {
                        if status == .denied {
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
                    .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: status)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isCurrent && status != .granted && status != .unknown
                      ? Color.accentColor.opacity(0.06)
                      : Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isCurrent && status != .granted && status != .unknown
                        ? Color.accentColor.opacity(0.3)
                        : Color(nsColor: .separatorColor).opacity(0.5),
                    lineWidth: 1
                )
        )
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
        .animation(.easeInOut(duration: 0.25), value: status)
    }

    private var iconBackground: Color {
        if status == .granted {
            return .green.opacity(0.15)
        } else if isCurrent && status != .unknown {
            return .accentColor.opacity(0.15)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var iconForeground: Color {
        if status == .granted {
            return .green
        } else if isCurrent && status != .unknown {
            return .accentColor
        }
        return .secondary
    }
}
