import SwiftUI

/// Standalone window for managing speaker profiles and diarization settings.
///
/// Sections:
/// 1. **Diarization Mode** — Picker to switch between Sortformer and Pyannote.
/// 2. **Speaker Profiles** — List of enrolled voices with delete.
/// 3. **Enroll Voice** — Button that opens a recording sheet.
@available(macOS 26.0, *)
struct SpeakerProfilesView: View {

    /// Value-type snapshots of enrolled voices for display.
    @State private var voices: [VoiceEmbedding] = []
    @State private var showEnrollSheet = false

    var body: some View {
        Form {
            // --- Speaker Profiles ---
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Speaker Profiles")
                        .font(.headline)
                    Text("Enrolled voices are matched automatically during recordings. Enroll yourself and frequent meeting participants for best results.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if voices.isEmpty {
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
                    ForEach(voices) { voice in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(voice.userID)
                                    .fontWeight(.medium)
                                Text("Enrolled \(voice.enrolledAt, style: .relative) ago (\(voice.clipCount) clip\(voice.clipCount == 1 ? "" : "s"))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer()

                            Button(role: .destructive) {
                                VoiceID.shared.remove(userID: voice.userID)
                                loadVoices()
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Delete")
                        }
                        .padding(.vertical, 2)
                    }
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
        .onAppear { loadVoices() }
        .sheet(isPresented: $showEnrollSheet) {
            VoiceEnrollmentSheet(onComplete: {
                loadVoices()
            })
        }
    }

    // MARK: - Data

    private func loadVoices() {
        voices = VoiceID.shared.allEnrolledVoices()
    }
}
