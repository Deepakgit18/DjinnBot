import DialogueCore
import SwiftUI

/// Minimal settings for the iOS app: API key and endpoint configuration.
struct SettingsTab: View {
    @AppStorage("aiEndpoint") private var endpoint = "https://localhost:8000/v1"
    @AppStorage("chatAgentId") private var agentId = "chieko"
    @State private var apiKey = ""
    @State private var showingSavedToast = false

    var body: some View {
        NavigationStack {
            Form {
                Section("API Configuration") {
                    LabeledContent("Endpoint") {
                        TextField("https://...", text: $endpoint)
                            .textContentType(.URL)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Agent ID") {
                        TextField("Agent", text: $agentId)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("API Key") {
                        SecureField("sk-...", text: $apiKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .multilineTextAlignment(.trailing)
                    }

                    Button("Save API Key") {
                        guard !apiKey.isEmpty else { return }
                        try? KeychainManager.shared.saveAPIKey(apiKey)
                        showingSavedToast = true
                        apiKey = ""
                    }
                    .disabled(apiKey.isEmpty)
                }

                Section("Storage") {
                    LabeledContent("Dialogue Folder") {
                        Text(DocumentManager.dialogueFolder.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    LabeledContent("Meetings") {
                        Text("\(MeetingStore.shared.meetings.count)")
                    }
                }

                Section("About") {
                    LabeledContent("Platform", value: "iOS")
                    LabeledContent("DialogueCore", value: "Shared Package")
                    LabeledContent("API Key Set", value: KeychainManager.shared.hasAPIKey ? "Yes" : "No")
                }
            }
            .navigationTitle("Settings")
            .overlay {
                if showingSavedToast {
                    toastOverlay
                }
            }
        }
    }

    private var toastOverlay: some View {
        Text("API Key Saved")
            .font(.subheadline.bold())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { showingSavedToast = false }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
    }
}
