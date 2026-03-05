import FluidAudio
import Foundation
import OSLog
import Speech

/// Pre-downloads and caches ASR (SpeechAnalyzer) and diarization models
/// at app launch so recording can start instantly without waiting for
/// model downloads.
///
/// Supports both Sortformer and Pyannote diarization backends. The active
/// backend is determined by the `diarizationMode` stored in `UserDefaults`.
///
/// Publish `state` so the UI can show download progress and disable recording
/// until models are ready.
@MainActor
public final class ModelPreloader: ObservableObject {

    public static let shared = ModelPreloader()

    // MARK: - Published State

    public enum State: Equatable {
        case idle
        case downloading(description: String, fractionComplete: Double?)
        case ready
        case failed(String)

        public var isReady: Bool { self == .ready }
    }

    @Published public private(set) var state: State = .idle

    /// Optional progress object exposed for SwiftUI ProgressView binding.
    @Published public private(set) var downloadProgress: Progress?

    // MARK: - Cached Results

    /// Pre-loaded Sortformer models, reused by `RealtimeDiarizationManager`.
    public private(set) var sortformerModels: SortformerModels?

    /// Pre-loaded Pyannote diarizer models (segmentation + WeSpeaker).
    public private(set) var diarizerModels: DiarizerModels?

    /// The diarization mode that was used for the last preload.
    public private(set) var preloadedMode: DiarizationMode?

    /// Matched ASR locale (confirmed available on this device).
    public private(set) var asrLocale: Locale?

    /// Whether ASR assets are confirmed installed.
    public private(set) var asrAssetsInstalled = false

    // MARK: - Private

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "ModelPreloader")
    private var preloadTask: Task<Void, Never>?

    private init() {}

    // MARK: - Preload

    /// Trigger model downloads. Safe to call multiple times; subsequent calls
    /// are no-ops if already loading or ready.
    public func preload() {
        guard state == .idle || isFailedState else { return }
        preloadTask?.cancel()
        preloadTask = Task { await performPreload() }
    }

    /// Re-preload diarization models if the selected mode has changed since
    /// the last preload. Call this when the user switches diarization mode.
    public func preloadIfModeChanged() {
        let currentMode = Self.selectedDiarizationMode
        if preloadedMode != currentMode {
            logger.info("Diarization mode changed to \(currentMode.rawValue); re-preloading models")
            // Clear stale models for the previous mode
            sortformerModels = nil
            diarizerModels = nil
            preloadedMode = nil
            state = .idle
            preload()
        }
    }

    private var isFailedState: Bool {
        if case .failed = state { return true }
        return false
    }

    /// Read the currently selected diarization mode from UserDefaults.
    public static var selectedDiarizationMode: DiarizationMode {
        let raw = UserDefaults.standard.string(forKey: "diarizationMode")
            ?? DiarizationMode.pyannoteStreaming.rawValue
        return DiarizationMode(rawValue: raw) ?? .pyannoteStreaming
    }

    private func performPreload() async {
        state = .downloading(description: "Checking ASR assets...", fractionComplete: nil)
        logger.info("Starting model preload")

        // --- ASR assets ---
        do {
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
                logger.warning("No supported ASR locale for \(Locale.current.identifier)")
                // ASR unavailable is non-fatal; diarization still runs
                state = .downloading(description: "Downloading diarization models...", fractionComplete: nil)
                try await preloadDiarization()
                state = .ready
                return
            }
            self.asrLocale = locale
            logger.info("ASR locale matched: \(locale.identifier)")

            let transcriber = SpeechTranscriber(
                locale: locale,
                preset: .timeIndexedProgressiveTranscription
            )

            state = .downloading(description: "Checking ASR assets...", fractionComplete: nil)

            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                logger.info("ASR assets need downloading")
                state = .downloading(description: "Downloading speech recognition model...", fractionComplete: 0)
                self.downloadProgress = downloader.progress

                // Observe progress on the main actor
                let progress = downloader.progress
                let observation = Task { @MainActor in
                    while !Task.isCancelled && !progress.isFinished {
                        self.state = .downloading(
                            description: "Downloading speech recognition model...",
                            fractionComplete: progress.fractionCompleted
                        )
                        try? await Task.sleep(for: .milliseconds(250))
                    }
                }

                try await downloader.downloadAndInstall()
                observation.cancel()
                self.downloadProgress = nil
                logger.info("ASR assets installed")
            } else {
                logger.info("ASR assets already installed")
            }
            self.asrAssetsInstalled = true
        } catch {
            logger.warning("ASR preload failed (non-fatal): \(error.localizedDescription)")
            // Continue to diarization even if ASR fails
        }

        // --- Diarization models (mode-dependent) ---
        do {
            state = .downloading(description: "Downloading diarization models...", fractionComplete: nil)
            try await preloadDiarization()
        } catch {
            logger.error("Diarization preload failed: \(error.localizedDescription)")
            state = .failed("Failed to download diarization models: \(error.localizedDescription)")
            return
        }

        state = .ready
        logger.info("Model preload complete (ASR: \(self.asrAssetsInstalled), Mode: \(self.preloadedMode?.rawValue ?? "none"))")
    }

    /// Download diarization models for the currently selected mode.
    private func preloadDiarization() async throws {
        let mode = Self.selectedDiarizationMode

        switch mode {
        case .sortformer:
            let config = SortformerConfig.default
            let models = try await SortformerModels.loadFromHuggingFace(config: config)
            self.sortformerModels = models
            logger.info("Sortformer models loaded")

            // Also preload DiarizerModels (Pyannote + WeSpeaker) when enrolled
            // voices exist, so the Sortformer hybrid Voice ID embedding extractor
            // doesn't have to compile them at recording start.
            if VoiceID.shared.hasEnrolledVoices {
                let diarModels = try await DiarizerModels.downloadIfNeeded()
                self.diarizerModels = diarModels
                logger.info("DiarizerModels also preloaded for Sortformer Voice ID")
            }

        case .pyannoteStreaming:
            let models = try await DiarizerModels.downloadIfNeeded()
            self.diarizerModels = models
            logger.info("Pyannote diarizer models loaded")
        }

        self.preloadedMode = mode
    }

    // MARK: - Cleanup

    /// Release cached models (e.g. on memory warning or app backgrounding).
    public func releaseCachedModels() {
        sortformerModels = nil
        diarizerModels = nil
        preloadedMode = nil
        asrAssetsInstalled = false
        asrLocale = nil
        state = .idle
    }
}
