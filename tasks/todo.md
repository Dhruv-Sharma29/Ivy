# Task List: Ivy Phase 1 (Core Menu Bar Chat)

## Phase 1.1: Foundation & Project Setup

### Task 1: Initialize Swift Package Structure
- **Description:** Create `Package.swift` declaring macOS 14+ / 15+ platform, `IvyCore` library target, `Ivy` executable target with SwiftUI entry point, and `IvyTests` test target.
- **Acceptance criteria:**
  - `Package.swift` validates and builds cleanly.
  - Targets are properly linked (`Ivy` depends on `IvyCore`, `IvyTests` depends on `IvyCore`).
  - Swift 6 strict concurrency flag `-strict-concurrency=complete` configured.
- **Verification:**
  - `swift build`
  - `swift test`
- **Dependencies:** None
- **Files likely touched:**
  - `Package.swift`
- **Estimated scope:** S (1-2 files)

### Task 2: Domain Models & Ivy Persona
- **Description:** Implement `ChatMessage`, `MessageRole`, and `IvyPersona` with Ivy's sharp, sarcastic system prompt text.
- **Acceptance criteria:**
  - `ChatMessage` conforms to `Identifiable`, `Codable`, `Equatable`, `Sendable`.
  - `IvyPersona.systemPrompt` defines Ivy's persona (dry wit, sarcastic, follow-through, safety priority).
  - All types satisfy Swift 6 strict concurrency without warnings.
- **Verification:**
  - `swift build -Xswiftc -strict-concurrency=complete`
- **Dependencies:** Task 1
- **Files likely touched:**
  - `Sources/IvyCore/Models/ChatMessage.swift`
  - `Sources/IvyCore/Models/Persona.swift`
- **Estimated scope:** S (2 files)

---

## Checkpoint 1: Foundation
- [x] `swift build` succeeds without compiler errors or warnings.
- [x] Foundation types are available for consumption in tests and clients.

---

## Phase 1.2: Gemini REST Client

### Task 3: Gemini REST Codable DTOs
- **Description:** Implement strongly-typed `Codable`, `Sendable` structs for Gemini REST requests and responses (`GeminiRequest`, `Content`, `Part`, `GeminiResponse`, `Candidate`, `GeminiAPIError`).
- **Acceptance criteria:**
  - Accurately models Google Generative Language v1beta JSON schema.
  - Supports system instructions, turn contents, and candidate extraction.
  - Handles parsing errors and API error structures gracefully.
- **Verification:**
  - `swift test --filter GeminiDTOTests`
- **Dependencies:** Task 2
- **Files likely touched:**
  - `Sources/IvyCore/Models/GeminiDTO.swift`
  - `Tests/IvyTests/GeminiDTOTests.swift`
- **Estimated scope:** M (2-3 files)

### Task 4: URLSession Gemini Client Implementation
- **Description:** Implement `GeminiClientProtocol` and `URLSessionGeminiClient` making direct POST requests to `gemini-3.8-flash:generateContent`.
- **Acceptance criteria:**
  - Performs network request with proper headers, URL encoding, and API key query parameter.
  - Parses text response from candidates.
  - Maps HTTP status codes (400, 403, 429, 500) to clear Swift errors (`GeminiClientError`).
- **Verification:**
  - `swift test --filter GeminiClientTests`
- **Dependencies:** Task 3
- **Files likely touched:**
  - `Sources/IvyCore/Services/GeminiClient.swift`
  - `Tests/IvyTests/GeminiClientTests.swift`
- **Estimated scope:** M (2-3 files)

---

## Checkpoint 2: REST Client
- [x] Unit tests pass with `swift test`.
- [x] Serialization and mock HTTP response parsing validated with 0 failures.

---

## Phase 1.3: State Machine & Brain

