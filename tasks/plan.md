# Implementation Plan: Ivy macOS Assistant

> Historical v1 plan. The Phase 5–7 status table below predates the current implementation. Use [remaining.md](remaining.md) and [the v1.1 roadmap](../docs/roadmap/README.md) for current work.

## Overview
Ivy is a native macOS menu bar assistant built with Swift and SwiftUI that connects directly to the Gemini 3.8 Flash REST API and Gemini Multimodal Live WebSocket API. Ivy possesses a distinct sarcastic persona, handles conversational back-and-forth, executes local macOS tools under strict user-confirmation safety gates, and provides real-time bidirectional voice conversations with "Hey Ivy" interruption and global push-to-talk.

---

## Phase-by-Phase Roadmap & Status

| Phase | Milestone | Focus | Status |
|---|---|---|---|
| **Phase 1** | **Core Loop** | Text-only menu bar app, Gemini REST client, Ivy sarcastic persona, turn history | **Complete** (100%) |
| **Phase 2** | **Tool Layer** | Function calling declarations, execution of AppleScript, shell, apps, calendar, files | **Complete** (100%) |
| **Phase 3** | **Confirmation Gate** | Safe vs Risky tool classification, in-character confirmation modal before execution | **Complete** (100%) |
| **Phase 4** | **Voice In & Out (Live)** | ElevenLabs TTS, Gemini Live WebSocket voice, "Hey Ivy" interruption, global hotkey push-to-talk | **Complete** (100%) |
| **Phase 5** | **Persistence & Settings** | macOS Keychain for API keys, JSON session history persistence across restarts | **Next Up** |
| **Phase 6** | **Permissions & Sandboxing** | Entitlements, Info.plist privacy descriptions, runtime permission recovery | Scheduled |
| **Phase 7** | **Portfolio Polish** | Dynamic status menu bar icons, notarization scripts, architecture diagram, demo GIF | Scheduled |

---

## Architecture Summary (Phases 1–4 Completed)

### 1. SPM Target Structure
- `IvyCore`: Pure Swift domain library containing models, REST client, live WebSocket client, turn management, tool execution, safety gates, audio capture/playback abstractions, and Ivy persona. Enables headless unit testing (`swift test`) without spinning up the macOS UI harness.
- `Ivy`: Native macOS executable target containing `IvyApp` (`MenuBarExtra`), popovers, views, and system driver adapters (`SystemGlobalHotkeyManager`, `SystemAudioCapture`, `SystemLiveAudioPlayer`, `SystemWakeWordDetector`).

### 2. Swift 6 Strict Concurrency
- Compiled with `-swiftLanguageMode(.v6)` and strict concurrency checking. All models and clients conform to `Sendable`. UI state machines (`IvyBrain`, `VoicePlaybackManager`, `GeminiLiveVoiceCoordinator`) are `@MainActor` isolated. Non-UI state utilizes `OSAllocatedUnfairLock`.

### 3. Voice & Audio Architecture (Phase 4)
- **ElevenLabs TTS**: `ElevenLabsSpeechSynthesizer` communicating with ElevenLabs REST endpoint for reading chat messages aloud with custom voice (`GO7CKs5ENqIU2xXLHrtL`) or default fallback (`EXAVITQu4vr4xnSDxMaL`). Managed by `VoicePlaybackManager`.
- **Gemini Live Multimodal Voice**: `GeminiLiveClient` bidirectional WebSocket client running over `wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1alpha.GenerativeService.BidiGenerateContent`. Real-time audio streaming at 16kHz PCM mono with prebuilt voice (`Kore`).
- **Interruption System**: `SystemWakeWordDetector` with `WakePhraseMatcher` monitoring speech for "Hey Ivy" variants during assistant playback, immediately stopping audio and clearing pending audio buffers.
- **Push-to-Talk Hotkey**: `SystemGlobalHotkeyManager` using Carbon Event Manager registering `⌘ + ⇧ + Space` (`Command + Shift + Space`) with zero Accessibility permission requirements.
- **Voice Tool Calling**: `GeminiLiveVoiceCoordinator` routes live tool calls through `SafetyGate` and `ToolDispatcher`, rendering in-character confirmation cards in the popover and returning `toolResponse` over the WebSocket.

---

## Phase 5: Persistence & Settings (Detailed Implementation Plan)

### Objective
Provide secure macOS Keychain storage for API keys (Gemini, ElevenLabs) and persist conversation history to disk (`~/Library/Application Support/Ivy/history.json`) across application restarts.

### Phase 5.1: macOS Keychain Storage
- **Protocol**: `KeychainStorageProtocol` defining `save(key:value:service:)`, `get(key:service:)`, `delete(key:service:)`.
- **Implementations**:
  - `SystemKeychainStorage`: Direct Security framework integration using `SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, `SecItemDelete` under service `com.ivy.assistant`.
  - `MockKeychainStorage`: In-memory thread-safe dictionary for 100% offline unit testing.
- **Keys**:
  - `gemini_api_key`: Gemini REST and Live API key.
  - `elevenlabs_api_key`: ElevenLabs TTS key.
  - `elevenlabs_voice_id`: Custom voice ID preference.
- **Fallback Hierarchy**: Keychain storage -> Process environment (`GEMINI_API_KEY`, `ELEVENLABS_API_KEY`, `ELEVENLABS_VOICE_ID`) -> In-memory popover input.

### Phase 5.2: Session History Persistence
- **Protocol**: `HistoryStorageProtocol` with `loadHistory() async throws -> [ChatMessage]` and `saveHistory(_ messages: [ChatMessage]) async throws`.
- **Implementations**:
  - `JSONHistoryStorage`: Stores pretty-printed JSON in `~/Library/Application Support/Ivy/history.json`.
  - `MockHistoryStorage`: In-memory implementation for unit testing.
- **Features**:
  - Atomic writing via temporary file to prevent corruption on crash or abrupt quit.
  - Exclude transient errors and unconfirmed states from disk.
  - Automatic load on `IvyBrain.init()` and debounced save on turn append.
  - "Clear History" button purges the persisted file and resets memory.

### Phase 5.3: Popover Settings UI
- Expand `settingsBar` in `IvyPopoverView` with:
  - Keychain persistence indicator (Secure / Saved in Keychain).
  - Clear conversation history button with confirmation.
  - ElevenLabs voice selector / custom Voice ID input field.

---

## Phase 6 & 7 Roadmap Preview

- **Phase 6: Permissions & Sandboxing**: Hardened runtime entitlements, Info.plist embedded descriptions, graceful handling for camera/mic/AppleScript denials, permission repair guidance UI.
- **Phase 7: Portfolio Polish**: Dynamic menu bar status icons (idle, thinking, speaking, listening, error), notarization scripts, architecture diagrams, GitHub documentation, and demo GIF.

---

## Constraints & Quality Floor
- All code strictly adheres to `CONSTRAINTS.md`.
- Zero secrets committed to source.
- Swift 6 strict concurrency (`-strict-concurrency=complete`) with zero warnings.
- ≥ 80% unit test coverage on new files.
