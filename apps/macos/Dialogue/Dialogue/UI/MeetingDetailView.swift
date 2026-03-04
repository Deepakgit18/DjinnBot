import AVFoundation
import SwiftUI
import AppKit
import SFBAudioEngine

/// Displays the transcript of a saved meeting with integrated audio playback.
///
/// Shows the meeting name, date, transport controls (play/pause/stop + seek bar),
/// and a scrollable list of transcript entries with speaker labels, timestamps,
/// per-segment playback buttons, and a fully custom context menu on each segment's
/// text for voice enrollment, speaker reassignment, enrollment enhancement,
/// text editing, and inline split & reassign.
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

    /// The entry selected for enrollment operations.
    @State private var selectedEntry: TranscriptEntry?

    /// Enroll-from-segment sheet state.
    @State private var showEnrollSheet = false
    @State private var enrollName = ""
    @State private var enrollColorIndex: Int? = nil

    /// Edit sheet — driven by item so the text is always populated correctly.
    @State private var editingEntry: TranscriptEntry?

    /// Processing overlay.
    @State private var isProcessing = false
    @State private var processingMessage = ""

    /// Error alert.
    @State private var showError = false
    @State private var errorMessage = ""

    /// Success toast.
    @State private var toastMessage: String?

    /// Full-document editing sheet.
    @State private var showDocumentEdit = false

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
        .sheet(item: $editingEntry) { entry in
            EditSegmentSheet(entry: entry) { newText in
                saveEdit(entryID: entry.id, newText: newText)
            }
        }
        .sheet(isPresented: $showDocumentEdit) {
            TranscriptDocumentEditView(
                originalEntries: entries,
                onSave: { newEntries in
                    entries = newEntries
                    collapseAdjacentEntries()
                    MeetingStore.shared.saveTranscriptEntries(for: meeting, entries: entries)
                    showToast("Transcript updated")
                }
            )
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

            if !entries.isEmpty {
                Button {
                    showDocumentEdit = true
                } label: {
                    Label("Edit as Document", systemImage: "doc.text")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .help("Edit the entire transcript as a single document")
            }

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

            HStack(spacing: 16) {
                Button {
                    player.togglePlayPause(url: meeting.recordingURL)
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    player.stop()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .disabled(!player.isPlaying && !player.isPaused)

                Button {
                    player.seek(to: max(0, player.currentTime - 10))
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.callout)
                }
                .buttonStyle(.borderless)

                Button {
                    player.seek(to: min(player.totalTime, player.currentTime + 10))
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

    /// All unique speaker names in the transcript, excluding enrolled voice IDs.
    private var callSpeakers: [String] {
        let enrolledIDs = Set(VoiceID.shared.allEnrolledVoices().map(\.userID))
        let unique = Set(entries.map(\.speaker))
        return unique.filter { !enrolledIDs.contains($0) }.sorted()
    }

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
                        callSpeakers: callSpeakers,
                        onEnroll: { e in
                            selectedEntry = e
                            enrollName = ""
                            enrollColorIndex = nil
                            showEnrollSheet = true
                        },
                        onReassign: { _, userID in
                            reassignEntry(at: index, to: userID)
                        },
                        onReassignAll: { e, userID in
                            reassignAllEntries(from: e.speaker, to: userID)
                        },
                        onEnhance: { e, userID in
                            Task { await enhanceVoice(entry: e, userID: userID) }
                        },
                        onEdit: { e in
                            editingEntry = e
                        },
                        onSplitReassign: { e, range, speaker in
                            splitEntry(entryID: e.id, range: range, newSpeaker: speaker)
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

    // MARK: - Empty / Error States

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

    // MARK: - Collapse Adjacent Same-Speaker Entries

    /// Merge adjacent entries with the same speaker and stream into one,
    /// concatenating text and extending time ranges. Called after any
    /// operation that may create adjacent same-speaker segments (reassign,
    /// split, enrollment reassign).
    private func collapseAdjacentEntries() {
        guard entries.count > 1 else { return }
        var collapsed: [TranscriptEntry] = [entries[0]]

        for i in 1..<entries.count {
            let prev = collapsed[collapsed.count - 1]
            let curr = entries[i]

            if curr.speaker == prev.speaker &&
               curr.stream == prev.stream &&
               curr.speaker != "Speaker-?" &&
               (curr.start - prev.end) < 3.0 {
                // Merge into prev
                collapsed[collapsed.count - 1] = TranscriptEntry(
                    speaker: prev.speaker,
                    start: prev.start,
                    end: curr.end,
                    text: prev.text + " " + curr.text,
                    stream: prev.stream,
                    isFinal: prev.isFinal
                )
            } else {
                collapsed.append(curr)
            }
        }

        if collapsed.count != entries.count {
            entries = collapsed
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
        collapseAdjacentEntries()
        MeetingStore.shared.saveTranscriptEntries(for: meeting, entries: entries)
        showToast("Reassigned to \(newSpeaker)")
    }

    // MARK: - Reassign All Segments of a Speaker

    private func reassignAllEntries(from oldSpeaker: String, to newSpeaker: String) {
        reassignMatchingSpeaker(oldSpeaker: oldSpeaker, newSpeaker: newSpeaker)
        showToast("Reassigned all \(oldSpeaker) to \(newSpeaker)")
    }

    // MARK: - Edit Segment Text

    private func saveEdit(entryID: UUID, newText: String) {
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else { return }
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let old = entries[idx]
        entries[idx] = TranscriptEntry(
            speaker: old.speaker,
            start: old.start,
            end: old.end,
            text: trimmed,
            stream: old.stream,
            isFinal: old.isFinal
        )
        MeetingStore.shared.saveTranscriptEntries(for: meeting, entries: entries)
        showToast("Text updated")
    }

    // MARK: - Split & Reassign

    private func splitEntry(entryID: UUID, range: NSRange, newSpeaker: String) {
        guard let idx = entries.firstIndex(where: { $0.id == entryID }) else { return }
        let entry = entries[idx]
        let nsText = entry.text as NSString

        guard range.location != NSNotFound,
              range.length > 0,
              range.location + range.length <= nsText.length else { return }

        let beforeText = nsText.substring(to: range.location).trimmingCharacters(in: .whitespaces)
        let selectedText = nsText.substring(with: range).trimmingCharacters(in: .whitespaces)
        let afterText = nsText.substring(from: range.location + range.length).trimmingCharacters(in: .whitespaces)

        let totalChars = max(1, nsText.length)
        let duration = entry.end - entry.start

        var newEntries: [TranscriptEntry] = []
        var currentTime = entry.start

        if !beforeText.isEmpty {
            let beforeEnd = entry.start + duration * Double(range.location) / Double(totalChars)
            newEntries.append(TranscriptEntry(
                speaker: entry.speaker,
                start: currentTime,
                end: beforeEnd,
                text: beforeText,
                stream: entry.stream,
                isFinal: entry.isFinal
            ))
            currentTime = beforeEnd
        }

        if !selectedText.isEmpty {
            let selectedEnd = entry.start + duration * Double(range.location + range.length) / Double(totalChars)
            newEntries.append(TranscriptEntry(
                speaker: newSpeaker,
                start: currentTime,
                end: selectedEnd,
                text: selectedText,
                stream: entry.stream,
                isFinal: entry.isFinal
            ))
            currentTime = selectedEnd
        }

        if !afterText.isEmpty {
            newEntries.append(TranscriptEntry(
                speaker: entry.speaker,
                start: currentTime,
                end: entry.end,
                text: afterText,
                stream: entry.stream,
                isFinal: entry.isFinal
            ))
        }

        entries.replaceSubrange(idx...idx, with: newEntries)
        collapseAdjacentEntries()
        MeetingStore.shared.saveTranscriptEntries(for: meeting, entries: entries)
        showToast("Split and reassigned to \(newSpeaker)")
    }

    // MARK: - Enroll from Segment

    private func enrollFromSegment(_ entry: TranscriptEntry, name: String, colorIndex: Int?) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isProcessing = true
        processingMessage = "Converting audio..."

        do {
            let clip = try extractAudioClip(for: entry)

            processingMessage = "Loading models..."
            try await VoiceID.shared.prepare()

            processingMessage = "Enrolling voice..."
            let userID = trimmed.lowercased().replacingOccurrences(of: " ", with: "_")
            try await VoiceID.shared.enroll(userID: userID, audioClips: [clip], colorIndex: colorIndex)

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
            collapseAdjacentEntries()
            MeetingStore.shared.saveTranscriptEntries(for: meeting, entries: entries)
        }
    }

    // MARK: - Audio Extraction

    private func extractAudioClip(for entry: TranscriptEntry) throws -> [Float] {
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

        let allSamples = try Self.decodeOpusToSamples(opusURL: opusURL)
        let sampleRate: Double = 16_000

        let segMid = (entry.start + entry.end) / 2.0
        let segDuration = entry.end - entry.start
        let windowDuration = max(10.0, segDuration)
        var windowStart = segMid - windowDuration / 2.0
        var windowEnd = segMid + windowDuration / 2.0

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

    private static func decodeOpusToSamples(opusURL: URL) throws -> [Float] {
        let decoder = try AudioDecoder(url: opusURL)
        try decoder.open()

        let processingFormat = decoder.processingFormat
        let chunkFrames: AVAudioFrameCount = 16384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat, frameCapacity: chunkFrames) else {
            throw AudioClipError.conversionFailed
        }

        var allSamples: [Float] = []

        while true {
            buffer.frameLength = 0
            try decoder.decode(into: buffer, length: chunkFrames)
            if buffer.frameLength == 0 { break }

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

// MARK: - Edit Segment Sheet

/// Standalone sheet for editing a segment's text.
/// Uses `init(initialValue:)` on `@State` to guarantee the text field is
/// populated with the entry's text when the sheet first appears.
private struct EditSegmentSheet: View {
    let entry: TranscriptEntry
    let onSave: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) var dismiss

    init(entry: TranscriptEntry, onSave: @escaping (String) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _text = State(initialValue: entry.text)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Segment Text")
                .font(.headline)

            Text("\(entry.speaker) at \(formatTime(entry.start))")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .frame(width: 420, height: 120)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            HStack(spacing: 12) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Button("Save") {
                    onSave(text)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Segment NSTextView

/// Custom NSTextView subclass that overrides the right-click context menu.
/// The `buildContextMenu` closure is called with the current selected range
/// (nil if nothing is selected) and must return the complete menu.
private class SegmentNSTextView: NSTextView {
    var buildContextMenu: ((NSRange?) -> NSMenu)?
    var heightDidChange: ((CGFloat) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let range = selectedRange()
        return buildContextMenu?(range.length > 0 ? range : nil) ?? super.menu(for: event)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        textContainer?.containerSize = NSSize(width: newSize.width, height: .greatestFiniteMagnitude)
        recalculateHeight()
    }

    override func didChangeText() {
        super.didChangeText()
        recalculateHeight()
    }

    private func recalculateHeight() {
        guard let container = textContainer, let lm = layoutManager else { return }
        lm.ensureLayout(for: container)
        let usedRect = lm.usedRect(for: container)
        let newHeight = max(ceil(usedRect.height), 16)
        heightDidChange?(newHeight)
    }
}

// MARK: - SegmentTextView (NSViewRepresentable)

/// Embeds a `SegmentNSTextView` in SwiftUI. The text is selectable but not
/// editable. Right-clicking anywhere on the text shows our full custom context
/// menu. When text is selected, an additional "Reassign Selected to >" submenu
/// appears at the top — enabling inline split & reassign without any sheet.
private struct SegmentTextView: NSViewRepresentable {
    let text: String
    @Binding var height: CGFloat

    // Data needed to build the context menu
    let enrolledVoices: [VoiceEmbedding]
    let callSpeakers: [String]
    let currentSpeaker: String
    let hasRecording: Bool
    let segmentDuration: TimeInterval

    // Callbacks
    let onEdit: () -> Void
    let onEnroll: () -> Void
    let onReassign: (String) -> Void
    let onReassignAll: (String) -> Void
    let onEnhance: (String) -> Void
    let onSplitReassign: (NSRange, String) -> Void

    static let minEnrollmentDuration: TimeInterval = 10.0

    func makeNSView(context: Context) -> SegmentNSTextView {
        let tv = SegmentNSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: NSFont.systemFontSize)
        tv.textColor = .labelColor
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.string = text

        let coordinator = context.coordinator
        tv.buildContextMenu = { [weak coordinator] range in
            coordinator?.buildMenu(selectedRange: range) ?? NSMenu()
        }
        tv.heightDidChange = { [weak coordinator] newHeight in
            coordinator?.updateHeight(newHeight)
        }

        return tv
    }

    func updateNSView(_ tv: SegmentNSTextView, context: Context) {
        // Keep coordinator in sync with latest parent values
        context.coordinator.parent = self

        if tv.string != text {
            tv.string = text
            // Programmatic string assignment doesn't trigger didChangeText(),
            // so the height callback never fires. Force a layout + recalc.
            tv.invalidateIntrinsicContentSize()
            if let container = tv.textContainer, let lm = tv.layoutManager {
                lm.ensureLayout(for: container)
                let usedRect = lm.usedRect(for: container)
                let newHeight = max(ceil(usedRect.height), 16)
                context.coordinator.updateHeight(newHeight)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject {
        var parent: SegmentTextView

        init(parent: SegmentTextView) {
            self.parent = parent
        }

        /// Container for split action data attached to menu items.
        private class SplitAction: NSObject {
            let range: NSRange
            let speaker: String
            init(range: NSRange, speaker: String) {
                self.range = range
                self.speaker = speaker
            }
        }

        /// Container for reassign-all action data attached to menu items.
        private class ReassignAllAction: NSObject {
            let speaker: String
            init(speaker: String) {
                self.speaker = speaker
            }
        }

        func updateHeight(_ newHeight: CGFloat) {
            guard abs(newHeight - parent.height) > 0.5 else { return }
            DispatchQueue.main.async {
                self.parent.height = newHeight
            }
        }

        func buildMenu(selectedRange: NSRange?) -> NSMenu {
            let menu = NSMenu()
            let p = parent
            let minDur = SegmentTextView.minEnrollmentDuration

            // ── Reassign Selected (only when text is selected) ──
            if let range = selectedRange {
                let splitSubmenu = NSMenu()
                let allSpeakers = buildAllSpeakers()
                for speaker in allSpeakers where speaker != p.currentSpeaker {
                    let item = NSMenuItem(
                        title: speaker,
                        action: #selector(splitReassignAction(_:)),
                        keyEquivalent: ""
                    )
                    item.target = self
                    item.representedObject = SplitAction(range: range, speaker: speaker)
                    splitSubmenu.addItem(item)
                }
                if splitSubmenu.items.isEmpty {
                    splitSubmenu.addItem(NSMenuItem(title: "No other speakers", action: nil, keyEquivalent: ""))
                }
                let splitItem = NSMenuItem(title: "Reassign Selected to", action: nil, keyEquivalent: "")
                splitItem.submenu = splitSubmenu
                menu.addItem(splitItem)
                menu.addItem(.separator())
            }

            // ── Edit Text ──
            let editItem = NSMenuItem(title: "Edit Text...", action: #selector(editAction), keyEquivalent: "")
            editItem.target = self
            menu.addItem(editItem)

            menu.addItem(.separator())

            // ── Enroll as New Speaker ──
            if p.hasRecording {
                if p.segmentDuration >= minDur {
                    let item = NSMenuItem(title: "Enroll as New Speaker...", action: #selector(enrollAction), keyEquivalent: "")
                    item.target = self
                    menu.addItem(item)
                } else {
                    menu.addItem(NSMenuItem(title: "Enroll as New Speaker... (need 10s+)", action: nil, keyEquivalent: ""))
                }
                menu.addItem(.separator())
            }

            // ── Reassign whole segment ──
            let reassignSubmenu = NSMenu()
            let allTargets: [(String, Bool)] = // (speaker, isEnabled)
                p.enrolledVoices.map { ($0.userID, $0.userID != p.currentSpeaker) }
                + p.callSpeakers.filter { $0 != p.currentSpeaker }.map { ($0, true) }

            for (speaker, enabled) in allTargets {
                let perSpeakerSub = NSMenu()

                let thisItem = NSMenuItem(
                    title: "Just This Segment",
                    action: #selector(reassignAction(_:)),
                    keyEquivalent: ""
                )
                thisItem.target = self
                thisItem.representedObject = speaker as NSString
                perSpeakerSub.addItem(thisItem)

                let allItem = NSMenuItem(
                    title: "All \(p.currentSpeaker) Segments",
                    action: #selector(reassignAllAction(_:)),
                    keyEquivalent: ""
                )
                allItem.target = self
                allItem.representedObject = ReassignAllAction(speaker: speaker)
                perSpeakerSub.addItem(allItem)

                let speakerItem = NSMenuItem(title: speaker, action: nil, keyEquivalent: "")
                speakerItem.submenu = perSpeakerSub
                speakerItem.isEnabled = enabled
                reassignSubmenu.addItem(speakerItem)
            }

            if allTargets.isEmpty {
                reassignSubmenu.addItem(NSMenuItem(title: "No other speakers", action: nil, keyEquivalent: ""))
            }
            let reassignItem = NSMenuItem(title: "Reassign to", action: nil, keyEquivalent: "")
            reassignItem.submenu = reassignSubmenu
            menu.addItem(reassignItem)

            // ── Enhance Voice ──
            if p.hasRecording && !p.enrolledVoices.isEmpty {
                let enhanceSubmenu = NSMenu()
                for voice in p.enrolledVoices {
                    if p.segmentDuration >= minDur {
                        let item = NSMenuItem(title: voice.userID, action: #selector(enhanceAction(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = voice.userID as NSString
                        enhanceSubmenu.addItem(item)
                    } else {
                        enhanceSubmenu.addItem(NSMenuItem(title: "\(voice.userID) (need 10s+)", action: nil, keyEquivalent: ""))
                    }
                }
                let enhanceItem = NSMenuItem(title: "Enhance Voice", action: nil, keyEquivalent: "")
                enhanceItem.submenu = enhanceSubmenu
                menu.addItem(enhanceItem)
            }

            menu.addItem(.separator())

            // ── Standard text actions (target nil = responder chain = the text view) ──
            menu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
            menu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

            return menu
        }

        private func buildAllSpeakers() -> [String] {
            let enrolled = parent.enrolledVoices.map(\.userID)
            let call = parent.callSpeakers
            var seen = Set<String>()
            var result: [String] = []
            for s in enrolled + call {
                if seen.insert(s).inserted { result.append(s) }
            }
            return result
        }

        // MARK: - Menu Actions

        @objc func editAction() {
            DispatchQueue.main.async { self.parent.onEdit() }
        }

        @objc func enrollAction() {
            DispatchQueue.main.async { self.parent.onEnroll() }
        }

        @objc func reassignAction(_ sender: NSMenuItem) {
            guard let speaker = sender.representedObject as? NSString else { return }
            DispatchQueue.main.async { self.parent.onReassign(speaker as String) }
        }

        @objc func reassignAllAction(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? ReassignAllAction else { return }
            DispatchQueue.main.async { self.parent.onReassignAll(action.speaker) }
        }

        @objc func enhanceAction(_ sender: NSMenuItem) {
            guard let userID = sender.representedObject as? NSString else { return }
            DispatchQueue.main.async { self.parent.onEnhance(userID as String) }
        }

        @objc func splitReassignAction(_ sender: NSMenuItem) {
            guard let action = sender.representedObject as? SplitAction else { return }
            DispatchQueue.main.async { self.parent.onSplitReassign(action.range, action.speaker) }
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
    let callSpeakers: [String]

    let onEnroll: (TranscriptEntry) -> Void
    let onReassign: (TranscriptEntry, String) -> Void
    let onReassignAll: (TranscriptEntry, String) -> Void
    let onEnhance: (TranscriptEntry, String) -> Void
    let onEdit: (TranscriptEntry) -> Void
    let onSplitReassign: (TranscriptEntry, NSRange, String) -> Void

    @State private var textHeight: CGFloat = 16

    private var isActiveSegment: Bool {
        player.isPlaying &&
        player.currentTime >= entry.start &&
        player.currentTime <= entry.end
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Per-segment playback buttons
            if hasRecording {
                segmentButtons
                    .padding(.top, 2)
            }

            // Timestamp
            Text(formatTimestamp(entry.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .trailing)
                .padding(.top, 1)

            // Speaker name
            Text(entry.speaker)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(CatppuccinSpeaker.labelColor(for: entry.speaker))
                .padding(.top, 1)

            // Text — custom NSTextView with full context menu
            SegmentTextView(
                text: entry.text,
                height: $textHeight,
                enrolledVoices: enrolledVoices,
                callSpeakers: callSpeakers,
                currentSpeaker: entry.speaker,
                hasRecording: hasRecording,
                segmentDuration: entry.end - entry.start,
                onEdit: { onEdit(entry) },
                onEnroll: { onEnroll(entry) },
                onReassign: { speaker in onReassign(entry, speaker) },
                onReassignAll: { speaker in onReassignAll(entry, speaker) },
                onEnhance: { userID in onEnhance(entry, userID) },
                onSplitReassign: { range, speaker in onSplitReassign(entry, range, speaker) }
            )
            .frame(height: max(textHeight, 16))

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(CatppuccinSpeaker.color(for: entry.speaker)
                    .opacity(isActiveSegment ? 0.15 : CatppuccinSpeaker.rowBackgroundOpacity))
        )
        .contextMenu { rowContextMenu }
    }

    // MARK: - Row Context Menu (for non-text areas)

    /// Minimum segment duration (seconds) for enrollment.
    private static let minEnrollmentDuration: TimeInterval = 10.0

    /// Non-enrolled call speakers eligible for reassignment (excludes current speaker).
    private var reassignableCallSpeakers: [String] {
        callSpeakers.filter { $0 != entry.speaker }
    }

    private var hasReassignTargets: Bool {
        !enrolledVoices.isEmpty || !reassignableCallSpeakers.isEmpty
    }

    @ViewBuilder
    private var rowContextMenu: some View {
        Button("Edit Text...") { onEdit(entry) }

        Divider()

        if hasRecording {
            let segDuration = entry.end - entry.start
            if segDuration >= Self.minEnrollmentDuration {
                Button("Enroll as New Speaker...") { onEnroll(entry) }
            } else {
                Button("Enroll as New Speaker... (need 10s+)") {}
                    .disabled(true)
            }
            Divider()
        }

        if hasReassignTargets {
            Menu("Reassign to") {
                if !enrolledVoices.isEmpty {
                    ForEach(enrolledVoices) { voice in
                        Menu(voice.userID) {
                            Button("Just This Segment") { onReassign(entry, voice.userID) }
                            Button("All \(entry.speaker) Segments") { onReassignAll(entry, voice.userID) }
                        }
                        .disabled(voice.userID == entry.speaker)
                    }
                }
                if !reassignableCallSpeakers.isEmpty {
                    if !enrolledVoices.isEmpty { Divider() }
                    ForEach(reassignableCallSpeakers, id: \.self) { speaker in
                        Menu(speaker) {
                            Button("Just This Segment") { onReassign(entry, speaker) }
                            Button("All \(entry.speaker) Segments") { onReassignAll(entry, speaker) }
                        }
                    }
                }
            }
        } else {
            Button("Reassign to") {}.disabled(true)
        }

        if hasRecording && !enrolledVoices.isEmpty {
            let segDuration = entry.end - entry.start
            Menu("Enhance Voice") {
                ForEach(enrolledVoices) { voice in
                    if segDuration >= Self.minEnrollmentDuration {
                        Button(voice.userID) { onEnhance(entry, voice.userID) }
                    } else {
                        Button("\(voice.userID) (need 10s+)") {}.disabled(true)
                    }
                }
            }
        }
    }

    // MARK: - Segment Buttons

    private var segmentButtons: some View {
        HStack(spacing: 2) {
            Button {
                player.playFrom(url: recordingURL, time: entry.start)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .help("Play from here")

            Button {
                player.playSegment(url: recordingURL, from: entry.start, to: entry.end)
            } label: {
                Image(systemName: "forward.end.fill")
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
