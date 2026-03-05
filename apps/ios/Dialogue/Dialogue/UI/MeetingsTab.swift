import DialogueCore
import SwiftUI

/// Lists saved meetings from MeetingStore and allows basic interaction.
struct MeetingsTab: View {
    @EnvironmentObject var meetingStore: MeetingStore
    @StateObject private var refinementProgress = RefinementProgress.shared

    var body: some View {
        NavigationStack {
            Group {
                if meetingStore.meetings.isEmpty {
                    ContentUnavailableView(
                        "No Meetings",
                        systemImage: "waveform",
                        description: Text("Recorded meetings will appear here.")
                    )
                } else {
                    List {
                        // Show refinement progress at top if active
                        if refinementProgress.isActive {
                            Section {
                                RefinementProgressRow(progress: refinementProgress)
                            }
                        }

                        Section {
                            ForEach(meetingStore.meetings) { meeting in
                                NavigationLink(value: meeting) {
                                    MeetingRow(meeting: meeting)
                                }
                            }
                            .onDelete { offsets in
                                for index in offsets {
                                    meetingStore.deleteMeeting(meetingStore.meetings[index])
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Meetings")
            .navigationDestination(for: SavedMeeting.self) { meeting in
                MeetingDetailView(meeting: meeting)
            }
            .refreshable {
                meetingStore.refresh()
            }
        }
    }
}

// MARK: - Refinement Progress Row

struct RefinementProgressRow: View {
    @ObservedObject var progress: RefinementProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Refining...")
                    .font(.subheadline.bold())
            }
            Text(progress.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let fraction = progress.fraction {
                ProgressView(value: fraction)
                    .tint(.blue)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Meeting Row

struct MeetingRow: View {
    let meeting: SavedMeeting

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meeting.displayName)
                .font(.headline)
            HStack(spacing: 12) {
                if meeting.hasRecording {
                    Label("Audio", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if meeting.hasTranscript {
                    Label("Transcript", systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
                Text(meeting.date, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Meeting Detail

struct MeetingDetailView: View {
    let meeting: SavedMeeting
    @State private var transcript: [TranscriptEntry]?
    @State private var isRefining = false
    @State private var refineError: String?
    @StateObject private var refinementProgress = RefinementProgress.shared

    var body: some View {
        List {
            Section("Info") {
                LabeledContent("Name", value: meeting.displayName)
                LabeledContent("Date", value: meeting.date.formatted())
                LabeledContent("Audio", value: meeting.hasRecording ? "Yes" : "No")
                LabeledContent("Transcript", value: meeting.hasTranscript ? "\(transcript?.count ?? 0) segments" : "None")
            }

            if refinementProgress.isActive {
                Section("Refinement") {
                    RefinementProgressRow(progress: refinementProgress)
                }
            }

            if let error = refineError {
                Section {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let transcript, !transcript.isEmpty {
                Section("Transcript") {
                    ForEach(transcript) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.speaker)
                                    .font(.caption.bold())
                                    .foregroundStyle(.tint)
                                Spacer()
                                Text(formatTime(entry.start))
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(entry.text)
                                .font(.body)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
                    }
                }
            } else if !meeting.hasTranscript && !refinementProgress.isActive {
                Section {
                    Button("Run Transcription") {
                        Task { await runRefinement() }
                    }
                    .disabled(isRefining)
                }
            }
        }
        .navigationTitle(meeting.displayName)
        .onAppear { loadTranscript() }
        .onChange(of: refinementProgress.state) {
            // Reload transcript when refinement completes
            if case .complete = refinementProgress.state {
                loadTranscript()
            }
        }
        .toolbar {
            if meeting.hasTranscript {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await runRefinement() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(refinementProgress.isActive)
                }
            }
        }
    }

    private func loadTranscript() {
        transcript = MeetingStore.shared.loadTranscript(for: meeting)
    }

    private func runRefinement() async {
        isRefining = true
        refineError = nil

        let localWAV = meeting.folderURL.appendingPathComponent("local.wav")
        let remoteWAV = meeting.folderURL.appendingPathComponent("remote.wav")
        let fm = FileManager.default

        let localURL: URL? = fm.fileExists(atPath: localWAV.path) ? localWAV : nil
        let remoteURL: URL? = fm.fileExists(atPath: remoteWAV.path) ? remoteWAV : nil

        guard localURL != nil || remoteURL != nil else {
            refineError = "No WAV audio files found for refinement."
            isRefining = false
            return
        }

        let refiner = PostRecordingRefiner()

        do {
            let segments = try await refiner.refine(
                localWavURL: localURL,
                remoteWavURL: remoteURL,
                liveSegments: []
            )

            if !segments.isEmpty {
                MeetingStore.shared.updateTranscript(for: meeting, segments: segments)
            }

            loadTranscript()
            await RefinementProgress.shared.state = .idle
        } catch {
            refineError = error.localizedDescription
            await RefinementProgress.shared.state = .failed(error.localizedDescription)
        }

        isRefining = false
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
