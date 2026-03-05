import SwiftUI
import DialogueCore

@main
struct DialogueApp: App {
    @StateObject private var permissionManager = MicrophonePermissionManager()
    @StateObject private var chatManager = ChatSessionManager.shared
    @StateObject private var meetingStore = MeetingStore.shared

    var body: some Scene {
        WindowGroup {
            if permissionManager.micGranted {
                MainView()
                    .environmentObject(chatManager)
                    .environmentObject(meetingStore)
            } else if permissionManager.hasChecked {
                MicrophonePermissionView(manager: permissionManager)
            } else {
                // Checking permissions silently
                Color.clear
                    .task { await permissionManager.checkPermission() }
            }
        }
    }
}
