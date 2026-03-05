import DialogueCore
import SwiftUI

// MARK: - Waveform Pill

/// A capsule-shaped HUD with an animated three-channel beam waveform,
/// metal grille overlay, and traveling shimmer sweep. Visually matches
/// the dictation pill from the original VibeTalk app.
///
/// `audioLevel` drives the waveform amplitude (0 = silence, 1 = loud).
/// When `isRecording` is false, the waveform shows a gentle idle animation.
struct WaveformPillView: View {
    var audioLevel: Float = 0
    var isRecording: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var motion = WaveMotionModel()

    private var isDark: Bool { colorScheme == .dark }

    // Pill sizing
    private let pillWidth: CGFloat = 170
    private let pillHeight: CGFloat = 32
    private let waveformHeight: CGFloat = 24
    private let strokeWidth: CGFloat = 1.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let amplitude = motion.smoothedAmplitude(
                audioLevel: audioLevel,
                isRecording: isRecording,
                time: timeline.date.timeIntervalSinceReferenceDate
            )

            ZStack {
                // Background
                Capsule(style: .continuous)
                    .fill(isDark ? Color.black : Color(red: 0.96, green: 0.97, blue: 0.98))

                // Waveform beams
                WaveformBeamLayer(
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    amplitude: amplitude,
                    isRecording: isRecording,
                    isDark: isDark
                )
                .frame(height: waveformHeight)
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.08),
                            .init(color: .black, location: 0.92),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )

                // Metal grille
                GrilleOverlay(isDark: isDark)
                    .allowsHitTesting(false)
            }
            .frame(width: pillWidth, height: pillHeight)
            .clipShape(Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .stroke(
                        isDark ? Color.black.opacity(0.16) : Color.black.opacity(0.12),
                        lineWidth: strokeWidth
                    )
            }
            .shadow(color: .black.opacity(isDark ? 0.34 : 0.20), radius: 24, x: 0, y: 14)
            .shadow(color: .black.opacity(isDark ? 0.16 : 0.08), radius: 6, x: 0, y: 2)
        }
    }
}

// MARK: - Standalone Waveform Bar

/// A bare waveform animation (no pill chrome) suitable for embedding in
/// banners and bars. Stretches to fill its frame.
struct WaveformBarView: View {
    var audioLevel: Float = 0
    var isRecording: Bool = true

    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var motion = WaveMotionModel()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
            let amplitude = motion.smoothedAmplitude(
                audioLevel: audioLevel,
                isRecording: isRecording,
                time: timeline.date.timeIntervalSinceReferenceDate
            )

            WaveformBeamLayer(
                time: timeline.date.timeIntervalSinceReferenceDate,
                amplitude: amplitude,
                isRecording: isRecording,
                isDark: colorScheme == .dark
            )
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.04),
                        .init(color: .black, location: 0.96),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
    }
}

// MARK: - Waveform Beam Layer

/// Canvas-drawn three-channel waveform: blue (bass), warm white (core), orange (treble).
struct WaveformBeamLayer: View {
    let time: TimeInterval
    let amplitude: CGFloat
    let isRecording: Bool
    let isDark: Bool

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard size.width > 1, size.height > 1 else { return }

            let centerY = size.height * 0.5
            let clamped = max(0, min(amplitude, 1))
            let energy = pow(clamped, 0.65)
            let boost: CGFloat = 1.65

            let idleAmp = max(size.height * 0.010, 0.34)
            let speechAmp = size.height * (0.04 + (energy * 0.52 * boost))
            let rawAmp = idleAmp + (isRecording ? speechAmp : speechAmp * 0.25)
            let waveAmp = min(size.height * 0.46, rawAmp)
            let coreW = max(0.8, (size.height * 0.035) + (energy * 0.7))
            let alive: CGFloat = isRecording ? 1.0 : 0.42
            let spread = max(0.8, size.height * 0.048) + (energy * 0.9)

            let bluePath = makePath(width: size.width, centerY: centerY + spread, amp: waveAmp, time: time, phase: 0.04, energy: energy)
            let corePath = makePath(width: size.width, centerY: centerY, amp: waveAmp, time: time, phase: 0, energy: energy)
            let orangePath = makePath(width: size.width, centerY: centerY - spread, amp: waveAmp, time: time, phase: -0.04, energy: energy)

            let blue: Color = isDark ? Color(red: 0.04, green: 0.28, blue: 1.0) : Color(red: 0.11, green: 0.13, blue: 0.18)
            let white: Color = isDark ? Color(red: 1.0, green: 0.93, blue: 0.80) : Color(red: 0.05, green: 0.06, blue: 0.09)
            let orange: Color = isDark ? Color(red: 1.0, green: 0.45, blue: 0.0) : Color(red: 0.22, green: 0.15, blue: 0.12)

            let blend: GraphicsContext.BlendMode = isDark ? .plusLighter : .normal
            let glowScale: CGFloat = isDark ? 1.0 : 0.58
            let coreScale: CGFloat = isDark ? 1.0 : 0.78
            let haloScale: CGFloat = isDark ? 1.0 : 0.84

            context.blendMode = blend

            // Blue base
            context.stroke(bluePath, with: .color(blue.opacity(Double(0.18 * alive * glowScale))), lineWidth: coreW * 5.0 * haloScale)
            context.stroke(bluePath, with: .color(blue.opacity(Double(0.42 * alive * glowScale))), lineWidth: coreW * 2.2 * haloScale)
            context.stroke(bluePath, with: .color(blue.opacity(Double(0.90 * alive * coreScale))), lineWidth: coreW)

