# Implementation Plan: Ivy macOS Assistant

> Companion launch (2026-10-08, build 20): Launch/reopen shows only the companion, with no Dock icon.
> Menu/companion actions open the full workspace on demand; first-run onboarding remains available.
> See [verification](companion-first-launch.md).

> Sidebar update (2026-10-08, build 19): Removed the background icon above Settings.
> Menu actions and closing the workspace retain background behavior.
> See [verification](sidebar-background-button-removal.md).

> Settings update (2026-10-08, build 18): Personality and profile answer length now use the same
> explanatory choice cards as Voice settings, preserving saved values and adaptive keyboard controls.
> See [verification](personality-settings-refresh.md).

> Voice recovery update (2026-10-08, build 17): Missing recognition and stalled model replies now
> close cleanly with a retry notice. Response deadlines renew on progress and exclude approval review,
> tool execution and completed reply playback. See [verification](voice-reply-recovery.md).

> App approval update (2026-10-08, build 16): The workspace shows the explanation and original
> action details in a scrollable review sheet with pinned Cancel / Do it controls. Companion layout
> stays unchanged. See [verification](app-approval-details.md).

> Companion text update (2026-10-08, build 15): Compact approval reasons and equal-sized decisions,
> larger left-aligned captions and clearer status type use adaptive opaque bubble surfaces. Existing
> confirmation and drag routing are retained. See [verification](companion-text-refresh.md).

> Voice UI update (2026-10-08, build 14): Pause tolerance, answer length and speaking pace now use
> explanatory choice cards with selected checkmarks, equal columns and narrow-window stacking.
> Saved values and voice behavior remain intact. See [verification](voice-settings-refresh.md).

> Task update (2026-10-08, build 13): New task and starter cards can prepare a goal while Ivy is busy.
> Existing work continues; sending waits until the active request ends. No concurrent execution or
> approval inheritance is added. See [verification](new-task-drafting.md).

> Background update (2026-10-08, build 12): Work in Background or closing the workspace leaves voice,
> chat and approved tasks running with companion progress/approval. The same pending approval hands
> off without an implicit Cancel; suggestions stay background until explicitly opening Ivy.
> See [verification](background-companion.md). This is resident-app behavior, not execution after Quit.

> Voice update (2026-10-08, build 11): A new PTT hold interrupts an old reply or pending approval
> and records a replacement question. Release submits once; Stop cancels an in-flight restart.
> See [PTT interruption verification](ptt-interrupt-reply.md).

> Chat update (2026-10-07): Tool/script cards stay under their triggering typed or voice question.
> Late voice chunks merge into the same request; display records remain session-only.
> See [chat ordering verification](chat-feed-ordering.md).

> Companion update (2026-10-07, build 10): Brief random phone/laptop/blushing idle moments use matching sprite
> frames. Real activity interrupts immediately and Reduce Motion stays static.
> Dancing remains removed; see [blush verification](companion-blush-animation.md) and [removal verification](companion-dance-removal.md).

> UI update (2026-10-07): Tasks owns its composer, goal/plan/result thread and follow-up drafts.
> Active and saved plans render connected execution flows. Approval remains explicit.
> See [task-panel verification](task-panel-flow.md); this does not complete the planned floating task panel.

> Scope update (2026-10-05): Pointer settings, cursor decoration and hover/circle/rectangle selection
> are removed; push-to-talk is voice-only. Explicit screen attachments, annotation arrows and the
> companion remain. See [the removal report](pointer-removal.md); do not restore cancelled work from historical checklists.

> Historical v1 plan. The Phase 5–7 status table below predates the current implementation. Use [remaining.md](remaining.md) and [the v1.1 roadmap](../docs/roadmap/README.md) for current work.

> Current expansion plan (2026-10-04): [Computer Control](../docs/roadmap/phase-19-computer-control.md)
> and [Assistant Workspace](../docs/roadmap/phase-20-assistant-workspace.md) cover the complete requested
> feature set, with dependencies, acceptance checks and an explicit implemented/planned distinction.

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
