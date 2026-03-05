import DialogueCore
import Combine
import SwiftUI

/// The main content view for the app window.
/// Shows a sidebar with the document library and the BlockNote editor.
/// The meeting recorder is accessible via a toolbar button in the title bar
/// and a collapsible live transcript banner below the toolbar.
struct ContentView: View {
    @EnvironmentObject var documentManager: DocumentManager
    @EnvironmentObject var appState: AppState
    
    // MARK: - Meeting Recorder (app-wide)
    
    /// Shared recorder controller, available from any screen.
    /// Wrapped in an availability-checked helper so the @StateObject
    /// can live here without polluting the rest of the view.
    @StateObject private var recorderHolder = RecorderHolder()
    
    // MARK: - Phase 3: Floating Chat
    
    /// Mouse proximity detector for the floating chat toolbar.
    @StateObject private var bottomEdgeDetector = BottomEdgeDetector()
    
    /// Mouse proximity detector for auto-revealing the sidebar.
    @StateObject private var sidebarEdgeDetector = SidebarEdgeDetector()
    
    /// Controls sidebar visibility for NavigationSplitView.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    
    /// Whether the floating chat toolbar is visible.
    @State private var chatToolbarVisible = false

    // MARK: - Search State

    /// Whether the toolbar search bar is expanded.
    @State private var isSearchActive = false
    /// Current search query text.
    @State private var searchQuery = ""
    /// Cached search results (persisted while navigating away).
    @State private var searchResults: [SearchResult] = []
    /// Search engine instance.
    @ObservedObject private var searchEngine = SearchEngine.shared

    /// In-document find state (Cmd+F when a note or transcript is open).
    @ObservedObject private var inDocSearch = InDocumentSearch.shared

    /// App updater for showing update-available banner.
    @ObservedObject private var updater = AppUpdater.shared

    // MARK: - Permission Onboarding

    /// Centralized permission manager — drives the onboarding overlay.
    @ObservedObject private var permissions = PermissionManager.shared

    /// Whether the permission onboarding screen is shown.
    /// Starts hidden — the `.task` check decides whether to show it.
    @State private var showPermissionOnboarding = false

