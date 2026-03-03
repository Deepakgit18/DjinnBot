import Combine
import Foundation
import OSLog
import SFBAudioEngine

/// Observable wrapper around SFBAudioEngine's `AudioPlayer` for meeting playback.
///
/// Provides:
/// - Play / pause / stop controls
/// - Seek to arbitrary time
/// - Current time / total time for seek bar
/// - Segment-bounded playback (play only a specific segment, then stop)
///
/// The player uses a Timer to poll the underlying `AudioPlayer` for position
/// updates — SFBAudioEngine's delegate callbacks arrive on unspecified queues
/// and don't provide continuous position updates suitable for a seek bar.
@MainActor
final class MeetingPlayer: NSObject, ObservableObject {

    // MARK: - Published State

    @Published private(set) var isPlaying = false
    @Published private(set) var isPaused = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var totalTime: TimeInterval = 0

    // MARK: - Private

    private let player = AudioPlayer()
    private var pollTimer: Timer?
    private let logger = Logger(subsystem: "bot.djinn.app.dialog", category: "MeetingPlayer")

    /// When non-nil, playback auto-stops at this time (segment-bounded playback).
    private var segmentEndTime: TimeInterval?

    /// The URL currently loaded (to avoid re-loading the same file).
    private var loadedURL: URL?

    // MARK: - Init

    override init() {
        super.init()
        player.delegate = self
    }

    deinit {
        pollTimer?.invalidate()
        player.stop()
    }

    // MARK: - Transport

    /// Play an audio file from the beginning (or resume if paused on the same file).
    func play(url: URL) {
        segmentEndTime = nil
        if loadedURL == url && isPaused {
            _ = player.resume()
            isPlaying = true
            isPaused = false
            startPolling()
            return
        }
        do {
            try player.play(url)
            loadedURL = url
            isPlaying = true
            isPaused = false
            startPolling()
        } catch {
            logger.error("Playback failed: \(error.localizedDescription)")
        }
    }

    /// Toggle between play and pause.
    func togglePlayPause(url: URL) {
        if isPlaying {
            pause()
        } else {
            play(url: url)
        }
    }

    /// Pause playback.
    func pause() {
        _ = player.pause()
        isPlaying = false
        isPaused = true
        stopPolling()
    }

    /// Stop playback and reset position.
    func stop() {
        player.stop()
        isPlaying = false
        isPaused = false
        segmentEndTime = nil
        currentTime = 0
        stopPolling()
    }

    /// Seek to a specific time in seconds.
    func seek(to time: TimeInterval) {
        _ = player.seek(time: time)
        currentTime = time
    }

    /// Play from `startTime`, stopping automatically at `endTime`.
    func playSegment(url: URL, from startTime: TimeInterval, to endTime: TimeInterval) {
        segmentEndTime = endTime
        if loadedURL == url && (isPlaying || isPaused) {
            // Same file already loaded — just seek to the new position.
            // Re-opening the file would reset to position 0 and race with
            // the seek, causing the playback to jump to the beginning.
            _ = player.seek(time: startTime)
            if isPaused { _ = player.resume() }
            isPlaying = true
            isPaused = false
            currentTime = startTime
            startPolling()
        } else {
            do {
                try player.play(url)
                loadedURL = url
                _ = player.seek(time: startTime)
                isPlaying = true
                isPaused = false
                currentTime = startTime
                startPolling()
            } catch {
                logger.error("Segment playback failed: \(error.localizedDescription)")
            }
        }
    }

    /// Seek to `startTime` and play from there (no end bound).
    func playFrom(url: URL, time startTime: TimeInterval) {
        segmentEndTime = nil
        if loadedURL == url && (isPlaying || isPaused) {
            // Same file — seek in place without re-opening.
            _ = player.seek(time: startTime)
            if isPaused { _ = player.resume() }
            isPlaying = true
            isPaused = false
            currentTime = startTime
            startPolling()
        } else {
            do {
                try player.play(url)
                loadedURL = url
                _ = player.seek(time: startTime)
                isPlaying = true
                isPaused = false
                currentTime = startTime
                startPolling()
            } catch {
                logger.error("Play-from failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollPosition()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollPosition() {
        if let t = player.currentTime {
            currentTime = t
        }
        if let t = player.totalTime, t > 0 {
            totalTime = t
        }

        // Segment-bounded playback: stop when we reach the end time
        if let endTime = segmentEndTime, currentTime >= endTime {
            stop()
        }
    }
}

// MARK: - AudioPlayer.Delegate

extension MeetingPlayer: AudioPlayer.Delegate {
    nonisolated func audioPlayer(_ audioPlayer: AudioPlayer, playbackStateChanged playbackState: AudioPlayer.PlaybackState) {
        Task { @MainActor in
            switch playbackState {
            case .playing:
                isPlaying = true
                isPaused = false
            case .paused:
                isPlaying = false
                isPaused = true
                stopPolling()
            case .stopped:
                isPlaying = false
                isPaused = false
                segmentEndTime = nil
                stopPolling()
            @unknown default:
                break
            }
        }
    }

    nonisolated func audioPlayerRenderingComplete(_ audioPlayer: AudioPlayer) {
        Task { @MainActor in
            isPlaying = false
            isPaused = false
            segmentEndTime = nil
            currentTime = 0
            stopPolling()
        }
    }
}
