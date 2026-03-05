import DialogueCore
import KeyboardShortcuts
import SwiftUI

// MARK: - Settings Tab Enum

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case ai = "AI"
    case voice = "Voice"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .ai: return "brain"
        case .voice: return "waveform"
        }
    }
}

// MARK: - Root Settings View

/// Settings view split into General, AI, and Voice tabs with a left sidebar.
struct SettingsView: View {
    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        HStack(spacing: 0) {
            // Left tab bar
            VStack(alignment: .leading, spacing: 2) {
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: tab.icon)
                                .frame(width: 16)
                            Text(tab.rawValue)
                        }
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .background(
                            selectedTab == tab
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6)
                        )
                        .foregroundStyle(selectedTab == tab ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(width: 130)
            .padding(.vertical, 16)
            .padding(.horizontal, 8)

            Divider()

            // Content
            Group {
                switch selectedTab {
                case .general:
                    GeneralSettingsTab()
                case .ai:
                    AISettingsTab()
                case .voice:
                    VoiceSettingsTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 640, height: 580)
    }
}

// MARK: - General Tab

struct GeneralSettingsTab: View {
    @ObservedObject private var updater = AppUpdater.shared
    @State private var dialogueFolder: URL = DocumentManager.dialogueFolder

    var body: some View {
        Form {
            // Software Update
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Software Update")
                        .font(.headline)

                    HStack(spacing: 4) {
                        Text("Current version: \(updater.currentAppVersion())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if updater.isDevBuild {
                            Text("(dev build)")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                updateStatusView

                HStack {
                    Spacer()
                    updateActionButtons
                }
            }

            // Voice Command
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Voice Command")
                        .font(.headline)

                    Text("Press and hold this keyboard shortcut to activate voice command mode. The shortcut works globally, even when the app is in the background.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                KeyboardShortcuts.Recorder("Shortcut:", name: .voiceCommand)
            }

            // Dialogue Folder
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Dialogue Folder")
                        .font(.headline)

                    Text("Meetings and Notes are stored inside this folder.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                        Text(dialogueFolder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button("Change...") {
                            chooseDialogueFolder()
                        }
                        .buttonStyle(.bordered)

                        Button("Open in Finder") {
                            NSWorkspace.shared.open(dialogueFolder)
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Folder Picker

    private func chooseDialogueFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Dialogue Folder"
        panel.message = "Select the folder where Meetings and Notes will be stored."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = dialogueFolder

        guard panel.runModal() == .OK, let url = panel.url else { return }
        DocumentManager.setDialogueFolder(url)
        dialogueFolder = url
    }

    // MARK: - Update Views

    @ViewBuilder
    private var updateStatusView: some View {
        switch updater.state {
        case .idle:
            EmptyView()

        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .available(let version, let notes, _):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Version \(version) is available")
                        .fontWeight(.medium)
                }

                if !notes.isEmpty && !notes.starts(with: "**Full Changelog**") {
                    Text(notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                }
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text("Downloading update...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .readyToInstall:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Download complete. Ready to install.")
                    .font(.caption)
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing update...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .failed(let message):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

        case .upToDate:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("You're up to date.")
                    .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var updateActionButtons: some View {
        switch updater.state {
        case .idle, .upToDate, .failed:
            Button("Check for Updates") {
                Task { await updater.checkForUpdates() }
            }
            .buttonStyle(.bordered)

        case .checking:
            EmptyView()

        case .available:
            HStack(spacing: 8) {
                Button("Later") {
                    updater.dismissUpdate()
                }
                .buttonStyle(.bordered)

                Button("Download Update") {
                    Task { await updater.downloadUpdate() }
                }
                .buttonStyle(.borderedProminent)
            }

        case .downloading:
            Button("Cancel") {
                updater.cancelDownload()
            }
            .buttonStyle(.bordered)

        case .readyToInstall:
            Button("Install and Relaunch") {
                Task { await updater.installUpdate() }
            }
            .buttonStyle(.borderedProminent)

        case .installing:
            EmptyView()
        }
    }
}

// MARK: - AI Tab

struct AISettingsTab: View {
    @State private var apiKey: String = ""
    @State private var hasExistingKey: Bool = false
    @State private var showKey: Bool = false
    @State private var saveStatus: SaveStatus = .idle
    @State private var testStatus: TestStatus = .idle
    @State private var endpointURL: String = UserDefaults.standard.string(forKey: "aiEndpoint") ?? "https://localhost:8000/v1"
    @State private var agentId: String = UserDefaults.standard.string(forKey: "chatAgentId") ?? "chieko"

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

                // Endpoint URL
                HStack {
                    TextField("Endpoint URL", text: $endpointURL, prompt: Text("https://your-server.example.com/v1"))
                        .textFieldStyle(.roundedBorder)
                    Text("Base URL ending in /v1")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                // Agent ID
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

                // Actions
                HStack {
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
        }
        .formStyle(.grouped)
        .onAppear { loadExistingKey() }
    }

    // MARK: - Actions

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

// MARK: - Voice Tab

struct VoiceSettingsTab: View {
    @AppStorage("diarizationMode") private var diarizationMode: DiarizationMode = .pyannoteStreaming
    @AppStorage("selectedInputDeviceUID") private var selectedInputDeviceUID: String = ""
    @State private var availableInputDevices: [AudioDevice] = []

    @State private var similarityThreshold: Double = {
        let v = UserDefaults.standard.double(forKey: "voiceID_similarityThreshold")
        return v == 0 ? 0.65 : v
    }()

    @State private var embeddingMatchThreshold: Double = {
        let v = UserDefaults.standard.double(forKey: "embeddingMatchThreshold")
        return v == 0 ? 0.40 : v
    }()

    @State private var voices: [VoiceEmbedding] = []
    @State private var showEnrollSheet = false
    @ObservedObject private var preloader = ModelPreloader.shared

    var body: some View {
        Form {
            // Diarization Engine
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

            // Microphone
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Microphone")
                        .font(.headline)

                    Text("Select which microphone to use for meeting recordings and voice enrollment. This setting is independent of the system default input device.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker("Input Device", selection: micPickerBinding) {
                    Text("System Default")
                        .tag("")
                    ForEach(availableInputDevices) { device in
                        Text(device.name)
                            .tag(device.uid)
                    }
                }
                .onAppear {
                    refreshInputDevices()
                }
            }

            // Voice ID Thresholds
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
                        Text("Recognition Threshold")
                        Spacer()
                        Text(String(format: "%.2f", similarityThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $similarityThreshold, in: 0.50...0.90, step: 0.01)
                        .onChange(of: similarityThreshold) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "voiceID_similarityThreshold")
                        }
                    Text("Minimum cosine similarity (0 = unrelated, 1 = identical) for a voice to match an enrolled speaker. Applied consistently in both diarization modes: directly in Sortformer, and converted to the equivalent cosine distance for Pyannote's SpeakerManager.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Embedding Match Threshold")
                        Spacer()
                        Text(String(format: "%.2f", embeddingMatchThreshold))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $embeddingMatchThreshold, in: 0.20...0.80, step: 0.01)
                        .onChange(of: embeddingMatchThreshold) { _, newValue in
                            UserDefaults.standard.set(newValue, forKey: "embeddingMatchThreshold")
                        }
                    Text("Minimum cosine similarity for attributing an unidentified segment to a speaker based on voice embedding comparison. Lower values are more permissive; higher values require a closer voice match. Used when diarization gaps leave segments temporarily unattributed.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            // Speaker Profiles
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
                        HStack(spacing: 10) {
                            // Color swatch
                            Menu {
                                ForEach(0..<CatppuccinSpeaker.palette.count, id: \.self) { idx in
                                    Button {
                                        VoiceID.shared.setColor(userID: voice.userID, colorIndex: idx)
                                        loadVoices()
                                    } label: {
                                        HStack {
                                            Circle()
                                                .fill(CatppuccinSpeaker.palette[idx])
                                                .frame(width: 10, height: 10)
                                            Text(CatppuccinSpeaker.paletteNames[idx])
                                            if voice.colorIndex == idx {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Circle()
                                    .fill(voice.colorIndex.map { CatppuccinSpeaker.palette[$0 % CatppuccinSpeaker.palette.count] } ?? Color.gray)
                                    .frame(width: 16, height: 16)
                                    .overlay(
                                        Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                                    )
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 20)
                            .help("Change color")

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
        .onAppear { loadVoices() }
        .onReceive(VoiceID.shared.voicesDidChange) { _ in
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

    // MARK: - Helpers

    private var micPickerBinding: Binding<String> {
        Binding<String>(
            get: {
                let saved = selectedInputDeviceUID
                if saved.isEmpty { return "" }
                if availableInputDevices.contains(where: { $0.uid == saved }) {
                    return saved
                }
                return ""
            },
            set: { newValue in
                selectedInputDeviceUID = newValue
            }
        )
    }

    private func refreshInputDevices() {
        let streamer = AudioInputStreamer()
        availableInputDevices = streamer.listInputDevices()
    }

    private func loadVoices() {
        voices = VoiceID.shared.allEnrolledVoices()
    }
}
