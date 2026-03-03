import AVFoundation
import SwiftUI
import AppKit
import SFBAudioEngine

/// Displays the transcript of a saved meeting with integrated audio playback.
///
/// Shows the meeting name, date, transport controls (play/pause/stop + seek bar),
/// and a scrollable list of transcript entries with speaker labels, timestamps,
/// per-segment playback buttons, and a context menu for voice enrollment,
/// speaker reassignment, and enrollment enhancement from segment audio.
struct MeetingDetailView: View {
    let meeting: SavedMeeting
    @State private var entries: [TranscriptEntry] = []
    @State private var loadError: String?
    @StateObject private var player = MeetingPlayer()

    /// Observe refinement progress so we can reload after opus conversion.
    @ObservedObject private var refinementProgress = RefinementProgress.shared

    /// Dynamic recording check — the `SavedMeeting` snapshot may be stale
    /// (created before post-refinement converted WAVs to opus).
    private var hasRecording: Bool {
        FileManager.default.fileExists(atPath: meeting.recordingURL.path)
    }

    // MARK: - Context Menu State

    /// The entry selected for enrollment / enhance operations.
    @State private var selectedEntry: TranscriptEntry?

    /// Enroll-from-segment sheet state.
    @State private var showEnrollSheet = false
    @State private var enrollName = ""
    @State private var enrollColorIndex: Int? = nil

    /// Processing overlay.
    @State private var isProcessing = false
    @State private var processingMessage = ""

    /// Error alert.
    @State private var showError = false
    @State private var errorMessage = ""

    /// Success toast.
    @State private var toastMessage: String?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                header
                Divider()

