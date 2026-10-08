# Task List: Ivy Development Roadmap

> Scope update (2026-10-05): Pointer settings, cursor decoration and hover/circle/rectangle selection
> are removed; push-to-talk is voice-only. Explicit screen attachments, annotation arrows and the
> companion remain. See [the removal report](pointer-removal.md); do not restore cancelled work from historical checklists.

> Historical v1 checklist. Its unchecked Phase 5–7 items are not the current backlog. See [remaining.md](remaining.md) for the source-audited status and [the v1.1 roadmap](../docs/roadmap/README.md) for module acceptance criteria.

## Phase 1: Core Menu Bar Chat [Complete]

### Phase 1.1: Foundation & Project Setup
- [x] **Task 1: Initialize Swift Package Structure** (`Package.swift`, `IvyCore`, `Ivy`, `IvyTests`, `-strict-concurrency=complete`)
- [x] **Task 2: Domain Models & Ivy Persona** (`ChatMessage`, `MessageRole`, `IvyPersona.systemPrompt`)
- [x] **Checkpoint 1: Foundation** (Clean build, types available)

### Phase 1.2: Gemini REST Client
- [x] **Task 3: Gemini REST Codable DTOs** (`GeminiRequest`, `Content`, `Part`, `GeminiResponse`, `Candidate`, `GeminiAPIError`)
- [x] **Task 4: URLSession Gemini Client** (`GeminiClientProtocol`, `URLSessionGeminiClient`, HTTP error mapping)
- [x] **Checkpoint 2: REST Client** (Round-trip encode/decode verified, mock HTTP passing)

### Phase 1.3: State Machine & Brain
- [x] **Task 5: IvyBrain State Machine** (`IvyBrain` `@MainActor ObservableObject`, turn logic, thinking state, error mapping)
- [x] **Checkpoint 3: Brain Logic** (Turn history maintains order, error handling verified)

### Phase 1.4: Native Menu Bar UI
- [x] **Task 6: SwiftUI Popover View Components** (`IvyPopoverView`, `ChatBubbleView`, `MessageInputBar`, autoscroll)
- [x] **Task 7: MenuBarExtra Application Entry Point** (`IvyApp.swift`, `MenuBarExtra("Ivy", systemImage: brain.statusIcon)`)
- [x] **Checkpoint 4: Phase 1 Verification** (All tests passing, Swift 6 strict concurrency, >80% coverage)

---

## Phase 2: Tool Layer & Function Calling [Complete]

### Phase 2A: Gemini Function-Calling Infrastructure & open_app
- [x] **Task 8: AnyCodable & Gemini REST Tool DTOs** (`ToolDeclarationWrapper`, `FunctionDeclaration`, `FunctionCall`, `FunctionResponse`)
- [x] **Task 9: Tool Protocol & Argument Validation** (`IvyTool`, `ToolResult`, `ToolError`, name & path sanitization)
- [x] **Task 10: Workspace Abstraction & OpenAppTool** (`WorkspaceProtocol`, `SystemWorkspace`, `MockWorkspace`, `OpenAppTool`)
- [x] **Task 11: ToolRegistry & ToolDispatcher** (`ToolRegistry`, `ToolDispatcher`, multi-tool routing)
- [x] **Task 12: Gemini Function-Calling & IvyBrain Multi-Turn Integration** (Loop detection, turn response injection, in-character synthesis)
- [x] **Checkpoint 5: Phase 2A Verification** (78 tests passing, 91.30% coverage)

### Phase 2B: SafetyGate & run_applescript
- [x] **Task 13: Centralized Tool Risk System & SafetyGate** (`SafetyPolicy`, `InteractiveSafetyGate`, `ConfirmationRequest`)
- [x] **Task 14: AppleScript Tool & Injectable Executor** (`RunAppleScriptTool`, `AppleScriptExecutorProtocol`, syntax and null-byte validation)
- [x] **Task 15: In-Character Confirmation UI & Cancellation** (`ConfirmationCardView`, "Do it" / "Cancel", cancel feedback to Gemini)
- [x] **Task 16: Gemini 3.8 Flash Thought Signature Wire Preservation** (CamelCase `thoughtSignature` at `Part` level preserved across turns)
- [x] **Checkpoint 6: Phase 2B Verification** (150 tests passing, 90.48% coverage)

