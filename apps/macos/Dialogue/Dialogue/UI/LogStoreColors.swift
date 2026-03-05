import DialogueCore
import SwiftUI

// MARK: - Platform-specific Color extensions for LogStore

extension LogStore.Level {
    public var color: Color {
        switch self {
        case .debug: return .secondary
        case .info: return .primary
        case .warning: return .orange
        case .error: return .red
        }
    }
}

extension LogStore.Category {
    public var color: Color {
        switch self {
        case .audio: return .blue
        case .recording: return .red
        case .voiceEnrollment: return .purple
        case .voiceID: return .indigo
        case .pipeline: return .cyan
        case .diarization: return .teal
        case .app: return .gray
        case .meeting: return .green
        }
    }
}
