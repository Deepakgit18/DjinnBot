import Combine
import Foundation
import OSLog
import SwiftUI

/// Top-level controller for the MeetingRecorder module.
///
/// Coordinates all sub-systems:
/// - `MeetingAppDetector` — discovers running Zoom/Teams/Chrome/etc.
/// - `DualAudioEngine` — captures mic + per-app meeting audio
/// - `MergeEngine` — merges ASR + diarization into a single transcript
///
/// ## Diarization Mode
///
/// The `diarizationMode` property (backed by `@AppStorage`) selects
/// between Sortformer and Pyannote diarization backends. Changing the
/// mode triggers a model re-preload so the next recording uses the
/// correct models instantly.
///
/// ## Speaker Identification
///
/// Speaker identification is fully handled by `VoiceID`. The merge engine
/// calls `VoiceID.identifySpeaker(fromEmbedding:)` during recording to
/// resolve auto-generated speaker labels to enrolled user IDs. No profile
/// loading or saving is done here — VoiceID manages its own persistence.
///
/// Bind to this object from your SwiftUI view to display recording state
/// and the live interleaved transcript.
@available(macOS 26.0, *)
@MainActor
final class MeetingRecorderController: ObservableObject {

    // MARK: - Published State

    @Published var isRecording = false
    @Published var mergedSegments: [TaggedSegment] = []
    @Published var detectedMeetingApps: String = "None"
    @Published var recordingDuration: TimeInterval = 0
    @Published var errorMessage: String?

    /// Guards against duplicate start calls while awaiting pipeline setup.
    @Published var isStarting = false

    /// Human-readable status message shown in the footer during startup.
    @Published var preparationStatus: String?

    // MARK: - Settings

    /// Selects the diarization backend: Sortformer (fast, max 4 speakers)
    /// or Pyannote Streaming (higher accuracy, 6+ speakers, cross-session memory).
    ///
    /// Changing this triggers a model re-preload via `ModelPreloader`.
    @AppStorage("diarizationMode") var diarizationMode: DiarizationMode = .pyannoteStreaming {
        didSet {
            guard oldValue != diarizationMode else { return }
            logger.info("Diarization mode changed: \(oldValue.rawValue) → \(self.diarizationMode.rawValue)")
            ModelPreloader.shared.preloadIfModeChanged()
        }
    }

    // MARK: - Private