### Phase 2C: Calendar Event Tool
- [x] Strongly typed `calendar_event(title, date)` with ISO 8601 parsing & EventKit integration.
- [x] Risky classification under `SafetyGate` requiring explicit user confirmation.
- [x] 100% mock executor coverage in unit tests; zero real calendar events created in tests.

### Phase 2D: File Operations Tool
- [x] Strongly typed `file_op(action, path, content?)` supporting read, write, delete.
- [x] Path containment, symlink escape checks, traversal protection (`../`, `../../`).
- [x] `read` classified as safe; `write` and `delete` classified as risky requiring explicit confirmation.

### Phase 2E: Shell Command Tool
- [x] Strongly typed `run_shell(command)`.
- [x] Always classified as risky; requires explicit user confirmation.
- [x] Concurrency-safe pipes, environment scrubbing, process escalation termination.

---

## Phase 3: Security & Safety Hardening [Complete]
- [x] Centralized SafetyGate audit across all 5 tools (`open_app`, `run_applescript`, `calendar_event`, `file_op`, `run_shell`).
- [x] Strict risk classification (`open_app`, `file_op read` safe; others risky).
- [x] Zero bypass paths from Gemini `functionCall` to executor; unexpected arguments strictly rejected.
- [x] Confirmation security: tied to exact pending UUID and `callId`; mismatched UUID ignored; cancel guarantees zero execution; repeated approvals execute at most once; natural language chat cannot approve pending actions.
- [x] Response distinguishability: `isCancelled`, `isSafetyRejection`, `isValidationError`, `isToolNotFound`, `isSuccess` clearly differentiated in `FunctionResponse`.
- [x] API key scrubbing in debug logs and error messages.
- [x] 330 automated tests in 38 suites passing; 94.45% line coverage.

---

## Phase 4: Voice In & Out & Live Multimodal [Complete]

### Phase 4A: ElevenLabs Text-to-Speech
- [x] **Task 17: ElevenLabs TTS Client & Key Provider** (`ElevenLabsSpeechSynthesizer`, `ElevenLabsConfiguration`, `ConfigurableElevenLabsKeyProvider`, custom voice `GO7CKs5ENqIU2xXLHrtL` / fallback `EXAVITQu4vr4xnSDxMaL`)
- [x] **Task 18: Audio Player & Voice Playback Manager** (`AudioPlayerProtocol`, `SystemAudioPlayer`, `MockAudioPlayer`, `VoicePlaybackManager` `@MainActor ObservableObject`)
- [x] **Task 19: Popover Audio Playback Controls** (Inline audio play/stop toggle button on message bubbles, error banners, synthesis state indicator)

### Phase 4B: Gemini Live WebSocket Client & Interruption
- [x] **Task 20: Gemini Live Multimodal Protocol & Client** (`GeminiLiveClient` WebSocket client connecting to `GenerativeService.BidiGenerateContent`, 16kHz PCM mono audio streaming, Tavi voice locked)
- [x] **Task 21: Native Audio Capture & Streaming** (`AudioCaptureProtocol`, `SystemAudioCapture` using `AVAudioEngine`, 16kHz format conversion, error resilience)
- [x] **Task 22: Live Audio Player with Smooth Playback** (`LiveAudioPlayerProtocol`, `SystemLiveAudioPlayer` with chunk queueing, format conversions, and instant drain)
- [x] **Task 23: On-Device "Hey Ivy" Interruption** (`WakeWordDetectorProtocol`, `SystemWakeWordDetector`, `WakePhraseMatcher`, partial transcription matching, instant playback stop and buffer purge)
- [x] **Task 24: GeminiLiveVoiceCoordinator** (`@MainActor ObservableObject` orchestrating state transitions: `.idle`, `.connecting`, `.listening`, `.speaking`, `.error`)

### Phase 4C: Global Push-to-Talk Hotkey
- [x] **Task 25: Carbon Global Hotkey Manager** (`SystemGlobalHotkeyManager`, `GlobalHotkeyManaging`, `HotkeyShortcut.defaultPushToTalk` with `⌘ + ⇧ + Space`, zero Accessibility permission required)
- [x] **Task 26: Push-to-Talk State Machine** (Key-down starts session / unmutes listening, key-up ends turn, idempotent deduplication)