                // Transport controls — use dynamic file check, not stale snapshot
                if hasRecording {
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

            // Processing overlay
            if isProcessing {
                processingOverlay
            }

            // Toast
            if let toast = toastMessage {
                toastView(toast)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { loadTranscript() }
        .onDisappear { player.stop() }
        .onChange(of: refinementProgress.state) { _, newState in
            // Reload transcript + re-check recording after refinement finishes.
            if case .complete = newState {
                loadTranscript()
            }
        }
        .alert("Error", isPresented: $showError) {
            Button("OK") {}
        } message: {
            Text(errorMessage)
        }
        .sheet(isPresented: $showEnrollSheet) {
            enrollmentSheet
        }
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
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    MeetingTranscriptRow(
                        entry: entry,
                        player: player,
                        recordingURL: meeting.recordingURL,
                        hasRecording: hasRecording,
                        enrolledVoices: VoiceID.shared.allEnrolledVoices(),
                        onEnroll: { e in
                            selectedEntry = e
                            enrollName = ""
                            enrollColorIndex = nil
                            showEnrollSheet = true
                        },
                        onReassign: { e, userID in
                            reassignEntry(at: index, to: userID)
                        },
                        onEnhance: { e, userID in
                            Task { await enhanceVoice(entry: e, userID: userID) }
                        }
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Enrollment Sheet

    private var enrollmentSheet: some View {
        VStack(spacing: 16) {
            Text("Enroll New Speaker")
                .font(.headline)

            if let entry = selectedEntry {
                Text("From segment: \"\(entry.text.prefix(60))...\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            TextField("Speaker Name", text: $enrollName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 250)

            // Color picker grid
            VStack(alignment: .leading, spacing: 4) {
                Text("Speaker Color")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 7), spacing: 4) {
                    ForEach(0..<CatppuccinSpeaker.palette.count, id: \.self) { idx in
                        let isReserved = reservedColorIndices.contains(idx)
                        Circle()
                            .fill(CatppuccinSpeaker.palette[idx])
                            .frame(width: 24, height: 24)
                            .overlay(
                                Circle()
                                    .strokeBorder(enrollColorIndex == idx ? Color.primary : Color.clear, lineWidth: 2)
                            )
                            .opacity(isReserved ? 0.3 : 1.0)
                            .onTapGesture {
                                if !isReserved { enrollColorIndex = idx }
                            }
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    showEnrollSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Enroll") {
                    guard let entry = selectedEntry else { return }
                    showEnrollSheet = false
                    Task { await enrollFromSegment(entry, name: enrollName, colorIndex: enrollColorIndex) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(enrollName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 340)
    }

    /// Color indices already reserved by enrolled voices.
    private var reservedColorIndices: Set<Int> {
        Set(VoiceID.shared.allEnrolledVoices().compactMap(\.colorIndex))
    }

    // MARK: - Processing Overlay

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(1.2)
                Text(processingMessage)
                    .font(.subheadline)
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Toast

    private func toastView(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.85), in: Capsule())
                .padding(.bottom, 16)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation { toastMessage = nil }
            }
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

    // MARK: - Reassign Speaker

    private func reassignEntry(at index: Int, to newSpeaker: String) {
        guard index >= 0 && index < entries.count else { return }
        let old = entries[index]
        entries[index] = TranscriptEntry(
            speaker: newSpeaker,
            start: old.start,
            end: old.end,
            text: old.text,
            stream: old.stream,
            isFinal: old.isFinal
        )
        MeetingStore.shared.saveTranscriptEntries(for: meeting, entries: entries)
        showToast("Reassigned to \(newSpeaker)")
    }

    // MARK: - Enroll from Segment

    private func enrollFromSegment(_ entry: TranscriptEntry, name: String, colorIndex: Int?) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isProcessing = true
        processingMessage = "Converting audio..."

        do {
            // 1. Extract audio clip from the opus file
            let clip = try extractAudioClip(for: entry)

            // 2. Prepare VoiceID models
            processingMessage = "Loading models..."
            try await VoiceID.shared.prepare()

            // 3. Enroll
            processingMessage = "Enrolling voice..."
            let userID = trimmed.lowercased().replacingOccurrences(of: " ", with: "_")
            try await VoiceID.shared.enroll(userID: userID, audioClips: [clip], colorIndex: colorIndex)

            // 4. Reassign this segment (and any matching ones) to the new userID
            reassignMatchingSpeaker(oldSpeaker: entry.speaker, newSpeaker: userID)

            isProcessing = false
            showToast("Enrolled \(trimmed)")
        } catch {
            isProcessing = false
            errorMessage = "Enrollment failed: \(error.localizedDescription)"
            showError = true
        }
    }

    // MARK: - Enhance Enrollment

    private func enhanceVoice(entry: TranscriptEntry, userID: String) async {
        isProcessing = true
        processingMessage = "Converting audio..."

        do {
            let clip = try extractAudioClip(for: entry)

            processingMessage = "Loading models..."
            try await VoiceID.shared.prepare()

            processingMessage = "Enhancing voice..."
            try await VoiceID.shared.enhance(userID: userID, audioClip: clip)

            isProcessing = false
            showToast("Enhanced \(userID)")
        } catch {
            isProcessing = false
            errorMessage = "Enhancement failed: \(error.localizedDescription)"
            showError = true
        }
    }

    // MARK: - Reassign All Matching

    /// After enrollment, reassign all segments from the same old speaker label
    /// to the new enrolled userID, then save.
    private func reassignMatchingSpeaker(oldSpeaker: String, newSpeaker: String) {
        var changed = false
        for i in entries.indices {
            if entries[i].speaker == oldSpeaker {
                let old = entries[i]
                entries[i] = TranscriptEntry(
                    speaker: newSpeaker,
                    start: old.start,
                    end: old.end,
                    text: old.text,
                    stream: old.stream,
                    isFinal: old.isFinal
                )
                changed = true
            }
        }
        if changed {
            MeetingStore.shared.saveTranscriptEntries(for: meeting, entries: entries)
        }
    }

    // MARK: - Audio Extraction

    /// Extract a 16 kHz mono Float32 audio clip from the meeting's opus file,
    /// covering the segment's time range expanded to at least 10 seconds
    /// (required by the Pyannote segmentation model for embedding extraction).
    ///
    /// Prefers the per-stream opus file (local.opus / remote.opus) for cleaner
    /// single-speaker audio; falls back to the mixed recording.opus.
    private func extractAudioClip(for entry: TranscriptEntry) throws -> [Float] {
        // Prefer per-stream file for cleaner audio
        let fm = FileManager.default
        let perStreamURL: URL = entry.stream == StreamType.mic.rawValue
            ? meeting.localRecordingURL
            : meeting.remoteRecordingURL
        let opusURL: URL
        if fm.fileExists(atPath: perStreamURL.path) {
            opusURL = perStreamURL
        } else if fm.fileExists(atPath: meeting.recordingURL.path) {
            opusURL = meeting.recordingURL
        } else {
            throw AudioClipError.noRecordingFile
        }

        // Decode opus to 16 kHz mono Float32 samples
        let allSamples = try Self.decodeOpusToSamples(opusURL: opusURL)
        let sampleRate: Double = 16_000

        // Calculate the 10s extraction window centered on the segment
        let segMid = (entry.start + entry.end) / 2.0
        let segDuration = entry.end - entry.start
        let windowDuration = max(10.0, segDuration)
        var windowStart = segMid - windowDuration / 2.0
        var windowEnd = segMid + windowDuration / 2.0

        // Clamp to file bounds
        let totalDuration = Double(allSamples.count) / sampleRate
        if windowStart < 0 {
            windowStart = 0
            windowEnd = min(windowDuration, totalDuration)
        }
        if windowEnd > totalDuration {
            windowEnd = totalDuration
            windowStart = max(0, windowEnd - windowDuration)
        }

        let startSample = max(0, Int(windowStart * sampleRate))
        let endSample = min(allSamples.count, Int(windowEnd * sampleRate))
        guard endSample > startSample else {
            throw AudioClipError.segmentOutOfRange
        }

        return Array(allSamples[startSample..<endSample])
    }

    /// Decode an Opus file to 16 kHz mono Float32 samples entirely in memory.
    ///
    /// Uses SFBAudioEngine's `AudioDecoder` to decode opus → PCM, then
    /// `MeetingAudioConverter.convertTo16kMono` for resampling/channel mixing.
    private static func decodeOpusToSamples(opusURL: URL) throws -> [Float] {
        let decoder = try AudioDecoder(url: opusURL)
        try decoder.open()

        let processingFormat = decoder.processingFormat
        let chunkFrames: AVAudioFrameCount = 16384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkFrames) else {
            throw AudioClipError.conversionFailed
        }

        var allSamples: [Float] = []

        // Decode all frames
        while true {
            buffer.frameLength = 0
            try decoder.decode(into: buffer, length: chunkFrames)
            if buffer.frameLength == 0 { break }

            // Convert each chunk to 16 kHz mono
            if let mono16k = MeetingAudioConverter.convertTo16kMono(buffer) {
                let samples = MeetingAudioConverter.toFloatArray(mono16k)
                allSamples.append(contentsOf: samples)
            }
        }

        try decoder.close()

        guard !allSamples.isEmpty else {
            throw AudioClipError.conversionFailed
        }
        return allSamples
    }

    // MARK: - Helpers

    private func showToast(_ message: String) {
        withAnimation { toastMessage = message }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Audio Clip Errors

private enum AudioClipError: Error, LocalizedError {
    case noRecordingFile
    case conversionFailed
    case segmentOutOfRange

    var errorDescription: String? {
        switch self {
        case .noRecordingFile: return "No recording file found for this meeting"
        case .conversionFailed: return "Failed to decode Opus audio"
        case .segmentOutOfRange: return "Segment time range is outside the recording"
        }
    }
}

// MARK: - Single Transcript Row

private struct MeetingTranscriptRow: View {
    let entry: TranscriptEntry
    @ObservedObject var player: MeetingPlayer
    let recordingURL: URL
    let hasRecording: Bool
    let enrolledVoices: [VoiceEmbedding]

    /// Callbacks for context menu actions.
    let onEnroll: (TranscriptEntry) -> Void
    let onReassign: (TranscriptEntry, String) -> Void
    let onEnhance: (TranscriptEntry, String) -> Void

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
        .contextMenu { contextMenuContent }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var contextMenuContent: some View {
        if hasRecording {
            Button("Enroll as New Speaker...") {
                onEnroll(entry)
            }

            Divider()

            if !enrolledVoices.isEmpty {
                Menu("Reassign to") {
                    ForEach(enrolledVoices) { voice in
                        Button(voice.userID) {
                            onReassign(entry, voice.userID)
                        }
                        .disabled(voice.userID == entry.speaker)
                    }
                }

                Menu("Enhance Voice") {
                    ForEach(enrolledVoices) { voice in
                        Button(voice.userID) {
                            onEnhance(entry, voice.userID)
                        }
                    }
                }
            } else {
                // No enrolled voices — show disabled hints
                Button("Reassign to") {}
                    .disabled(true)
                Button("Enhance Voice") {}
                    .disabled(true)
            }
        } else {
            // No recording — only allow reassignment if voices exist
            if !enrolledVoices.isEmpty {
                Menu("Reassign to") {
                    ForEach(enrolledVoices) { voice in
                        Button(voice.userID) {
                            onReassign(entry, voice.userID)
                        }
                        .disabled(voice.userID == entry.speaker)
                    }
                }
            }
        }
    }

    // MARK: - Segment Buttons

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
