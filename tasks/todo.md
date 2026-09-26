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
