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
/// ## Speaker Profiles
///
/// After each recording, speakers with sufficient speech (> 8 seconds)
/// are saved to `SpeakerProfileStore` for cross-session recognition.
/// On the next recording, known profiles are loaded into the
/// `SpeakerManager` (Pyannote) or used for merge-time matching.
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
    /// 2. Loads cached speaker profiles for merge-time matching
    /// 3. Starts mic + per-app audio capture with selected diarization mode
    /// 4. Begins ASR + diarization on both streams
    /// 5. Starts mixed WAV recording
    func start() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        errorMessage = nil

        do {
            // Detect meeting apps
            let meetingApps = await MeetingAppDetector.shared.runningMeetingApplications()
            let appNames = meetingApps.map(\.applicationName)
            detectedMeetingApps = appNames.isEmpty ? "None (mic only)" : appNames.joined(separator: ", ")

            logger.info("Starting recording. Detected apps: \(self.detectedMeetingApps), mode: \(self.diarizationMode.rawValue)")

            // Reset merge engine for fresh recording
            mergeEngine.reset()

            // Load cached speaker profiles for merge-time matching
            await loadCachedProfilesForMergeEngine()

            // Start dual audio capture with the selected diarization mode
            try await dualEngine.start(
                micEnabled: true,
                meetingEnabled: !meetingApps.isEmpty,
                diarizationMode: diarizationMode
            )

            // Bind merge engine output to our published property
            mergeEngine.$mergedSegments
                .receive(on: RunLoop.main)
                .assign(to: &$mergedSegments)

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
            logger.info("Recording started")

        } catch {
            isStarting = false
            logger.error("Failed to start recording: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Stop Recording

    /// Stop recording and return metadata about the session.
    ///
    /// Saves the recording WAV and transcript JSON to
    /// ~/Documents/Dialog/Meetings/{timestamp}/ and refreshes
    /// the MeetingStore so the sidebar updates immediately.
    ///
    /// After stopping, extracts speaker embeddings from long-duration
    /// speakers and saves them as persistent profiles for future
    /// cross-session recognition.
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

        // Extract speakers BEFORE stopping (stop releases the pipelines)
        let extractedSpeakers = await dualEngine.extractAllSpeakers()

        // Stop audio capture
        let wavURL = await dualEngine.stop()

        // Build metadata
        let startDate = recordingStartDate ?? Date()
        let uniqueSpeakers = Set(mergedSegments.map(\.speaker))
        let metadata = RecordingMetadata(
            startDate: startDate,
            durationSeconds: recordingDuration,
            wavFileURL: wavURL,
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

        // Save to ~/Documents/Dialog/Meetings/
        let segments = mergedSegments
        let saved = MeetingStore.shared.saveMeeting(
            name: nil,
            wavSourceURL: wavURL,
            segments: segments
        )
        if let saved {
            logger.info("Meeting saved to \(saved.folderURL.lastPathComponent)")
        } else {
            logger.warning("Failed to save meeting to Meetings directory")
        }

        // Save speaker profiles for cross-session recognition
        await saveSpeakerProfiles(extractedSpeakers: extractedSpeakers)

        recordingStartDate = nil
        logger.info("Recording stopped. Duration: \(String(format: "%.1f", self.recordingDuration))s, Speakers: \(uniqueSpeakers.count)")

        return metadata
    }

    // MARK: - Speaker Profile Management

    /// Load cached speaker profiles from the store and inject them into
    /// the `MergeEngine` for synchronous matching during recording.
    private func loadCachedProfilesForMergeEngine() async {
        guard let store = SpeakerProfileStore.shared else {
            logger.info("No SpeakerProfileStore available; skipping profile cache")
            return
        }

        do {
            let cached = try await store.loadCachedProfiles()
            mergeEngine.setCachedProfiles(cached)
            logger.info("Loaded \(cached.count) cached profiles for merge-time matching")
        } catch {
            logger.warning("Failed to load cached profiles: \(error.localizedDescription)")
        }
    }

    /// Save speaker profiles from the completed recording.
    ///
    /// For Pyannote mode, uses the `ExtractedSpeaker` data from the
    /// `SpeakerManager` (high-quality running-average embeddings).
    ///
    /// As a fallback (or for speakers not in the extracted set), scans
    /// the final merged segments for speakers with embeddings and
    /// sufficient duration (> 8 seconds).
    private func saveSpeakerProfiles(extractedSpeakers: [ExtractedSpeaker]) async {
        guard let store = SpeakerProfileStore.shared else { return }

        // 1. Save extracted speakers from SpeakerManager (Pyannote mode)
        let minDurationForProfile: Float = 8.0
        var savedIds = Set<String>()

        for speaker in extractedSpeakers where speaker.duration >= minDurationForProfile {
            do {
                try await store.saveOrUpdateProfile(
                    speakerId: speaker.id,
                    displayName: speaker.name,
                    embedding: speaker.embedding
                )
                savedIds.insert(speaker.id)
                logger.info("Saved profile for '\(speaker.name)' (\(String(format: "%.1f", speaker.duration))s)")
            } catch {
                logger.warning("Failed to save profile for '\(speaker.name)': \(error.localizedDescription)")
            }
        }

        // 2. Fallback: scan merged segments for speakers with embeddings
        //    that weren't already saved (e.g. from merge-engine rename resolution)
        let segmentsBySpeaker = Dictionary(grouping: mergedSegments.filter { !$0.embedding.isEmpty }) { $0.speaker }
        for (speakerName, segments) in segmentsBySpeaker {
            // Skip if already saved via extracted speakers
            guard !savedIds.contains(speakerName) else { continue }

            let totalDuration = segments.reduce(0.0) { $0 + $1.duration }
            guard totalDuration >= Double(minDurationForProfile) else { continue }

            // Average all embeddings for this speaker
            guard let avgEmbedding = Self.averageEmbeddings(segments.map(\.embedding)) else { continue }

            do {
                try await store.saveOrUpdateProfile(
                    speakerId: speakerName,
                    displayName: speakerName,
                    embedding: avgEmbedding
                )
                logger.info("Saved fallback profile for '\(speakerName)' (\(String(format: "%.1f", totalDuration))s)")
            } catch {
                logger.warning("Failed to save fallback profile for '\(speakerName)': \(error.localizedDescription)")
            }
        }
    }

    /// Average multiple embedding vectors.
    private static func averageEmbeddings(_ embeddings: [[Float]]) -> [Float]? {
        let nonEmpty = embeddings.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        let dim = nonEmpty[0].count
        var avg = [Float](repeating: 0, count: dim)
        for emb in nonEmpty {
            guard emb.count == dim else { continue }
            for i in 0..<dim {
                avg[i] += emb[i]
            }
        }
        let n = Float(nonEmpty.count)
        return avg.map { $0 / n }
    }

    // MARK: - Helpers

    /// Formatted duration string for display (MM:SS).
    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
