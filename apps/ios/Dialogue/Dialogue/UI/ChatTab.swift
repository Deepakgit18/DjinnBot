import DialogueCore
import SwiftUI

/// Minimal chat interface for testing DialogueCore's ChatSessionManager.
struct ChatTab: View {
    @EnvironmentObject var chatManager: ChatSessionManager
    @State private var messageText = ""
    @State private var showingAPIKeyAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Messages
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if let session = chatManager.activeSession {
                                ForEach(session.messages, id: \.id) { message in
                                    ChatBubble(message: message)
                                        .id(message.id)
                                }
                            } else {
                                ContentUnavailableView(
                                    "No Active Chat",
                                    systemImage: "bubble.left.and.bubble.right",
                                    description: Text("Type a message to start a new chat session.")
                                )
                            }
                        }
                        .padding()
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .onChange(of: chatManager.activeSession?.messages.count) {
                        if let last = chatManager.activeSession?.messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                // Input bar
                HStack(spacing: 12) {
                    TextField("Message...", text: $messageText, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...5)
                        .padding(10)
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 12))

                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                    }
                    .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .navigationTitle("Chat")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        chatManager.createNewSession()
                    } label: {
                        Image(systemName: "plus.bubble")
                    }
                    .disabled(chatManager.isStartingSession)
                }
            }
            .alert("API Key Required", isPresented: $showingAPIKeyAlert) {
                Button("OK") {}
            } message: {
                Text("Set your API key in the Settings tab to use chat.")
            }
        }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        guard KeychainManager.shared.hasAPIKey else {
            showingAPIKeyAlert = true
            return
        }

        messageText = ""
        chatManager.sendMessageWhenReady(text)
    }
}

// MARK: - Chat Bubble

struct ChatBubble: View {
    @ObservedObject var message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: .leading, spacing: 4) {
                if message.role == .thinking {
                    Label("Thinking", systemImage: "brain")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if message.role == .toolCall {
                    Label(message.toolName ?? "Tool", systemImage: "wrench")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
                Text(message.content)
                    .font(.body)
                    .textSelection(.enabled)
            }
            .padding(12)
            .background(bubbleBackground, in: RoundedRectangle(cornerRadius: 16))
            .foregroundStyle(message.role == .user ? .white : .primary)

            if message.role != .user { Spacer(minLength: 60) }
        }
    }

    private var bubbleBackground: some ShapeStyle {
        switch message.role {
        case .user:
            return AnyShapeStyle(.tint)
        case .error:
            return AnyShapeStyle(Color.red.opacity(0.15))
        case .thinking:
            return AnyShapeStyle(Color.purple.opacity(0.1))
        default:
            return AnyShapeStyle(.fill.tertiary)
        }
    }
}
