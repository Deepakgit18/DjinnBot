import MenuBarExtraAccess
import SwiftUI

@main
struct DialogueApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var documentManager = DocumentManager.shared
    @StateObject private var appState = AppState.shared

    /// Controls the menubar dropdown presentation.
    @State private var isMenuPresented = false

    var body: some Scene {
        // MARK: - Main Window

        WindowGroup {
            ContentView()
                .environmentObject(documentManager)
                .environmentObject(appState)
                .onAppear {
                    if #available(macOS 26.0, *) {
                        ModelPreloader.shared.preload()
                        _ = VoiceCommandManager.shared
                    }
                    AppUpdater.shared.startPeriodicChecks()
                }
        }

        // MARK: - Menu Bar Extra

        MenuBarExtra("Dialogue", systemImage: "waveform") {
            Button("Start Meeting") {
                isMenuPresented = false
                showMainWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    appState.openMeetingRecorder()
                    NotificationCenter.default.post(name: .toggleRecording, object: nil)
                }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Button("Show Dialogue") {
                isMenuPresented = false
                showMainWindow()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit Dialogue") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .menuBarExtraAccess(isPresented: $isMenuPresented)
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    Task { await AppUpdater.shared.checkForUpdates() }
                    // Also open Settings so the user can see results.
                    if #available(macOS 14.0, *) {
                        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                    } else {
                        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                    }
                }
            }

            CommandGroup(replacing: .newItem) {
                Button("New Document") {
                    appState.createAndOpenNewDocument()
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    appState.saveCurrentDocument()
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            CommandGroup(after: .textEditing) {
                Button("Find") {
                    NotificationCenter.default.post(name: .activateSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Find in All Documents") {
                    NotificationCenter.default.post(name: .activateGlobalSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            CommandMenu("Meeting") {
                Button("Toggle Recording") {
                    NotificationCenter.default.post(name: .toggleRecording, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Speaker Profiles...") {
                    NotificationCenter.default.post(name: .openSpeakerProfiles, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            CommandMenu("AI Chat") {
                Button("Toggle Chat Panel") {
                    NotificationCenter.default.post(name: .toggleChatPanel, object: nil)
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("New Chat Session") {
                    NotificationCenter.default.post(name: .newChatSession, object: nil)
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Divider()

                Button("Close Chat") {
                    NotificationCenter.default.post(name: .closeChatPanel, object: nil)
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
        }

        Settings {
            SettingsView()
        }
    }

    // MARK: - Window Management

    private func showMainWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Try the stored reference first.
        if let window = appDelegate.mainWindow, window.isVisible || !window.isReleasedWhenClosed {
            window.makeKeyAndOrderFront(nil)
            return
        }

        // Scan all windows for one that's still alive.
        for window in NSApplication.shared.windows where !(window is NSPanel) {
            guard !window.className.contains("StatusBar") else { continue }
            window.makeKeyAndOrderFront(nil)
            return
        }
    }
}

// MARK: - App Delegate

/// Keeps the app alive when the last window is closed (stays in menubar).
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Reference to the main window so we can reshow it.
    var mainWindow: NSWindow?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Capture the main window once it appears.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowBecameKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    @objc private func handleWindowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              !(window is NSPanel),
              !window.className.contains("StatusBar") else { return }
        mainWindow = window
    }

    /// Called when the user clicks the dock icon (or re-activates the app).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            mainWindow?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

// MARK: - App State

/// Central app state managing the currently open document.
final class AppState: ObservableObject {
    static let shared = AppState()

    enum DetailScreen {
        case home
        case editor
        case meetingRecorder
        case meetingDetail(SavedMeeting)
        case meetingDetailHighlight(SavedMeeting, UUID)
        case searchResults

        var isHome: Bool {
            if case .home = self { return true }
            return false
        }
        var isEditor: Bool {
            if case .editor = self { return true }
            return false
        }
        var isSearchResults: Bool {
            if case .searchResults = self { return true }
            return false
        }
    }

    @Published var activeScreen: DetailScreen = .home

    /// The last search query — used for "Back to search" navigation.
    @Published var lastSearchQuery: String?

    var showHome: Bool {
        get { activeScreen.isHome }
        set { if newValue { activeScreen = .home } }
    }

    @Published var currentDocument: BlockNoteDocument = .init()
    @Published var currentFileURL: URL?

    private init() {}

    func navigateHome() {
        saveCurrentDocument()
        lastSearchQuery = nil
        activeScreen = .home
    }

    func openMeetingRecorder() {
        saveCurrentDocument()
        lastSearchQuery = nil
        activeScreen = .meetingRecorder
    }

    func openMeeting(_ meeting: SavedMeeting) {
        saveCurrentDocument()
        lastSearchQuery = nil
        activeScreen = .meetingDetail(meeting)
    }

    /// Navigate to a meeting and highlight a specific transcript entry (from search).
    func openMeetingHighlight(_ meeting: SavedMeeting, entryID: UUID) {
        saveCurrentDocument()
        // Don't clear lastSearchQuery — we want "Back to search" to appear
        activeScreen = .meetingDetailHighlight(meeting, entryID)
    }

    func showSearchResults() {
        saveCurrentDocument()
        activeScreen = .searchResults
    }

    func returnToSearch() {
        activeScreen = .searchResults
    }

    /// Navigate to a document from search — preserves lastSearchQuery for "back" nav.
    func openDocumentFromSearch(at url: URL) {
        saveCurrentDocument()
        guard let data = try? Data(contentsOf: url),
              let file = try? BlockNoteFile.fromJSON(data) else { return }
        currentDocument = BlockNoteDocument(file: file)
        currentFileURL = url
        // Don't clear lastSearchQuery — we want "Back to search" to appear
        activeScreen = .editor
    }

    func openDocument(at url: URL) {
        saveCurrentDocument()

        guard let data = try? Data(contentsOf: url),
              let file = try? BlockNoteFile.fromJSON(data) else {
            print("[Dialogue] Failed to open document at \(url.path)")
            return
        }
        currentDocument = BlockNoteDocument(file: file)
        currentFileURL = url
        activeScreen = .editor
    }

    func createAndOpenNewDocument(in folder: URL? = nil) {
        if let url = DocumentManager.shared.createNewDocument(in: folder) {
            openDocument(at: url)
        }
    }

    func saveCurrentDocument() {
        guard let url = currentFileURL,
              let data = try? currentDocument.file.toJSON() else { return }
        try? data.write(to: url, options: .atomic)
        currentDocument.hasUnsavedChanges = false
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let toggleChatPanel = Notification.Name("dialogue.toggleChatPanel")
    static let newChatSession = Notification.Name("dialogue.newChatSession")
    static let closeChatPanel = Notification.Name("dialogue.closeChatPanel")
    static let toggleRecording = Notification.Name("dialogue.toggleRecording")
    static let openSpeakerProfiles = Notification.Name("dialogue.openSpeakerProfiles")
    static let activateSearch = Notification.Name("dialogue.activateSearch")
    static let activateGlobalSearch = Notification.Name("dialogue.activateGlobalSearch")
    static let showChatPanel = Notification.Name("dialogue.showChatPanel")
}
