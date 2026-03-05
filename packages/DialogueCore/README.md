# DialogueCore

Shared business logic for the Dialogue app, extracted as a reusable Swift Package supporting **macOS 14+** and **iOS 17+**.

## Structure

```
Sources/DialogueCore/
├── Models/           Data models (BlockNoteFile, ChatModels, TaggedSegment, etc.)
├── Services/         Networking, storage, search (KeychainManager, MeetingStore, etc.)
├── Editor/           Editor bridge protocol (BridgeMessages)
├── Recording/        Audio recording & merge (MergeEngine, MixedWAVRecorder, MeetingPlayer)
├── Pipelines/        Realtime ASR+diarization pipelines (RealtimePipeline)
├── Transcription/    Speech recognition (RealtimeTranscriptionManager)
├── Diarization/      Speaker identification (VoiceID, RealtimeDiarizationManager)
└── Refinement/       Post-recording improvement (PostRecordingRefiner, ModelPreloader)
```

## Dependencies

- **FluidAudio** — On-device speaker diarization (Pyannote + WeSpeaker, Sortformer)
- **SFBAudioEngine** — Audio playback and Opus encoding
- **FuzzyMatch** — Fuzzy text search for notes and transcripts

## What stays in the platform app

Platform-specific code remains in each app target:

- **macOS**: AppKit UI, ScreenCaptureKit audio capture, Core Audio HAL device management, menu bar, keyboard shortcuts, permissions (Accessibility, Screen Recording), app updater
- **iOS** (future): UIKit/SwiftUI UI, microphone capture via AVAudioSession, iOS permissions

## Adding an iOS app

1. Create a new iOS app target (e.g. `apps/ios/Dialogue/`)
2. Add `Packages/DialogueCore` as a local package dependency
3. `import DialogueCore` to access all shared types
4. Implement platform-specific pieces:
   - Audio capture (AVAudioSession instead of Core Audio HAL)
   - Permissions (iOS microphone/speech permissions)
   - UI (SwiftUI views, no AppKit)
   - The recording pipeline types (`RealtimePipeline`, `ModelPreloader`, etc.) work on iOS 26+ — they use `SpeechAnalyzer` and `FluidAudio` which both support iOS

## Platform availability

Most types work on macOS 14+ / iOS 17+. The recording pipeline requires macOS 26.0 / iOS 26.0 due to the `SpeechAnalyzer` API (`@available(macOS 26.0, iOS 26.0, *)`).
