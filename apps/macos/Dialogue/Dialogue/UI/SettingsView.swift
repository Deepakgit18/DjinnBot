import SwiftUI

/// Settings view for managing API key and app preferences.
struct SettingsView: View {
    @State private var apiKey: String = ""
    @State private var hasExistingKey: Bool = false
    @State private var showKey: Bool = false
    @State private var saveStatus: SaveStatus = .idle
    @State private var testStatus: TestStatus = .idle
    @State private var endpointURL: String = UserDefaults.standard.string(forKey: "aiEndpoint") ?? "https://localhost:8000/v1"
    @State private var agentId: String = UserDefaults.standard.string(forKey: "chatAgentId") ?? "chieko"

    // Diarization engine
    @AppStorage("diarizationMode") private var diarizationMode: DiarizationMode = .pyannoteStreaming

    // Voice ID thresholds (0.65 default when UserDefaults key is unset / zero)
    @State private var similarityThreshold: Double = {
        let v = UserDefaults.standard.double(forKey: "voiceID_similarityThreshold")
        return v == 0 ? 0.65 : v
    }()
    @State private var clusteringThreshold: Double = {
        let v = UserDefaults.standard.double(forKey: "voiceID_clusteringThreshold")
        return v == 0 ? 0.65 : v
    }()

    // Speaker profiles
    @State private var voices: [VoiceEmbedding] = []
    @State private var showEnrollSheet = false

    @ObservedObject private var preloader = ModelPreloader.shared
    @Environment(\.dismiss) private var dismiss

    /// The top-level Dialogue folder (parent of Notes and Meetings).
    private var dialogueFolder: URL {
        DocumentManager.shared.rootFolder.deletingLastPathComponent()
    }

    enum SaveStatus: Equatable {
        case idle, saving, saved, error(String)
    }

    enum TestStatus: Equatable {
        case idle, testing, success, error(String)
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("AI Configuration")
                        .font(.headline)

                    Text("Enter your API key for AI-powered features. The key is securely stored in the macOS Keychain and never leaves this device except when making API requests.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Endpoint URL (above API key)
                HStack {
                    TextField("Endpoint URL", text: $endpointURL, prompt: Text("https://your-server.example.com/v1"))
                        .textFieldStyle(.roundedBorder)
                    Text("Base URL ending in /v1")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Agent ID for chat (Phase 3)
                HStack {
                    TextField("Chat Agent ID", text: $agentId)
                        .textFieldStyle(.roundedBorder)
                    Text("Used for AI Chat sessions")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // API Key field
                HStack {
                    if showKey {
                        TextField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        SecureField("API Key", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    Button {
                        showKey.toggle()
                    } label: {
                        Image(systemName: showKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                }

                // Actions — right-aligned
                HStack {
                    // Status indicator on the left
                    switch saveStatus {
                    case .idle:
                        EmptyView()
                    case .saving:
                        ProgressView()
                            .scaleEffect(0.7)
                    case .saved:
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    case .error(let msg):
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    if case .success = testStatus {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else if case .error(let msg) = testStatus {
                        Label(msg, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }

                    Spacer()

                    if hasExistingKey {
                        Button("Delete Key", role: .destructive) {
                            deleteAPIKey()
                        }
                    }

                    Button("Test Connection") {
                        testConnection()
                    }
                    .disabled(apiKey.isEmpty || endpointURL.isEmpty)
                    .buttonStyle(.bordered)

                    Button("Save") {
                        saveAPIKey()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(apiKey.isEmpty)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Diarization Engine")
                        .font(.headline)

                    Text("Choose which model identifies who is speaking during recordings.")
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

            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Voice ID")
                        .font(.headline)

                    Text("Controls how confidently the app must recognise a voice before labelling it. Lower values accept looser matches (more names shown, but more mistakes); higher values require a closer match (fewer mistakes, but voices may go unrecognised).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Similarity Threshold")
                        Spacer()
                        Text(String(format: "%.2f", similarityThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $similarityThreshold, in: 0.50...0.90, step: 0.01)
                        .onChange(of: similarityThreshold) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "voiceID_similarityThreshold")
                        }
                    Text("How closely a voice must match an enrolled speaker to be identified. In Pyannote mode, this compares voice embeddings during and after recording. In Sortformer mode, no embeddings are produced, so this setting has no effect.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Clustering Threshold")
                        Spacer()
                        Text(String(format: "%.2f", clusteringThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $clusteringThreshold, in: 0.50...0.90, step: 0.01)
                        .onChange(of: clusteringThreshold) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "voiceID_clusteringThreshold")
                        }
                    Text("How aggressively speech segments are grouped into a single speaker during voice enrollment. A lower value merges more segments together; a higher value keeps them separate. In Pyannote mode, this shapes the voice profile built from enrollment clips. In Sortformer mode, enrollment does not use clustering, so this setting has no effect.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
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

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dialogue Folder")
                        .font(.headline)

                    Text("Meetings and Notes are stored inside this folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text(dialogueFolder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button("Open in Finder") {
                            NSWorkspace.shared.open(dialogueFolder)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 546, height: 900)
        .onAppear {
            loadExistingKey()
            loadVoices()
        }
        .sheet(isPresented: $showEnrollSheet) {
            if #available(macOS 26.0, *) {
                VoiceEnrollmentSheet(onComplete: {
                    loadVoices()
                })
            } else {
                Text("Voice enrollment requires macOS 26.0 or later.")
                    .padding()
            }
        }
    }

    // MARK: - Actions

    private func loadVoices() {
        voices = VoiceID.shared.allEnrolledVoices()
    }

    private func loadExistingKey() {
        if let existing = try? KeychainManager.shared.getAPIKey() {
            apiKey = existing
            hasExistingKey = true
        }
    }

    private func saveAPIKey() {
        saveStatus = .saving
        do {
            try KeychainManager.shared.saveAPIKey(apiKey)
            UserDefaults.standard.set(endpointURL, forKey: "aiEndpoint")
            UserDefaults.standard.set(agentId, forKey: "chatAgentId")
            hasExistingKey = true
            saveStatus = .saved

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if saveStatus == .saved {
                    saveStatus = .idle
                }
            }
        } catch {
            saveStatus = .error(error.localizedDescription)
        }
    }

    private func deleteAPIKey() {
        do {
            try KeychainManager.shared.deleteAPIKey()
            apiKey = ""
            hasExistingKey = false
            saveStatus = .idle
        } catch {
            saveStatus = .error(error.localizedDescription)
        }
    }
    
    private func testConnection() {
        testStatus = .testing

        // Test against the Djinn /v1/status endpoint
        let base = endpointURL.hasSuffix("/") ? String(endpointURL.dropLast()) : endpointURL
        guard let url = URL(string: "\(base)/status") else {
            testStatus = .error("Invalid URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    testStatus = .error(error.localizedDescription)
                    return
                }
                if let http = response as? HTTPURLResponse {
                    if (200..<300).contains(http.statusCode) {
                        testStatus = .success
                    } else if http.statusCode == 401 {
                        testStatus = .error("Unauthorized (401)")
                    } else {
                        testStatus = .error("HTTP \(http.statusCode)")
                    }
                } else {
                    testStatus = .error("No response")
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if testStatus == .success || testStatus != .idle {
                        testStatus = .idle
                    }
                }
            }
        }.resume()
    }
}