### Phase 4D: Gemini Live Tool Calling & SafetyGate
- [x] **Task 27: Voice Tool Call Dispatching** (`GeminiLiveVoiceCoordinator` routes model `toolCall` events through `SafetyGate` and `ToolDispatcher`)
- [x] **Task 28: Live In-Character Confirmation** (Renders confirmation cards in popover, blocks execution until confirmed, returns `toolResponse` over WebSocket)

### Checkpoint 7: Phase 4 Complete Verification
- [x] Swift 6 strict concurrency compiles with zero warnings/errors (`-swiftLanguageMode(.v6)`).
- [x] All 703 unit tests pass across 71 test suites in < 1 second.
- [x] Real-time voice conversation, hands-free "Hey Ivy" interruption, and push-to-talk hotkey verified.

---

## Phase 5: Persistence & Settings [Next Up]

### Phase 5.1: macOS Keychain Storage
- [ ] **Task 29: Keychain Storage Abstraction & System Implementation**
  - Implement `KeychainStorageProtocol` with `save(key:value:service:)`, `get(key:service:)`, `delete(key:service:)`.
  - Implement `SystemKeychainStorage` using macOS Security framework (`SecItemAdd`, `SecItemCopyMatching`, `SecItemUpdate`, `SecItemDelete`) under service `com.ivy.assistant`.
  - Implement thread-safe `MockKeychainStorage` for isolated offline unit testing.
  - Verification: `swift test --filter KeychainStorageTests`
- [ ] **Task 30: Credential Provider Keychain Integration**
  - Update `IvyBrain` and `VoicePlaybackManager` to load keys from Keychain on startup, falling back to environment variables (`GEMINI_API_KEY`, `ELEVENLABS_API_KEY`).
  - Automatically persist user-entered API keys to Keychain when modified in popover settings.
  - Verification: `swift test --filter CredentialProviderTests`

### Phase 5.2: Conversation History Persistence
- [ ] **Task 31: Session History Storage Protocol & JSON Implementation**
  - Implement `HistoryStorageProtocol` with `loadHistory() async throws -> [ChatMessage]` and `saveHistory(_ messages: [ChatMessage]) async throws`.
  - Implement `JSONHistoryStorage` writing to `~/Library/Application Support/Ivy/history.json`.
  - Atomic write via temporary file + rename to prevent corruption on crash or abrupt quit.
  - Filter out transient error messages and incomplete tool states before serialization.
  - Implement `MockHistoryStorage` for unit tests.
  - Verification: `swift test --filter HistoryStorageTests`
- [ ] **Task 32: IvyBrain History Restoration & Auto-Save**
  - `IvyBrain` loads persisted history on launch.
  - Debounced auto-save on message append / turn completion.
  - "Clear Conversation" removes file from disk and clears in-memory state.
  - Verification: `swift test --filter IvyBrainHistoryTests`

### Phase 5.3: Popover Settings UI Enhancements
- [ ] **Task 33: Enhanced Settings View in IvyPopoverView**
  - Indicator for Keychain status (e.g. "Stored securely in macOS Keychain").
  - Persistent input fields for Gemini API Key, ElevenLabs API Key, and ElevenLabs Voice ID.
  - "Clear Conversation History" button with confirmation prompt.
  - Verification: `swift build` and manual UI inspection.

### Checkpoint 8: Phase 5 Verification
- [ ] `swift test` passes with 100% pass rate.
- [ ] Concurrency check: `swift build -Xswiftc -strict-concurrency=complete` with zero warnings.
- [ ] App retains conversation and credentials after restart.
- [ ] Zero secrets written to plain disk files; keys strictly stored in Keychain.

---

## Phase 6: Permissions & Sandboxing [Scheduled]
- [ ] Embedded Info.plist privacy descriptions (`NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`, `NSCalendarsFullAccessUsageDescription`).
- [ ] Sandboxing evaluation & hardened runtime entitlements.
- [ ] Permission check recovery flow & user guidance UI when permissions denied.

---

## Phase 7: Portfolio Polish [Scheduled]
- [ ] Dynamic menu bar status icons (idle, thinking, speaking, listening, error).
- [ ] Automated notarization and packaging scripts.
- [ ] Architecture documentation, diagrams, demo GIF.