            // Warm white core
            context.stroke(corePath, with: .color(white.opacity(Double(0.06 * alive * glowScale))), lineWidth: coreW * 3.5 * haloScale)
            context.stroke(corePath, with: .color(white.opacity(Double(0.28 * alive * coreScale))), lineWidth: coreW * 1.6 * haloScale)
            context.stroke(corePath, with: .color(white.opacity(Double(0.88 * alive * coreScale))), lineWidth: coreW * 0.6)

            // Orange edge
            context.stroke(orangePath, with: .color(orange.opacity(Double(0.20 * alive * glowScale))), lineWidth: coreW * 5.5 * haloScale)
            context.stroke(orangePath, with: .color(orange.opacity(Double(0.40 * alive * glowScale))), lineWidth: coreW * 2.4 * haloScale)
            context.stroke(orangePath, with: .color(orange.opacity(Double(0.82 * alive * coreScale))), lineWidth: coreW)

            // Traveling shimmer sweep
            let sweepColor: Color = isDark ? .white : .black
            let sweepScale: CGFloat = isDark ? 1.0 : 0.72
            let sweepPhase = CGFloat(time.truncatingRemainder(dividingBy: 5.0) / 5.0)
            let sweepHalfW = max(22, size.width * 0.20)
            let totalTravel = size.width + sweepHalfW * 2
            let sweepX = (size.width + sweepHalfW) - sweepPhase * totalTravel
            let sweepRect = CGRect(x: sweepX - sweepHalfW, y: 0, width: sweepHalfW * 2, height: size.height)
            let gradient = Gradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: sweepColor.opacity(Double((isRecording ? 0.10 : 0.04) * sweepScale)), location: 0.38),
                .init(color: sweepColor.opacity(Double((isRecording ? 0.18 : 0.06) * sweepScale)), location: 0.5),
                .init(color: sweepColor.opacity(Double((isRecording ? 0.10 : 0.04) * sweepScale)), location: 0.62),
                .init(color: .clear, location: 1),
            ])
            context.fill(
                Path(sweepRect),
                with: .linearGradient(gradient, startPoint: CGPoint(x: sweepRect.minX, y: centerY), endPoint: CGPoint(x: sweepRect.maxX, y: centerY))
            )
        }
    }

    private func makePath(width: CGFloat, centerY: CGFloat, amp: CGFloat, time: TimeInterval, phase: CGFloat, energy: CGFloat) -> Path {
        let count = max(Int(width / 2), 72)
        let p = CGFloat(time) * 2.6 + phase
        var path = Path()
        for i in 0...count {
            let x = (CGFloat(i) / CGFloat(count)) * width
            let nx = x / max(width, 1)
            var signal: CGFloat =
                sin(nx * 15.0 + p) * 0.46 +
                sin(nx * 28.0 + p * 1.30 + 1.1) * 0.24
            signal +=
                sin(nx * 44.0 + p * 1.82 + 0.4) * (0.10 + energy * 0.14) +
                sin(nx * 65.0 + p * 2.20 + 0.8) * energy * 0.16 +
                sin(nx * 92.0 + p * 2.80 + 1.5) * energy * 0.10
            let y = centerY + signal * amp
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

// MARK: - Metal Grille Overlay

private struct GrilleOverlay: View {
    let isDark: Bool

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, size in
            guard size.width > 1, size.height > 1 else { return }

            let slatWidth: CGFloat = max(3.5, size.width * 0.026)
            let spacing: CGFloat = max(28, size.width * 0.18)
            let centerX = size.width * 0.5
            let slatCount = Int((size.width * 0.80) / spacing)

            let metalColor: Color = isDark ? .black.opacity(0.54) : .black.opacity(0.10)
            let highlightColor: Color = isDark ? .white.opacity(0.08) : .white.opacity(0.36)

            for index in 0...slatCount {
                let offset = CGFloat(index) - CGFloat(slatCount) * 0.5
                let x = centerX + (offset * spacing)
                let rect = CGRect(x: x - slatWidth * 0.5, y: 0, width: slatWidth, height: size.height)
                context.fill(Path(rect), with: .color(metalColor))

                var hlPath = Path()
                hlPath.move(to: CGPoint(x: x + slatWidth * 0.5, y: 0))
                hlPath.addLine(to: CGPoint(x: x + slatWidth * 0.5, y: size.height))
                context.stroke(hlPath, with: .color(highlightColor), lineWidth: 0.5)
            }
        }
    }
}

// MARK: - Wave Motion Model

@MainActor
final class WaveMotionModel: ObservableObject {
    private var smoothedLevel: CGFloat = 0

    func smoothedAmplitude(audioLevel: Float, isRecording: Bool, time _: TimeInterval) -> CGFloat {
        guard isRecording else {
            smoothedLevel = 0
            return 0.1
        }
        let clamped = max(0, min(CGFloat(audioLevel), 1.0))
        smoothedLevel = smoothedLevel * 0.80 + clamped * 0.20
        return smoothedLevel
    }
}

// MARK: - Preview

#Preview("Waveform Pill — Dark") {
    WaveformPillView(audioLevel: 0.6, isRecording: true)
        .padding(40)
        .background(.black)
        .preferredColorScheme(.dark)
}

#Preview("Waveform Pill — Light") {
    WaveformPillView(audioLevel: 0.4, isRecording: true)
        .padding(40)
        .background(Color(white: 0.95))
        .preferredColorScheme(.light)
}