    /// Prevents the main content from loading before the permission check completes.
    @State private var permissionCheckDone = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Update banner — full window width, above the split view
                if updater.showsBanner {
                    UpdateBanner()
                }

                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView(
                        documentManager: documentManager,
                        onSelectDocument: { url in
                            inDocSearch.dismiss()
                            appState.openDocument(at: url)
                        },
                        onSelectHome: {
                            inDocSearch.dismiss()
                            appState.navigateHome()
                        },
                        onSelectMeetingRecorder: {
                            inDocSearch.dismiss()
                            appState.navigateHome()
                        },
                        onSelectMeeting: { meeting in
                            inDocSearch.dismiss()
                            appState.openMeeting(meeting)
                        },
                        onDeleteMeeting: { meeting in
                            // Navigate away if viewing the deleted meeting
                            if case .meetingDetail(let current) = appState.activeScreen,
                               current == meeting {
                                appState.navigateHome()
                            }
                            MeetingStore.shared.deleteMeeting(meeting)
                        },
                        onRenameMeeting: { meeting, newName in
                            if let renamed = MeetingStore.shared.renameMeeting(meeting, to: newName) {
                                // If viewing the renamed meeting, update navigation to the new instance
                                if case .meetingDetail(let current) = appState.activeScreen,
                                   current == meeting {
                                    appState.openMeeting(renamed)
                                }
                            }
                        }
                    )
                } detail: {
                    VStack(spacing: 0) {
                        if #available(macOS 26.0, *),
                           let recorder = recorderHolder.recorder,
                           recorder.isRecording {
                            LiveTranscriptBanner(recorder: recorder)
                        }

                        detailContent
                    }
                }
                .navigationSplitViewStyle(.balanced)
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        ToolbarSearchBar(
                            isActive: $isSearchActive,
                            query: $searchQuery,
                            onCommit: performSearch
                        )
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if #available(macOS 26.0, *),
                           let recorder = recorderHolder.recorder {
                            RecordingToolbarButton(recorder: recorder)
                        }
                    }
                }

                // App-wide status footer (model download progress, recording prep, refinement)
                if #available(macOS 26.0, *), let recorder = recorderHolder.recorder {
                    StatusFooterView(
                        preparationStatus: recorder.preparationStatus,
                        isStarting: recorder.isStarting
                    )
                } else {
                    StatusFooterView()
                }
            }
            
            // Phase 3: Mouse tracking layer (invisible, covers the whole window)
            MouseTrackingView(detector: bottomEdgeDetector, sidebarDetector: sidebarEdgeDetector)
                .allowsHitTesting(false)
            
            // Phase 3: Floating chat toolbar (overlays at bottom)
            FloatingChatToolbar(
                detector: bottomEdgeDetector,
                isVisible: $chatToolbarVisible
            )

            // Permission onboarding overlay — covers everything until required
            // permissions are granted.
            if showPermissionOnboarding {
                PermissionOnboardingView {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        showPermissionOnboarding = false
                    }
                }
                .transition(.opacity)
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .onChange(of: bottomEdgeDetector.isNearBottom) { _, isNear in
            chatToolbarVisible = isNear
        }
        .onChange(of: sidebarEdgeDetector.isNearLeftEdge) { _, isNear in
            withAnimation(.easeInOut(duration: 0.2)) {
                if isNear {
                    columnVisibility = .all
                } else {
                    columnVisibility = .detailOnly
                }
            }
        }
        .onChange(of: columnVisibility) { oldValue, newValue in
            if !sidebarEdgeDetector.isNearLeftEdge {
                if newValue == .detailOnly {
                    sidebarEdgeDetector.userCollapsedSidebar()
                } else if newValue == .all {
                    sidebarEdgeDetector.userExpandedSidebar()
                }
            }
        }
        .onAppear {
            // Start on the Home screen; pre-load the most recent document
            // so it's ready when the user navigates to it.
            if appState.currentFileURL == nil && appState.activeScreen.isEditor {
                if let recent = documentManager.mostRecentDocument() {
                    appState.openDocument(at: recent)
                } else {
                    appState.createAndOpenNewDocument()
                }
            }
        }
        .task {
            // Check permissions on launch.
            await permissions.refreshAll()
            if permissions.allRequiredGranted {
                // All good — skip onboarding entirely.
                permissionCheckDone = true
            } else {
                // Show onboarding to walk the user through granting permissions.
                showPermissionOnboarding = true
                permissionCheckDone = true
            }
        }
        // Phase 3: Chat panel keyboard shortcuts
        .onReceive(NotificationCenter.default.publisher(for: .toggleChatPanel)) { _ in
            toggleChatToolbar()
        }
        .onReceive(NotificationCenter.default.publisher(for: .newChatSession)) { _ in
            ChatSessionManager.shared.createNewSession()
            bottomEdgeDetector.forceShow()
            chatToolbarVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .closeChatPanel)) { _ in
            bottomEdgeDetector.forceHide()
            chatToolbarVisible = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .showChatPanel)) { _ in
            if !chatToolbarVisible {
                bottomEdgeDetector.forceShow()
                chatToolbarVisible = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleRecording)) { _ in
            if #available(macOS 26.0, *) {
                guard let recorder = recorderHolder.recorder else { return }
                Task {
                    if recorder.isRecording {
                        await recorder.stop()
                    } else {
                        await recorder.start()
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .activateSearch)) { _ in
            handleCmdF()
        }
        .onReceive(NotificationCenter.default.publisher(for: .activateGlobalSearch)) { _ in
            withAnimation(.easeInOut(duration: 0.25)) {
                isSearchActive = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSpeakerProfiles)) { _ in
            // Speaker Profiles are now in the main Settings window.
            if #available(macOS 14.0, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
    }

    // MARK: - Detail Content

    @ViewBuilder
    private var detailContent: some View {
        VStack(spacing: 0) {
            // Back to search banner — shown when navigating from a search result
            if appState.lastSearchQuery != nil && !appState.activeScreen.isSearchResults {
                if let q = appState.lastSearchQuery {
                    BackToSearchBanner(query: q) {
                        appState.returnToSearch()
                    }
                    Divider()
                }
            }

            switch appState.activeScreen {
            case .home:
                HomeView()
                    .frame(minWidth: 500, minHeight: 400)
            case .editor:
                ZStack {
                    BlockNoteEditorView(document: appState.currentDocument)
                        .frame(minWidth: 500, minHeight: 400)

                    if inDocSearch.isActive {
                        VStack {
                            HStack {
                                Spacer()
                                InDocumentSearchBar(
                                    search: inDocSearch,
                                    onQueryChanged: { newQuery in
                                        BlockNoteEditorView.Coordinator.current?.findInPage(newQuery)
                                    },
                                    onNext: {
                                        BlockNoteEditorView.Coordinator.current?.findNext()
                                    },
                                    onPrevious: {
                                        BlockNoteEditorView.Coordinator.current?.findPrevious()
                                    },
                                    onDismiss: {
                                        BlockNoteEditorView.Coordinator.current?.clearFind()
                                    }
                                )
                                .padding(.trailing, 16)
                                .padding(.top, 8)
                            }
                            Spacer()
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .onChange(of: inDocSearch.isActive) { _, active in
                    if !active {
                        BlockNoteEditorView.Coordinator.current?.clearFind()
                    }
                }
            case .meetingRecorder:
                HomeView()
                    .frame(minWidth: 500, minHeight: 400)
                    .onAppear { appState.navigateHome() }
            case .meetingDetail(let meeting):
                MeetingDetailView(meeting: meeting)
                    .id(meeting.id)
                    .frame(minWidth: 500, minHeight: 400)
            case .meetingDetailHighlight(let meeting, let entryID):
                MeetingDetailView(meeting: meeting, highlightEntryID: entryID)
                    .id("\(meeting.id)-\(entryID)")
                    .frame(minWidth: 500, minHeight: 400)
            case .searchResults:
                SearchResultsView(
                    results: searchResults,
                    query: searchQuery,
                    onSelectNote: { url in
                        appState.openDocumentFromSearch(at: url)
                    },
                    onSelectTranscript: { meeting, entryID in
                        appState.openMeetingHighlight(meeting, entryID: entryID)
                    }
                )
                .frame(minWidth: 500, minHeight: 400)
            }
        }
    }
    
    // MARK: - Search

    /// Routes Cmd+F based on what's currently open.
    private func handleCmdF() {
        switch appState.activeScreen {
        case .editor, .meetingDetail, .meetingDetailHighlight:
            // Open in-document search overlay
            if inDocSearch.isActive {
                // Toggle off
                inDocSearch.dismiss()
            } else {
                inDocSearch.activate()
            }
        default:
            // No document open — activate the global toolbar search bar
            withAnimation(.easeInOut(duration: 0.25)) {
                isSearchActive = true
            }
        }
    }

    private func performSearch() {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            appState.lastSearchQuery = nil
            // If on search results with empty query, go home
            if appState.activeScreen.isSearchResults {
                appState.navigateHome()
            }
            return
        }

        // Reindex every time we search (fast enough for local data)
        searchEngine.reindex()
        searchResults = searchEngine.search(trimmed)
        appState.lastSearchQuery = trimmed
        appState.showSearchResults()
    }

    /// Dismiss search bar and clear search state when user explicitly closes.
    private func dismissSearch() {
        withAnimation(.easeInOut(duration: 0.25)) {
            isSearchActive = false
        }
        searchQuery = ""
        searchResults = []
        appState.lastSearchQuery = nil
        if appState.activeScreen.isSearchResults {
            appState.navigateHome()
        }
    }

    // MARK: - Phase 3: Chat Toggle
    
    private func toggleChatToolbar() {
        if chatToolbarVisible {
            bottomEdgeDetector.forceHide()
            chatToolbarVisible = false
        } else {
            bottomEdgeDetector.forceShow()
            chatToolbarVisible = true
        }
    }
}

// MARK: - RecorderHolder

/// Availability-safe wrapper so we can hold a @StateObject of
/// MeetingRecorderController (which requires macOS 26.0) inside
/// a view that doesn't itself require macOS 26.0.
@MainActor
final class RecorderHolder: ObservableObject {
    /// The underlying recorder, stored as `AnyObject` to avoid referencing
    /// the `@available(macOS 26.0, *)` type in the property signature.
    private let _recorder: AnyObject?

    /// Forwards objectWillChange from the inner controller so ContentView
    /// re-renders when recorder state (e.g. isRecording) changes.
    private var cancellable: AnyCancellable?

    /// Typed accessor. Returns nil on systems older than macOS 26.0.
    @available(macOS 26.0, *)
    var recorder: MeetingRecorderController? {
        _recorder as? MeetingRecorderController
    }

    init() {
        if #available(macOS 26.0, *) {
            let controller = MeetingRecorderController()
            _recorder = controller
            cancellable = controller.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        } else {
            _recorder = nil
            cancellable = nil
        }
    }
}

// MARK: - Update Banner

/// Catpuccin Mocha green: #a6e3a1
private let catpuccinGreen = Color(red: 166.0/255, green: 227.0/255, blue: 161.0/255)
/// Darker variant for text contrast
private let catpuccinGreenDark = Color(red: 30.0/255, green: 56.0/255, blue: 28.0/255)

/// Banner shown across the top of the detail pane for all active update states.
/// Provides clear feedback for every phase: available, downloading, ready, installing.
struct UpdateBanner: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        HStack(spacing: 8) {
            statusContent
            Spacer()
            actionButtons
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(catpuccinGreen)
        .animation(.easeInOut(duration: 0.2), value: updater.state)
    }

    @ViewBuilder
    private var statusContent: some View {
        switch updater.state {
        case .available(let version, _, _):
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(catpuccinGreenDark)
                .font(.caption)
            Text("Version \(version) is available")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(catpuccinGreenDark)

        case .downloading(let progress):
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .frame(width: 80)
                .tint(catpuccinGreenDark)
            Text("Downloading update... \(Int(progress * 100))%")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(catpuccinGreenDark)
                .monospacedDigit()

        case .readyToInstall:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(catpuccinGreenDark)
                .font(.caption)
            Text("Update downloaded. Ready to install.")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(catpuccinGreenDark)

        case .installing:
            // statusContent is empty — the action buttons area shows the spinner
            EmptyView()

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch updater.state {
        case .available:
            Button("Update Now") {
                Task { await updater.downloadUpdate() }
            }
            .font(.caption)
            .fontWeight(.medium)
            .buttonStyle(.plain)
            .foregroundStyle(catpuccinGreenDark)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(catpuccinGreenDark.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))

            Button {
                updater.dismissUpdate()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(catpuccinGreenDark.opacity(0.6))
            }
            .buttonStyle(.plain)

        case .downloading:
            Button("Cancel") {
                updater.cancelDownload()
            }
            .font(.caption)
            .buttonStyle(.plain)
            .foregroundStyle(catpuccinGreenDark.opacity(0.7))

        case .readyToInstall:
            Button {
                Task { await updater.installUpdate() }
            } label: {
                Label("Install and Relaunch", systemImage: "arrow.clockwise")
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(catpuccinGreenDark)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(catpuccinGreenDark.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))

        case .installing:
            // Brief flash before the app terminates and relaunches
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                    .tint(catpuccinGreenDark)
                Text("Restarting...")
                    .font(.caption)
                    .foregroundStyle(catpuccinGreenDark)
            }

        default:
            EmptyView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(DocumentManager.shared)
        .environmentObject(AppState.shared)
}
