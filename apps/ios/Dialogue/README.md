# Dialogue iOS

Minimal iOS companion app for testing **DialogueCore** end-to-end on iPhone/iPad.

## Requirements

- Xcode 26.0+ (with iOS 26.0 SDK)
- Physical iOS device (ReplayKit broadcast requires a real device)

## How to Build and Run

1. Open `Dialogue.xcodeproj` in Xcode.
2. Select your device as the run destination.
3. Set your development team under **Signing & Capabilities** for all three targets:
   - `Dialogue` (main app)
   - `BroadcastSetupUI`
   - `BroadcastUpload`
4. Build and run (Cmd+R).

The Xcode project is generated from `project.yml` using [XcodeGen](https://github.com/yonaskolb/XcodeGen). To regenerate after changes:

```
brew install xcodegen   # if not installed
xcodegen generate
```

## Permissions

- **Microphone**: Required for meeting recording. The app shows a clean permission screen on first launch. Grant it.
- **Screen Recording**: Handled automatically by the ReplayKit broadcast picker (Apple's standard system UI).

## What to Test

### Recording (Record tab)
- Tap the broadcast picker button to start a ReplayKit screen recording.
- The extension captures `.audioApp` (system audio) and `.audioMic` (microphone) separately.
- Audio chunks are written to an App Group shared container.
- When you stop the broadcast, the main app saves the meeting to `MeetingStore`.
- No live transcription on iOS — post-recording refinement handles that.

### Meetings (Meetings tab)
- Lists all saved meetings from `MeetingStore.shared`.
- Tap a meeting to see its details and transcript.
- Use "Ingest & Summarize" to test the `MeetingIngestService` pipeline (requires a running Djinn server).

### Chat (Chat tab)
- Full `ChatSessionManager` integration.
- Type a message to create a session and chat with the Djinn backend.
- Requires API key (set in Settings).

### Settings (Settings tab)
- Configure API endpoint, agent ID, and API key.
- All stored via `UserDefaults` / `KeychainManager` from DialogueCore.

## Architecture

```
apps/ios/Dialogue/
├── Dialogue/                  # Main app target
│   ├── DialogueApp.swift      # @main entry, permission check
│   ├── Services/
│   │   ├── MicrophonePermissionManager.swift
│   │   └── RecordingCoordinator.swift
│   └── UI/
│       ├── MainView.swift     # Tab container
│       ├── RecordingTab.swift  # RPSystemBroadcastPickerView + status
│       ├── MeetingsTab.swift   # Meeting list + detail
│       ├── ChatTab.swift       # Chat interface
│       ├── SettingsTab.swift   # API config
│       └── MicrophonePermissionView.swift
├── BroadcastSetupUI/          # Broadcast Setup UI Extension
│   └── BroadcastSetupViewController.swift
├── BroadcastUpload/           # Broadcast Upload Extension (SampleHandler)
│   └── SampleHandler.swift
└── project.yml                # XcodeGen spec
```

The app depends **only** on `DialogueCore` (via local package at `../../../Packages/DialogueCore`). All business logic — meeting storage, chat, document management, ingest, keychain — comes from the shared package.

## App Group

The main app and `BroadcastUpload` extension share data via the App Group `group.bot.djinn.dialogue`. You must enable this capability for both targets in your provisioning profile.
