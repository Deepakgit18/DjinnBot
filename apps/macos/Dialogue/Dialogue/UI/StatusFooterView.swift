import SwiftUI

// MARK: - StatusFooterView

/// A persistent footer bar at the bottom of the main window.
/// Shows model download progress, detected meeting apps, and recording preparation status.
struct StatusFooterView: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            StatusFooterContent()
        } else {
            EmptyView()
        }
    }
}

@available(macOS 26.0, *)
private struct StatusFooterContent: View {
    @ObservedObject private var preloader = ModelPreloader.shared
    @ObservedObject private var refinement = RefinementProgress.shared

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                if refinement.isActive || isRefinementResult {
                    refinementContent
                } else {
                    preloaderContent
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    /// True when refinement just finished (complete or failed) and is still showing.
    private var isRefinementResult: Bool {
        switch refinement.state {
        case .complete, .failed: return true
        default: return false
        }
    }

    // MARK: - Refinement Progress

    @ViewBuilder
    private var refinementContent: some View {
        switch refinement.state {
        case .preparingModels:
            ProgressView()
                .controlSize(.small)
            Text(refinement.description)
                .font(.caption)
                .foregroundStyle(.secondary)

        case .diarizing, .transcribing, .buildingTranscript:
            ProgressView()
                .controlSize(.small)
            Text(refinement.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let fraction = refinement.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 140)
            }

        case .complete:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            Text(refinement.description)
                .font(.caption)
                .foregroundStyle(.secondary)

        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
            Text(refinement.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

        case .idle:
            EmptyView()
        }
    }

    // MARK: - Model Preloader Status

    @ViewBuilder
    private var preloaderContent: some View {
        switch preloader.state {
        case .idle:
            ProgressView()
                .controlSize(.small)
            Text("Preparing models...")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .downloading(let description, let fraction):
            ProgressView()
                .controlSize(.small)
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 120)
            }

        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Retry") {
                preloader.preload()
            }
            .buttonStyle(.borderless)
            .font(.caption)

        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
            Text("Ready")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
