import SwiftUI
import AppKit

/// Displays the transcript of a saved meeting with integrated audio playback.
///
/// Shows the meeting name, date, transport controls (play/pause/stop + seek bar),
/// and a scrollable list of transcript entries with speaker labels, timestamps,
/// and per-segment playback buttons.
struct MeetingDetailView: View {
    let meeting: SavedMeeting
    @State private var entries: [TranscriptEntry] = []
    @State private var loadError: String?
    @StateObject private var player = MeetingPlayer()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header
            Divider()

            // Transport controls
            if meeting.hasRecording {
                transportBar
                Divider()
            }

            // Transcript content
            if let error = loadError {
                errorView(error)
            } else if entries.isEmpty {
                emptyView
            } else {
                transcriptList
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadTranscript() }
        .onDisappear { player.stop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.displayName)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(meeting.date, style: .date)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.folderURL])
            } label: {
                Label("Show in Finder", systemImage: "folder")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Transport Controls

    private var transportBar: some View {
        VStack(spacing: 6) {
            // Seek bar
            HStack(spacing: 8) {
                Text(formatTime(player.currentTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { player.currentTime },
                        set: { player.seek(to: $0) }
                    ),
                    in: 0...max(player.totalTime, 1)
                )

                Text(formatTime(player.totalTime))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)
            }

            // Buttons
            HStack(spacing: 16) {
                // Play / Pause
                Button {
                    player.togglePlayPause(url: meeting.recordingURL)
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.space, modifiers: [])

                // Stop
                Button {
                    player.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!player.isPlaying && !player.isPaused)

                // Skip backward 10s
                Button {
                    let target = max(0, player.currentTime - 10)
                    player.seek(to: target)
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.callout)
                }
                .buttonStyle(.borderless)

                // Skip forward 10s
                Button {
                    let target = min(player.totalTime, player.currentTime + 10)
                    player.seek(to: target)
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Transcript List

    private var transcriptList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    MeetingTranscriptRow(
                        entry: entry,
                        player: player,
                        recordingURL: meeting.recordingURL,
                        hasRecording: meeting.hasRecording
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Empty / Error states

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("No Transcript")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text("This meeting does not have a transcript file.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text("Failed to Load Transcript")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Loading

    private func loadTranscript() {
        guard meeting.hasTranscript else {
            entries = []
            return
        }
        if let loaded = MeetingStore.shared.loadTranscript(for: meeting) {
            entries = loaded
        } else {
            loadError = "Could not read transcript.json"
        }
    }

    // MARK: - Formatting

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Single Transcript Row

private struct MeetingTranscriptRow: View {
    let entry: TranscriptEntry
    @ObservedObject var player: MeetingPlayer
    let recordingURL: URL
    let hasRecording: Bool

    /// True when this segment is currently being played (segment-bounded).
    private var isActiveSegment: Bool {
        player.isPlaying &&
        player.currentTime >= entry.start &&
        player.currentTime <= entry.end
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // Per-segment playback buttons
            if hasRecording {
                segmentButtons
            }

            // Timestamp
            Text(formatTimestamp(entry.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)

            // Speaker name
            Text(entry.speaker)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(CatppuccinSpeaker.labelColor(for: entry.speaker))

            // Text
            Text(entry.text)
                .font(.body)
                .foregroundStyle(.primary)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(CatppuccinSpeaker.color(for: entry.speaker)
                    .opacity(isActiveSegment ? 0.15 : CatppuccinSpeaker.rowBackgroundOpacity))
        )
    }

    private var segmentButtons: some View {
        HStack(spacing: 2) {
            // Play from here (continuous)
            Button {
                player.playFrom(url: recordingURL, time: entry.start)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Play from here")

            // Play this segment only
            Button {
                player.playSegment(url: recordingURL, from: entry.start, to: entry.end)
            } label: {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Play this segment only")
        }
        .frame(width: 32, alignment: .center)
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
