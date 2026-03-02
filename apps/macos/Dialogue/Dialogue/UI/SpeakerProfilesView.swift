import SwiftData
import SwiftUI

/// Standalone window for managing speaker profiles and diarization settings.
///
/// Sections:
/// 1. **Diarization Mode** — Picker to switch between Sortformer and Pyannote.
/// 2. **Speaker Profiles** — List of enrolled voices with rename/delete.
/// 3. **Enroll Voice** — Button that opens a recording sheet.
@available(macOS 26.0, *)
struct SpeakerProfilesView: View {

    @AppStorage("diarizationMode") private var diarizationMode: DiarizationMode = .pyannoteStreaming

    /// Value-type snapshots for display — avoids holding live SwiftData model
    /// objects that can be invalidated across context resets.
    @State private var profiles: [ProfileSnapshot] = []
    @State private var showEnrollSheet = false
    @State private var editingId: String?
    @State private var editName: String = ""
    @State private var loadError: String?

    @ObservedObject private var preloader = ModelPreloader.shared

    var body: some View {
        Form {
            // --- Diarization Mode ---
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Diarization Engine")
                        .font(.headline)
                    Text("Choose which speaker diarization model to use during recordings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Mode", selection: $diarizationMode) {
                    ForEach(DiarizationMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: diarizationMode) { _, _ in
                    ModelPreloader.shared.preloadIfModeChanged()
                }

                if !preloader.state.isReady {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Downloading models...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // --- Speaker Profiles ---
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speaker Profiles")
                        .font(.headline)
                    Text("Enrolled voices are matched automatically during recordings. Enroll yourself and frequent meeting participants for best results.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if profiles.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            Image(systemName: "person.wave.2")
                                .font(.title2)
                                .foregroundStyle(.tertiary)
                            Text("No speaker profiles yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 12)
                        Spacer()
                    }
                } else {
                    ForEach(profiles) { snap in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                if editingId == snap.id {
                                    HStack(spacing: 4) {
                                        TextField("Name", text: $editName)
                                            .textFieldStyle(.roundedBorder)
                                            .frame(maxWidth: 200)
                                            .onSubmit { commitRename(snap.id) }
                                        Button("Save") { commitRename(snap.id) }
                                            .buttonStyle(.borderless)
                                            .font(.caption)
                                        Button("Cancel") { editingId = nil }
                                            .buttonStyle(.borderless)
                                            .font(.caption)
                                    }
                                } else {
                                    Text(snap.displayName)
                                        .fontWeight(.medium)
                                }
                                Text("Seen \(snap.sampleCount) time(s) -- Last: \(snap.lastSeen, style: .relative) ago")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()

                            Button {
                                editingId = snap.id
                                editName = snap.displayName
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                            .help("Rename")

                            Button(role: .destructive) {
                                deleteProfile(snap.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete")
                        }
                        .padding(.vertical, 2)
                    }
                }

                if let error = loadError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button {
                        showEnrollSheet = true
                    } label: {
                        Label("Enroll Voice", systemImage: "mic.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 520)
        .onAppear { loadProfiles() }
        .sheet(isPresented: $showEnrollSheet) {
            VoiceEnrollmentSheet(onComplete: {
                loadProfiles()
            })
        }
    }

    // MARK: - Shared Context

    /// The single model context from the shared `SpeakerProfileStore`.
    /// All reads and writes go through this to avoid the
    /// "model instance was destroyed" crash caused by multiple containers.
    private var sharedContext: ModelContext? {
        SpeakerProfileStore.shared?.modelContainer.mainContext
    }

    // MARK: - Data

    private func loadProfiles() {
        guard let context = sharedContext else {
            loadError = "Profile store unavailable"
            return
        }
        do {
            let descriptor = FetchDescriptor<SpeakerProfile>(
                sortBy: [SortDescriptor(\.lastSeenDate, order: .reverse)]
            )
            let models = try context.fetch(descriptor)
            // Snapshot into value types immediately so the view never
            // holds stale SwiftData model object references.
            profiles = models.map { ProfileSnapshot(from: $0) }
            loadError = nil
        } catch {
            loadError = "Failed to load profiles: \(error.localizedDescription)"
        }
    }

    private func deleteProfile(_ speakerId: String) {
        guard let context = sharedContext else { return }
        do {
            let descriptor = FetchDescriptor<SpeakerProfile>(
                sortBy: [SortDescriptor(\.lastSeenDate, order: .reverse)]
            )
            let all = try context.fetch(descriptor)
            if let toDelete = all.first(where: { $0.speakerID == speakerId }) {
                context.delete(toDelete)
                try context.save()
            }
            loadProfiles()
        } catch {
            loadError = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func commitRename(_ speakerId: String) {
        let newName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { editingId = nil; return }
        guard let context = sharedContext else { return }

        do {
            let descriptor = FetchDescriptor<SpeakerProfile>(
                sortBy: [SortDescriptor(\.lastSeenDate, order: .reverse)]
            )
            let all = try context.fetch(descriptor)
            if let toRename = all.first(where: { $0.speakerID == speakerId }) {
                toRename.displayName = newName
                try context.save()
            }
            editingId = nil
            loadProfiles()
        } catch {
            loadError = "Rename failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Profile Snapshot (Value Type)

/// Lightweight, non-model snapshot of a `SpeakerProfile` for display.
/// Avoids holding live SwiftData `@Model` references in `@State` which
/// can be invalidated by context resets.
private struct ProfileSnapshot: Identifiable {
    let id: String
    let displayName: String
    let sampleCount: Int
    let lastSeen: Date

    init(from model: SpeakerProfile) {
        self.id = model.speakerID
        self.displayName = model.displayName
        self.sampleCount = model.sampleCount
        self.lastSeen = model.lastSeenDate
    }
}
