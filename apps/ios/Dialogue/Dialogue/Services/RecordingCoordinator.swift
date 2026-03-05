import AVFoundation
import Combine
import DialogueCore
import Foundation
import OSLog
import ReplayKit

/// Coordinates ReplayKit broadcast recording with DialogueCore's post-recording
/// refinement pipeline.
///
/// The BroadcastUpload extension writes proper 16kHz mono WAV files directly
/// using AVAssetWriter. This coordinator just moves them into MeetingStore
/// and runs the refiner.
@MainActor
final class RecordingCoordinator: ObservableObject {
    static let shared = RecordingCoordinator()

    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var statusMessage = "Ready"
    @Published var lastSavedMeeting: SavedMeeting?

    private let logger = Logger(subsystem: "bot.djinn.ios.dialogue", category: "RecordingCoordinator")
    private nonisolated(unsafe) let refiner = PostRecordingRefiner()

    static let appGroupID = "group.bot.djinn.dialogue"

    var sharedAudioDir: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)?
            .appendingPathComponent("AudioChunks", isDirectory: true)
    }

    var broadcastActiveFile: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)?
            .appendingPathComponent("broadcast_active")
    }

    var recordingPendingFile: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID)?
            .appendingPathComponent("recording_pending")
    }

    private var pollTimer: Timer?
    private var durationTimer: Timer?
    private var recordingStartTime: Date?

    private init() {
        if let dir = sharedAudioDir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        guard pollTimer == nil else { return }
        logger.info("Starting broadcast monitor")

        // Check for recordings that completed while app was backgrounded
        checkForPendingRecording()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkBroadcastState()
            }
        }
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        durationTimer?.invalidate()
        durationTimer = nil
    }

    func stopBroadcast() {
        logger.info("User requested broadcast stop")

        if let activeFile = broadcastActiveFile {
            try? FileManager.default.removeItem(at: activeFile)
        }

        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroupID) {
            let stopFile = container.appendingPathComponent("broadcast_stop_request")
            FileManager.default.createFile(atPath: stopFile.path, contents: Data())
        }
    }

    private func checkForPendingRecording() {
        guard let pendingFile = recordingPendingFile,
              FileManager.default.fileExists(atPath: pendingFile.path) else { return }

        let broadcastStillActive = broadcastActiveFile.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false

        if broadcastStillActive {
            logger.info("Found active broadcast on foreground")
            isRecording = true
            recordingStartTime = Date()
            statusMessage = "Recording..."
        } else {
            logger.info("Found pending recording from backgrounded session")
            Task {
                await processRecording()
            }
        }
    }

    private func checkBroadcastState() {
        guard let activeFile = broadcastActiveFile else { return }
        let isActive = FileManager.default.fileExists(atPath: activeFile.path)

        if isActive && !isRecording {
            isRecording = true
            recordingStartTime = Date()
            statusMessage = "Recording..."
            logger.info("Broadcast started")

            durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let start = self.recordingStartTime else { return }
                    self.recordingDuration = Date().timeIntervalSince(start)
                }
            }

        } else if !isActive && isRecording {
            isRecording = false
            durationTimer?.invalidate()
            durationTimer = nil
            logger.info("Broadcast stopped")

            Task {
                await processRecording()
            }
        }
    }

    // MARK: - Process Recording

    private func processRecording() async {
        statusMessage = "Saving meeting..."
        logger.info("Processing recording...")

        guard let dir = sharedAudioDir else {
            statusMessage = "Error: no shared container"
            logger.error("No shared container URL")
            removePendingMarker()
            return
        }

        let fm = FileManager.default

        // The extension writes proper WAV files directly — just find them
        let micWAV = dir.appendingPathComponent("mic_audio.wav")
        let appWAV = dir.appendingPathComponent("app_audio.wav")

        let micSize = fileSize(micWAV)
        let appSize = fileSize(appWAV)
        logger.info("WAV file sizes — mic: \(micSize) bytes, app: \(appSize) bytes")

        // Move to temp dir with the names MeetingStore expects
        let tempDir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var localWAV: URL?
        var remoteWAV: URL?
        var mixedWAV: URL?

        // Minimum size: WAV header is 44 bytes, need at least some audio data
        let minSize = 1000

        if fm.fileExists(atPath: micWAV.path) && micSize > minSize {
            let dest = tempDir.appendingPathComponent("local.wav")
            try? fm.copyItem(at: micWAV, to: dest)
            localWAV = dest
            logger.info("Mic WAV ready: \(micSize) bytes")
        }

        if fm.fileExists(atPath: appWAV.path) && appSize > minSize {
            let dest = tempDir.appendingPathComponent("remote.wav")
            try? fm.copyItem(at: appWAV, to: dest)
            remoteWAV = dest
            logger.info("App WAV ready: \(appSize) bytes")
        }

        // Mixed recording = whichever stream we have (prefer mic)
        if let local = localWAV {
            let dest = tempDir.appendingPathComponent("recording.wav")
            try? fm.copyItem(at: local, to: dest)
            mixedWAV = dest
        } else if let remote = remoteWAV {
            let dest = tempDir.appendingPathComponent("recording.wav")
            try? fm.copyItem(at: remote, to: dest)
            mixedWAV = dest
        }

        guard localWAV != nil || remoteWAV != nil else {
            statusMessage = "No audio captured"
            logger.error("No valid WAV files found in shared container")
            cleanupSharedAudio()
            removePendingMarker()
            try? fm.removeItem(at: tempDir)
            return
        }

        // Save to MeetingStore (moves files into meeting folder)
        let meeting = MeetingStore.shared.saveMeeting(
            wavSourceURL: mixedWAV,
            localWavSourceURL: localWAV,
            remoteWavSourceURL: remoteWAV,
            segments: []
        )

        cleanupSharedAudio()
        try? fm.removeItem(at: tempDir)

        guard let meeting else {
            statusMessage = "Failed to save meeting"
            logger.error("MeetingStore.saveMeeting returned nil")
            removePendingMarker()
            return
        }

        lastSavedMeeting = meeting
        recordingDuration = 0

        // Verify files in meeting folder
        let localExists = fm.fileExists(atPath: meeting.folderURL.appendingPathComponent("local.wav").path)
        let remoteExists = fm.fileExists(atPath: meeting.folderURL.appendingPathComponent("remote.wav").path)
        logger.info("Meeting saved: \(meeting.id) — local.wav: \(localExists), remote.wav: \(remoteExists)")

        // Run refinement
        statusMessage = "Refining transcript..."
        await runRefinement(for: meeting)
        removePendingMarker()
    }

    private func fileSize(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    // MARK: - Refinement

    private func runRefinement(for meeting: SavedMeeting) async {
        let localWAV = meeting.folderURL.appendingPathComponent("local.wav")
        let remoteWAV = meeting.folderURL.appendingPathComponent("remote.wav")
        let fm = FileManager.default

        let localURL: URL? = fm.fileExists(atPath: localWAV.path) ? localWAV : nil
        let remoteURL: URL? = fm.fileExists(atPath: remoteWAV.path) ? remoteWAV : nil

        do {
            let segments = try await refiner.refine(
                localWavURL: localURL,
                remoteWavURL: remoteURL,
                liveSegments: []
            )

            if !segments.isEmpty {
                MeetingStore.shared.updateTranscript(for: meeting, segments: segments)
                statusMessage = "Transcript ready (\(segments.count) segments)"
                logger.info("Refinement complete: \(segments.count) segments")
            } else {
                statusMessage = "No speech detected"
                logger.info("Refinement produced no segments")
            }

            await refiner.convertWAVsToOpus(in: meeting.folderURL)
            await RefinementProgress.shared.state = .idle
            MeetingStore.shared.refresh()

        } catch {
            statusMessage = "Refinement failed: \(error.localizedDescription)"
            logger.error("Refinement error: \(error)")
            await RefinementProgress.shared.state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Cleanup

    private func cleanupSharedAudio() {
        guard let dir = sharedAudioDir else { return }
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for file in files {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func removePendingMarker() {
        if let pendingFile = recordingPendingFile {
            try? FileManager.default.removeItem(at: pendingFile)
        }
    }

    // MARK: - Duration Formatting

    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