    private let dualEngine = DualAudioEngine()
    private let mergeEngine = MergeEngine.shared
    private var cancellables = Set<AnyCancellable>()
    private var durationTimer: Timer?
    private var recordingStartDate: Date?

    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "MeetingRecorder")

    // MARK: - Start Recording

    /// Start recording the meeting.
    ///
    /// 1. Detects running meeting apps
    /// 2. Starts mic + per-app audio capture with selected diarization mode
    /// 3. Begins ASR + diarization on both streams
    /// 4. Starts mixed WAV recording
    func start() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        preparationStatus = "Detecting meeting apps…"
        errorMessage = nil

        do {
            // Detect meeting apps
            let meetingApps = await MeetingAppDetector.shared.runningMeetingApplications()
            let appNames = meetingApps.map(\.applicationName)
            detectedMeetingApps = appNames.isEmpty ? "None (mic only)" : appNames.joined(separator: ", ")

            logger.info("Starting recording. Detected apps: \(self.detectedMeetingApps), mode: \(self.diarizationMode.rawValue)")

            // Reset merge engine for fresh recording
            preparationStatus = "Preparing pipelines…"
            mergeEngine.reset()

            // Start dual audio capture with the selected diarization mode
            preparationStatus = "Starting audio capture…"
            try await dualEngine.start(
                micEnabled: true,
                meetingEnabled: !meetingApps.isEmpty,
                diarizationMode: diarizationMode
            )

            // Bind merge engine output to our published property
            mergeEngine.$mergedSegments
                .receive(on: RunLoop.main)
                .assign(to: &$mergedSegments)

            // Start periodic refinement (speaker merging, re-attribution, enrolled voice matching)
            mergeEngine.startRefinementTimer()

            // Start duration timer
            recordingStartDate = Date()
            durationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordingStartDate else { return }
                    self.recordingDuration = Date().timeIntervalSince(start)
                }
            }

            isRecording = true
            isStarting = false
            preparationStatus = nil
            logger.info("Recording started")

        } catch {
            isStarting = false
            preparationStatus = nil
            logger.error("Failed to start recording: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Stop Recording

    /// Stop recording and return metadata about the session.
    ///
    /// Saves the recording WAV and transcript JSON to
    /// {dialogueFolder}/Meetings/{timestamp}/ and refreshes
    /// the MeetingStore so the sidebar updates immediately.
    ///
    /// Returns the WAV file URL and recording metadata, or nil if
    /// recording was not active.
    @discardableResult
    func stop() async -> RecordingMetadata? {
        guard isRecording else { return nil }
        // Set immediately to prevent re-entrant calls while async work runs
        isRecording = false

        logger.info("Stopping recording")

        // Stop duration timer
        durationTimer?.invalidate()
        durationTimer = nil

        // Stop the merge timer BEFORE pipeline teardown to prevent the 30s
        // timeout from committing segments as Speaker-? while diarization
        // is still catching up. The final flush will handle all remaining entries.
        mergeEngine.stopTimers()

        // Stop audio capture. This forces ASR to emit all final segments
        // via `finalizeAndFinishThroughEndOfInput()` before pipelines are torn down.
        let recordingURLs = await dualEngine.stop()

        // Small delay to let final ASR segments propagate.
        try? await Task.sleep(for: .milliseconds(500))

        // NOW flush — all ASR finals have been emitted and processed.
        mergeEngine.flushUnattributed()

        // Build metadata
        let startDate = recordingStartDate ?? Date()
        let uniqueSpeakers = Set(mergedSegments.map(\.speaker))
        let metadata = RecordingMetadata(
            startDate: startDate,
            durationSeconds: recordingDuration,
            wavFileURL: recordingURLs.mixed,
            detectedApps: detectedMeetingApps.components(separatedBy: ", "),
            speakerCount: uniqueSpeakers.count,
            segmentCount: mergedSegments.count
        )

        // Save metadata sidecar
        do {
            try metadata.writeSidecar()
            logger.info("Recording metadata saved")
        } catch {
            logger.warning("Failed to save metadata: \(error.localizedDescription)")
        }

        // Save to {dialogueFolder}/Meetings/
        let segments = mergedSegments
        let saved = MeetingStore.shared.saveMeeting(
            name: nil,
            wavSourceURL: recordingURLs.mixed,
            localWavSourceURL: recordingURLs.local,
            remoteWavSourceURL: recordingURLs.remote,
            segments: segments
        )
        if let saved {
            logger.info("Meeting saved to \(saved.folderURL.lastPathComponent)")

            // Run post-recording refinement on per-stream WAVs.
            // This produces ground-truth speaker profiles from full audio
            // and re-attributes segments that were wrong or unresolved during live recording.
            Task {
                await self.runPostRecordingRefinement(meeting: saved)
            }
        } else {
            logger.warning("Failed to save meeting to Meetings directory")
        }

        recordingStartDate = nil
        logger.info("Recording stopped. Duration: \(String(format: "%.1f", self.recordingDuration))s, Speakers: \(uniqueSpeakers.count)")

        return metadata
    }

    // MARK: - Post-Recording Refinement

    /// Run offline VBx diarization on per-stream WAVs and re-attribute the transcript.
    ///
    /// This runs asynchronously after the meeting is saved. The user sees the live
    /// transcript immediately; it gets refined in the background with higher accuracy.
    private func runPostRecordingRefinement(meeting: SavedMeeting) async {
        // WAV files are still on disk at this point — SavedMeeting URLs point to
        // .opus which don't exist yet. Reference the WAVs directly by name.
        let folder = meeting.folderURL
        let localWavURL = folder.appendingPathComponent("local.wav")
        let remoteWavURL = folder.appendingPathComponent("remote.wav")
        let fm = FileManager.default

        let hasLocal = fm.fileExists(atPath: localWavURL.path)
        let hasRemote = fm.fileExists(atPath: remoteWavURL.path)

        guard hasLocal || hasRemote else {
            logger.info("No per-stream WAVs found; skipping post-recording refinement")
            return
        }

        logger.info("Starting post-recording refinement for \(folder.lastPathComponent)")

        let refiner = PostRecordingRefiner()
        var refinedCount = 0
        var originalCount = 0

        do {
            let refined = try await refiner.refine(
                localWavURL: hasLocal ? localWavURL : nil,
                remoteWavURL: hasRemote ? remoteWavURL : nil,
                liveSegments: mergedSegments
            )

            refinedCount = refined.count
            originalCount = mergedSegments.filter { $0.isFinal && $0.hasSubstantialContent }.count

            // Update the live display
            mergedSegments = refined

            // Overwrite the saved transcript with the refined version
            MeetingStore.shared.updateTranscript(for: meeting, segments: refined)

            logger.info("Post-recording refinement complete for \(folder.lastPathComponent)")
        } catch {
            logger.warning("Post-recording refinement failed: \(error.localizedDescription)")
            RefinementProgress.shared.state = .failed(error.localizedDescription)

            // Auto-dismiss error after 10 seconds
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                if case .failed = RefinementProgress.shared.state {
                    RefinementProgress.shared.state = .idle
                }
            }
        }

        // Convert WAV files to Opus for long-term storage regardless of whether
        // refinement succeeded or failed — the WAVs are no longer needed.
        await refiner.convertWAVsToOpus(in: folder)

        // Refresh the meeting list so it picks up the new .opus files
        MeetingStore.shared.refresh()

        // Show completion and auto-dismiss
        RefinementProgress.shared.state = .complete(segments: refinedCount, original: originalCount)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            if case .complete = RefinementProgress.shared.state {
                RefinementProgress.shared.state = .idle
            }
        }
    }

    // MARK: - Helpers

    /// Formatted duration string for display (MM:SS).
    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