### Task 5: IvyBrain State Machine
- **Description:** Implement `IvyBrain` `@MainActor ObservableObject` that maintains message history, manages asynchronous send/receive turns, updates thinking state, and handles error states.
- **Acceptance criteria:**
  - Calling `send(_ text: String)` appends user message, toggles `isThinking = true`, invokes client, appends model response, and toggles `isThinking = false`.
  - Captures errors and displays in-character error message in message history.
  - Supports configurable API key (via initializer, environment, or mutable property).
- **Verification:**
  - `swift test --filter IvyBrainTests`
- **Dependencies:** Task 4
- **Files likely touched:**
  - `Sources/IvyCore/Brain/IvyBrain.swift`
  - `Tests/IvyTests/IvyBrainTests.swift`
- **Estimated scope:** M (2-3 files)

---

## Checkpoint 3: Brain Logic
- [x] `IvyBrainTests` passes all mock turn scenarios.
- [x] Turn history maintains order and handles errors without crashing.

---

## Phase 1.4: Native Menu Bar UI

### Task 6: SwiftUI Popover View Components
- **Description:** Build `IvyPopoverView`, `ChatMessageListView`, `ChatBubbleView`, and `MessageInputBar`.
- **Acceptance criteria:**
  - Polished macOS popover layout with message list, auto-scrolling, and responsive input field.
  - Distinct styling for user messages vs Ivy's responses.
  - Shows thinking indicator while Ivy is generating a response.
  - Keyboard shortcut: Return sends message, Shift+Return enters newline.
- **Verification:**
  - `swift build`
- **Dependencies:** Task 5
- **Files likely touched:**
  - `Sources/Ivy/Views/IvyPopoverView.swift`
  - `Sources/Ivy/Views/ChatBubbleView.swift`
  - `Sources/Ivy/Views/MessageInputBar.swift`
- **Estimated scope:** M (3-4 files)

### Task 7: MenuBarExtra Application Entry Point
- **Description:** Implement `IvyApp.swift` with `MenuBarExtra("Ivy", systemImage: "sparkle")` and configure window style popover. Provide minimal API key configuration in UI if unset.
- **Acceptance criteria:**
  - App launches in menu bar with sparkle icon.
  - Clicking icon toggles the popover window.
  - Allows entering/persisting API key in session memory if not found in environment.
- **Verification:**
  - `swift build`
  - Manual check: `swift run Ivy`
- **Dependencies:** Task 6
- **Files likely touched:**
  - `Sources/Ivy/IvyApp.swift`
- **Estimated scope:** S (1-2 files)

---

## Checkpoint 4: Phase 1 Complete Verification
- [x] All tests pass via `swift test`.
- [x] App compiles cleanly with Swift 6 strict concurrency (`-strict-concurrency=complete`).
- [x] Verified against `CONSTRAINTS.md` (no secrets, no stubs, strict concurrency, >80% coverage).

---

## Phase 2A: Gemini Function-Calling Infrastructure & open_app

### Task 8: AnyCodable & Gemini REST Tool DTOs [x]
- **Description:** Implement `AnyCodable` and extend `GeminiDTO.swift` with `ToolDeclarationWrapper`, `FunctionDeclaration`, `ToolParameters`, `ToolProperty`, `FunctionCall`, and `FunctionResponse`.
- **Acceptance criteria:**
  - Round-trip JSON encode/decode tests pass for function declarations, calls, and responses.
  - Swift 6 strict concurrency compliant (`Sendable`, `Equatable`).
- **Verification:** `swift test --filter GeminiDTOTests`
- **Dependencies:** Task 7
- **Estimated scope:** S (2 files)

### Task 9: Tool Protocol, Results, Errors & Argument Validation [x]
- **Description:** Define `IvyTool` protocol, `ToolResult`, `ToolError`, and application name validation utilities.
- **Acceptance criteria:**
  - `IvyTool` defines tool metadata, function declarations, and async execution interface.
  - Argument validation rejects empty names, path traversals, shell metacharacters, and excessive length.
  - Tests verify valid and invalid inputs.
- **Verification:** `swift test --filter ToolValidationTests`
- **Dependencies:** Task 8
- **Estimated scope:** S (2 files)

