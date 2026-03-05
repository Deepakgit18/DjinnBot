import Foundation

// MARK: - Chat Message

/// A single message in a chat conversation.
/// Supports user, assistant, thinking, tool call, and error message types.
public final class ChatMessage: ObservableObject, Identifiable {
    public let id: String
    public let role: MessageRole
    public let createdAt: Date
    
    /// The text content — mutated during streaming for assistant messages.
    @Published public var content: String
    
    /// Whether the assistant is still streaming this message.
    @Published public var isStreaming: Bool
    
    /// Tool call metadata (only for .toolCall role).
    @Published public var toolName: String?
    @Published public var toolStatus: ToolCallStatus
    @Published public var toolResult: String?
    
    /// Thinking content (for extended thinking / reasoning tokens).
    @Published public var thinkingContent: String?
    
    /// Error message (only for .error role).
    public var errorMessage: String? {
        role == .error ? content : nil
    }
    
    public init(
        id: String = UUID().uuidString,
        role: MessageRole,
        content: String = "",
        isStreaming: Bool = false,
        toolName: String? = nil,
        toolStatus: ToolCallStatus = .idle,
        toolResult: String? = nil,
        thinkingContent: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.toolName = toolName
        self.toolStatus = toolStatus
        self.toolResult = toolResult
        self.thinkingContent = thinkingContent
        self.createdAt = createdAt
    }
}

// MARK: - Message Role

public enum MessageRole: String, Codable {
    case user
    case assistant
    case thinking
    case toolCall = "tool_call"
    case error
}

// MARK: - Tool Call Status

public enum ToolCallStatus: String {
    case idle
    case running
    case completed
    case failed
}

// MARK: - Chat Session

/// A local chat session, tracking conversation state and backend session ID.
public final class ChatSession: ObservableObject, Identifiable {
    public let id: String
    public let agentId: String
    public let createdAt: Date
    
    @Published public var title: String
    @Published public var model: String
    @Published public var status: SessionStatus
    @Published public var messages: [ChatMessage]
    
    /// Whether the assistant is currently generating a response.
    @Published public var isGenerating: Bool = false
    
    /// The assistant message ID returned by the backend (for completion tracking).
    public var pendingAssistantMessageId: String?
    
    public init(
        id: String,
        agentId: String,
        title: String = "New Chat",
        model: String = "anthropic/claude-sonnet-4",
        status: SessionStatus = .starting,
        messages: [ChatMessage] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.agentId = agentId
        self.title = title
        self.model = model
        self.status = status
        self.messages = messages
        self.createdAt = createdAt
    }
}

// MARK: - Session Status

public enum SessionStatus: String, Codable {
    case starting
    case running
    case ready
    case completed
    case failed
    case idle
    
    public var isActive: Bool {
        switch self {
        case .starting, .running, .ready:
            return true
        default:
            return false
        }
    }
}

// MARK: - SSE Event Types

/// Parsed SSE event from the Djinn backend session stream.
public enum DjinnSSEEvent: @unchecked Sendable {
    case connected(sessionId: String)
    case textDelta(text: String)
    case thinkingDelta(text: String)
    case toolStart(toolName: String, toolCallId: String?)
    case toolEnd(toolCallId: String?, result: String?)
    case stepEnd(result: String?, success: Bool)
    case turnEnd
    case responseAborted
    case sessionComplete
    case statusChanged(newStatus: String)
    case heartbeat
    case error(message: String)
    case unknown(type: String, data: [String: Any])
    
    /// Parse a raw SSE JSON data payload into a typed event.
    public static func parse(from jsonString: String) -> DjinnSSEEvent? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return nil
        }
        
        let eventData = json["data"] as? [String: Any] ?? [:]
        
        switch type {
        case "connected":
            let sessionId = json["session_id"] as? String ?? ""
            return .connected(sessionId: sessionId)
            
        case "text_delta", "delta", "output":
            // The engine sends "output" events with data.content or data.stream
            if let text = eventData["content"] as? String ?? eventData["stream"] as? String ?? eventData["text"] as? String ?? json["text"] as? String {
                return .textDelta(text: text)
            }
            // Fallback: check top-level content field
            if let content = json["content"] as? String {
                return .textDelta(text: content)
            }
            return nil
            
        case "thinking_delta", "thinking":
            // The engine sends "thinking" events with data.thinking or data.text
            if let text = eventData["thinking"] as? String ?? eventData["text"] as? String ?? json["thinking"] as? String {
                return .thinkingDelta(text: text)
            }
            return nil
            
        case "tool_start":
            let name = eventData["name"] as? String ?? eventData["tool_name"] as? String ?? "unknown"
            let callId = eventData["tool_call_id"] as? String ?? eventData["id"] as? String
            return .toolStart(toolName: name, toolCallId: callId)
            
        case "tool_end", "tool_result":
            let callId = eventData["tool_call_id"] as? String ?? eventData["id"] as? String
            let result = eventData["result"] as? String ?? eventData["output"] as? String
            return .toolEnd(toolCallId: callId, result: result)
            
        case "step_end":
            let result = eventData["result"] as? String
            let success = eventData["success"] as? Bool ?? true
            return .stepEnd(result: result, success: success)
            
        case "turn_end", "completed":
            return .turnEnd
            
        case "response_aborted":
            return .responseAborted
            
        case "session_complete":
            return .sessionComplete
            
        case "status_changed":
            let newStatus = eventData["newStatus"] as? String ?? json["status"] as? String ?? ""
            return .statusChanged(newStatus: newStatus)
            
        case "heartbeat", "ping":
            return .heartbeat
            
        case "error":
            let msg = eventData["message"] as? String ?? json["error"] as? String ?? "Unknown error"
            return .error(message: msg)
            
        default:
            return .unknown(type: type, data: eventData)
        }
    }
}

// MARK: - API Response Models

/// Response from POST /v1/agents/{agent_id}/chat/start
public struct StartChatResponse: Codable {
    public let sessionId: String
    public let status: String
    public let message: String?
}

/// Response from POST /v1/agents/{agent_id}/chat/{session_id}/message
public struct SendMessageResponse: Codable {
    public let status: String
    public let sessionId: String
    public let userMessageId: String?
    public let assistantMessageId: String?
}

/// Response from GET /v1/agents/{agent_id}/chat/{session_id}/status
public struct SessionStatusResponse: Codable {
    public let sessionId: String
    public let status: String
    public let exists: Bool?
    public let messageCount: Int?
    public let model: String?
    public let containerId: String?
    public let createdAt: Int?
    public let lastActivityAt: Int?
}

/// Response from GET /v1/agents/{agent_id}/chat/sessions
public struct ChatSessionListResponse: Codable {
    public let sessions: [ChatSessionInfo]
    public let total: Int
    public let has_more: Bool
}

public struct ChatSessionInfo: Codable {
    public let id: String
    public let agent_id: String
    public let status: String
    public let model: String
    public let created_at: Int
    public let last_activity_at: Int
    public let message_count: Int?
}

// MARK: - Model Provider Types

/// A configured model provider from GET /v1/settings/providers
public struct ModelProvider: Codable, Identifiable, Equatable {
    public let providerId: String
    public let name: String
    public let description: String
    public let configured: Bool
    public let enabled: Bool
    public let models: [ProviderModel]
    
    public var id: String { providerId }
}

/// A model available from a provider
public struct ProviderModel: Codable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String?
    public let reasoning: Bool?
}

/// Response from GET /v1/settings/providers/{providerId}/models
public struct ProviderModelsResponse: Codable {
    public let models: [ProviderModel]
    public let source: String // "live" or "static"
}