### Task 10: Workspace Abstraction & OpenAppTool [x]
- **Description:** Create `WorkspaceProtocol`, `SystemWorkspace` (using `NSWorkspace`), and `OpenAppTool`.
- **Acceptance criteria:**
  - `OpenAppTool` executes `open_app(name: String)` safely via `WorkspaceProtocol`.
  - In unit tests, `MockWorkspace` is used with zero real app launches.
  - Handles missing applications and reports descriptive errors.
- **Verification:** `swift test --filter OpenAppToolTests`
- **Dependencies:** Task 9
- **Estimated scope:** M (3 files)

### Task 11: ToolRegistry & ToolDispatcher [x]
- **Description:** Implement `ToolRegistry` and `ToolDispatcher` for tool lookup and execution routing.
- **Acceptance criteria:**
  - `ToolRegistry` registers tools and exposes `[ToolDeclarationWrapper]` for Gemini.
  - `ToolDispatcher` routes incoming `FunctionCall` to appropriate `IvyTool` and formats `FunctionResponse`.
  - Captures execution failures and returns safe error responses for model synthesis.
- **Verification:** `swift test --filter ToolDispatcherTests`
- **Dependencies:** Task 10
- **Estimated scope:** M (3 files)

### Task 12: Gemini Client Function-Calling Support & IvyBrain Multi-Turn Integration [x]
- **Description:** Enhance `GeminiClientProtocol` and `URLSessionGeminiClient` to handle tools and function calls. Integrate `ToolDispatcher` into `IvyBrain` multi-turn loop.
- **Acceptance criteria:**
  - `IvyBrain` detects function calls, dispatches execution, posts results back to Gemini, and delivers final in-character message.
  - Guard against infinite tool call loops.
  - Existing Phase 1 tests pass unchanged.
  - Mock integration tests verify end-to-end tool execution flow.
- **Verification:**
  - `swift build -Xswiftc -strict-concurrency=complete`
  - `swift test`
- **Dependencies:** Task 11
- **Estimated scope:** L (4 files)

---

## Checkpoint 5: Phase 2A Verification
- [x] Swift 6 strict concurrency compiles with zero warnings/errors.
- [x] All unit tests pass with zero failures (78 tests passing).
- [x] Code coverage exceeds 80% (91.30% overall coverage across IvyCore).
- [x] No stubs, no secrets, no unauthorized tools (no shell, AppleScript, file op, calendar).

---

## Phase 2B: SafetyGate & run_applescript

### Task 13: Centralized Tool Risk System & SafetyGate [x]
- **Description:** Implement centralized `SafetyPolicy` risk classification decoupled from individual tools, `InteractiveSafetyGate`, `ConfirmationProvider`, and `ConfirmationRequest`. Pre-evaluate tool arguments before safety gating.
- **Acceptance criteria:**
  - `SafetyPolicy` centrally governs safe vs risky classifications (`open_app` is safe, `run_applescript` is risky, default is risky).
  - Deceptive tools claiming `.safe` cannot bypass centralized `.risky` policy.
  - Safe tools execute automatically; risky tools require explicit user confirmation.
  - Swift 6 strict concurrency compliant (`Sendable`, `@MainActor`).
- **Verification:** `swift test --filter SafetyGateTests`
- **Dependencies:** Checkpoint 5
- **Estimated scope:** M (2 files)

### Task 14: AppleScript Tool & Injectable Executor [x]
- **Description:** Implement `RunAppleScriptTool` conforming to `IvyTool` with injectable `AppleScriptExecutorProtocol` (`SystemAppleScriptExecutor` and `MockAppleScriptExecutor`).
- **Acceptance criteria:**
  - Validates script length, non-empty whitespace, and null bytes before execution.
  - Malformed or invalid script arguments fail immediately without reaching executor or prompting user.
  - Non-fatal execution errors return structured `ToolResult.failure` without crashing.
  - Offline unit tests mock execution with zero real destructive AppleScripts.
- **Verification:** `swift test --filter RunAppleScriptToolTests`
- **Dependencies:** Task 13
- **Estimated scope:** M (3 files)

### Task 15: In-Character Confirmation UI & Cancellation Flow [x]
- **Description:** Implement `ConfirmationCardView` displaying tool name, arguments/script, sarcastic Ivy confirmation prompt, and "Do it" / "Cancel" buttons.
- **Acceptance criteria:**
  - Risky operations halt until user explicitly approves.
  - User cancellation returns structured `"User cancelled operation with prejudice."` to Gemini.
  - Sarcastic Ivy persona maintained in prompt text.
- **Verification:** `swift test --filter IvyBrainTests`
- **Dependencies:** Task 14
- **Estimated scope:** M (3 files)

### Task 16: Gemini 3.8 Flash Thought Signature Wire Preservation [x]
- **Description:** Ensure Gemini 3.8 Flash `thoughtSignature` is decoded from `Part`, retained in conversation history across model and tool turns, and emitted as camelCase `thoughtSignature` at the `Part` level (never inside `functionCall`).
- **Acceptance criteria:**
  - Round-trip encode/decode tests pass.
  - Exact token preserved through multi-turn tool loops without fabrication or alteration.
- **Verification:** `swift test --filter GeminiDTOTests`, `swift test --filter GeminiClientTests`
- **Dependencies:** Task 15
- **Estimated scope:** M (4 files)

---

## Checkpoint 6: Phase 2B Verification
- [x] Swift 6 strict concurrency compiles with zero warnings/errors (`-strict-concurrency=complete`).
- [x] All 150 unit tests pass with zero failures.
- [x] Code coverage exceeds 80% (90.48% overall coverage across IvyCore).
- [x] Centralized SafetyGate prevents tool deception and enforces confirmation on risky tools.
- [x] No unauthorized tools (no shell, file operations, calendar, voice, persistence).

---

## Phase 2C: Calendar Event Tool [x]
- [x] Strongly typed `calendar_event(title, date)` with ISO 8601 parsing & EventKit integration.
- [x] Risky classification under `SafetyGate` requiring explicit user confirmation.
- [x] 100% mock executor coverage in unit tests; zero real calendar events created in tests.

---

## Phase 2D: File Operations Tool [x]
- [x] Strongly typed `file_op(action, path, content?)` supporting read, write, delete.
- [x] Path containment, symlink escape checks, traversal protection (`../`, `../../`).
- [x] `read` classified as safe; `write` and `delete` classified as risky requiring explicit confirmation.

---

## Phase 2E: Shell Command Tool [x]
- [x] Strongly typed `run_shell(command)`.
- [x] Always classified as risky; requires explicit user confirmation.
- [x] Concurrency-safe pipes, environment scrubbing, process escalation termination, BiDi protection.

---

## Phase 3: Security & Safety Hardening [x]
- [x] Centralized SafetyGate audit across all 5 tools (`open_app`, `run_applescript`, `calendar_event`, `file_op`, `run_shell`).
- [x] Strict risk classification (`open_app`, `file_op read` safe; `run_applescript`, `calendar_event`, `file_op write/delete`, `run_shell` risky).
- [x] Zero bypass paths from Gemini `functionCall` to executor; unexpected arguments strictly rejected.
- [x] Confirmation security: tied to exact pending UUID and `callId`; approval authorizes only that specific call; mismatched UUID ignored; cancel guarantees zero execution; repeated approvals execute at most once; natural language chat cannot approve pending actions.
- [x] Response distinguishability: `isCancelled`, `isSafetyRejection`, `isValidationError`, `isToolNotFound`, `isSuccess` clearly differentiated in `FunctionResponse`.
- [x] API key scrubbing in debug logs.
- [x] 100% Swift 6 strict concurrency compliance (`-strict-concurrency=complete`), zero force unwraps (`!`), zero warnings.
- [x] 330 automated tests in 38 suites passing; 94.45% line coverage.



