# Spec: Ivy — Native macOS Assistant

## Objective
Ivy is a lightweight, responsive native macOS menu bar assistant built in Swift and SwiftUI, powered by Google's Gemini 3.8 Flash REST API (without the Google GenAI SDK). Ivy has a distinctive persona: sharp, sarcastic, witty, and impatient with vagueness, but reliably effective. Ivy pairs conversational AI with local macOS system automation (AppleScript, shell, application control, calendar, file management), backed by an uncompromising in-character confirmation gate for risky/destructive actions.

The initiative is built incrementally across 7 phases, starting strictly with **Phase 1: Core text-only menu bar chat loop**.

---

## Tech Stack
- **Language**: Swift 6.4 (Strict Concurrency Checking enabled: `-strict-concurrency=complete`)
- **Frameworks**: SwiftUI, AppKit (`NSWorkspace`, `NSAlert`), Foundation (`URLSession`), OSLog
- **Target OS**: macOS 14.0+ (Sonoma) / macOS 15.0+ (Sequoia)
- **API**: Gemini 3.8 Flash REST endpoint (`POST https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent`)
- **Networking**: Native `URLSession` with `async/await` and custom JSON `Codable` models (zero third-party SDK dependencies)
- **Build System**: Swift Package Manager (`Package.swift`) with separated `IvyCore` logic library, `Ivy` executable app target, and `IvyTests` test target.

---

## Commands
```bash
# Build the entire package with Swift 6 strict concurrency checks:
swift build -Xswiftc -strict-concurrency=complete

# Run the test suite:
swift test

# Run tests with code coverage report:
swift test --enable-code-coverage

# Run the Ivy app executable directly:
swift run Ivy

# Archive/build release binary:
swift build -c release
```

---

## 1. System Architecture

Ivy uses a Unidirectional Data Flow (UDF) clean architecture designed around Swift 6 concurrency (`Sendable`, `@MainActor`, `async/await`):

```
┌────────────────────────────────────────────────────────┐
│                      UI Layer                          │
│   IvyApp (MenuBarExtra) ──► IvyPopoverView             │
│                                 │                      │
│                                 ▼                      │
│                   @StateObject / @Observable           │
│                           IvyBrain                     │
└────────────────────────────┬───────────────────────────┘
                             │
            ┌────────────────┴────────────────┐
            ▼                                 ▼
┌───────────────────────────┐    ┌───────────────────────────┐
│     Gemini REST Layer     │    │   Execution & Safety      │
│  GeminiClient (Protocol)  │    │  SafetyGate               │
│  URLSessionGeminiClient   │    │  ToolDispatcher           │
│  Custom JSON Codable      │    │  Tool Handlers (Phase 2+) │
└───────────────────────────┘    └───────────────────────────┘
            │                                 │
            ▼                                 ▼
┌───────────────────────────┐    ┌───────────────────────────┐
│     Persistence Layer     │    │    macOS System Bridge    │
│  KeychainStorage (Keys)   │    │  NSWorkspace, Process,    │
│  SessionStorage (JSON)    │    │  NSAppleScript, EventKit  │
└───────────────────────────┘    └───────────────────────────┘
```

### Architectural Principles:
1. **Zero SDK Lock-In**: Direct lightweight REST calls to Gemini using standard Foundation `URLSession`.
2. **Actor Isolation & Concurrency Safety**: The networking client and tool dispatchers are non-isolated or background actors; UI state is isolated to `@MainActor`.
3. **Safety First**: Tool execution is strictly decoupled behind an interceptor (`SafetyGate`). Risky operations cannot bypass confirmation regardless of prompt injection or model hallucination.
4. **Mockability**: `GeminiClient` conforms to a protocol, enabling deterministic offline unit tests for turn management, error handling, and tool call responses without hitting Google servers.

---

## 2. Project Structure

```
Ivy/
├── Package.swift                     # SPM manifest (IvyCore library, Ivy App, IvyTests)
├── CAPABILITY-MAP.md                 # Initiative capability breakdown
├── CONSTRAINTS.md                    # Project quality floor & enforceable metrics
├── AGENTS.md                         # Rules for autonomous agents
├── SPEC.md                           # Master specification (this document)
├── tasks/
│   ├── plan.md                       # High-level technical plan
│   └── todo.md                       # Discrete, verifiable task list
├── Sources/
│   ├── Ivy/                          # Application Entry Point & UI
│   │   ├── IvyApp.swift              # @main SwiftUI App + MenuBarExtra(.window)
│   │   ├── Views/
│   │   │   ├── IvyPopoverView.swift  # Main popover container view
│   │   │   ├── ChatMessageListView.swift # Scrollable message bubbles
│   │   │   ├── ChatBubbleView.swift  # Single message bubble (user vs ivy)
│   │   │   ├── MessageInputBar.swift # TextEditor / TextField + Send action
│   │   │   └── StatusIndicatorView.swift # Idle / Thinking / Error indicator
│   │   └── Resources/
│   │       └── Info.plist            # LSUIElement=true (accessory/menu bar app)
│   │
│   └── IvyCore/                      # Domain logic, API client, Brain state
│       ├── Models/
│       │   ├── ChatMessage.swift     # Domain message model (role, text, timestamp)
│       │   ├── Persona.swift         # Ivy system prompt definition
│       │   ├── GeminiDTO.swift       # Request/Response JSON Codable models
│       │   ├── ToolDeclaration.swift # Tool schema definitions (Phase 2)
│       │   └── SafetyLevel.swift     # Safe vs Risky classification (Phase 3)
│       ├── Services/
│       │   ├── GeminiClient.swift    # GeminiClientProtocol & URLSessionGeminiClient
│       │   ├── KeychainStorage.swift # Secure API key storage (Phase 5)
│       │   └── SessionStorage.swift  # JSON conversation persistence (Phase 5)
│       ├── Tools/                    # Tool execution engine (Phase 2+)
│       │   ├── ToolDispatcher.swift  # Function dispatch router
│       │   └── Handlers/             # Individual tool implementations
│       └── Brain/
│           ├── IvyBrain.swift        # Central @MainActor state coordinator
│           └── SafetyGate.swift      # Destructive action interceptor (Phase 3)
│
└── Tests/
    └── IvyTests/
        ├── GeminiClientTests.swift   # Mocked REST serialization & deserialization tests
        ├── IvyBrainTests.swift       # Turn handling, message ordering, error states
        ├── PersonaTests.swift        # System instruction payload validation
        └── ToolDispatcherTests.swift # Tool schema & routing tests
```

---

## 3. Data Models

### Domain Models (`IvyCore/Models/ChatMessage.swift`)
```swift
import Foundation

public enum MessageRole: String, Codable, Sendable {
    case user
    case model
    case system
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public let text: String
    public let timestamp: Date
    public let isError: Bool

    public init(id: UUID = UUID(), role: MessageRole, text: String, timestamp: Date = Date(), isError: Bool = false) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isError = isError
    }
}
```

### Gemini REST DTO Models (`IvyCore/Models/GeminiDTO.swift`)
Strict mapping for Google Generative Language REST v1beta:
```swift
import Foundation

public struct GeminiRequest: Codable, Sendable {
    public let systemInstruction: SystemInstruction?
    public let contents: [Content]
    public let tools: [ToolDeclarationWrapper]?

    public init(systemInstruction: SystemInstruction? = nil, contents: [Content], tools: [ToolDeclarationWrapper]? = nil) {
        self.systemInstruction = systemInstruction
        self.contents = contents
        self.tools = tools
    }
}

public struct SystemInstruction: Codable, Sendable {
    public let parts: [Part]
    public init(text: String) {
        self.parts = [Part(text: text)]
    }
}

public struct Content: Codable, Sendable {
    public let role: String
    public let parts: [Part]

    public init(role: String, parts: [Part]) {
        self.role = role
        self.parts = parts
    }
}

public struct Part: Codable, Sendable {
    public let text: String?
    public let functionCall: FunctionCall?
    public let functionResponse: FunctionResponse?

    public init(text: String? = nil, functionCall: FunctionCall? = nil, functionResponse: FunctionResponse? = nil) {
        self.text = text
        self.functionCall = functionCall
        self.functionResponse = functionResponse
    }
}

public struct FunctionCall: Codable, Sendable {
    public let name: String
    public let args: [String: AnyCodable]
}

public struct FunctionResponse: Codable, Sendable {
    public let name: String
    public let response: [String: AnyCodable]
}

public struct GeminiResponse: Codable, Sendable {
    public let candidates: [Candidate]?
    public let error: GeminiAPIError?
}

public struct Candidate: Codable, Sendable {
    public let content: Content?
    public let finishReason: String?
}

public struct GeminiAPIError: Codable, Sendable {
    public let code: Int
    public let message: String
    public let status: String
}
```

*(Note: `AnyCodable` is a clean, lightweight enum supporting JSON primitives `string`, `int`, `double`, `bool`, `dictionary`, `array` for arbitrary function call arguments).*

---

## 4. Gemini API Abstraction

### Protocol Interface (`IvyCore/Services/GeminiClient.swift`)
```swift
import Foundation

public protocol GeminiClientProtocol: Sendable {
    func generateContent(
        history: [ChatMessage],
        systemPrompt: String,
        apiKey: String
    ) async throws -> String
}
```

### URLSession Implementation
- **Endpoint**: `https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent` (key in the `x-goog-api-key` header only)
- **HTTP Method**: `POST`
- **Headers**: `Content-Type: application/json`
- **Timeout**: 30 seconds request timeout
- **Error Mapping**:
  - `invalidAPIKey` (HTTP 400/403 with `API_KEY_INVALID`)
  - `quotaExceeded` (HTTP 429)
  - `serverError(code, message)` (HTTP 5xx)
  - `decodingError(Error)`
  - `emptyResponse`

---

## 5. UI Architecture

### Menu Bar Window (`Ivy/IvyApp.swift`)
```swift
import SwiftUI
import IvyCore

@main
struct IvyApp: App {
    @StateObject private var brain = IvyBrain()

    var body: some Scene {
        MenuBarExtra("Ivy", systemImage: brain.statusIcon) {
            IvyPopoverView(brain: brain)
        }
        .menuBarExtraStyle(.window)
    }
}
```

### Popover View Layout (`Ivy/Views/IvyPopoverView.swift`)
- **Dimensions**: Fixed width (360pt), dynamic height (480pt–600pt).
- **Header**:
  - Title: "Ivy" (bold, semi-callout font)
  - Status indicator: Subtle colored dot or animated symbol (Idle: Gray, Thinking: Amber pulse, Speaking: Blue)
  - Clear / Reset conversation button
- **Message List**:
  - `ScrollViewReader` with auto-scroll to latest message on append.
  - User bubbles: Right-aligned, primary accent background, white text.
  - Ivy bubbles: Left-aligned, macOS system secondary background with sarcastic tone styling.
- **Input Bar**:
  - Multiline `TextField` or `TextEditor` with placeholder *"Ask Ivy... if you must"*.
  - Keyboard shortcuts: `Return` to send, `Shift+Return` for newline.
  - Send button (disabled when empty or while `isThinking == true`).

---

## 6. Tool / Function-Calling Architecture (Phase 2+)

Tools are declared via JSON Schema in `tools: [{functionDeclarations: [...]}]`:
1. `run_applescript(script: String)`
2. `open_app(name: String)`
3. `run_shell(command: String)`
4. `calendar_event(title: String, date: String)`
5. `file_op(action: String, path: String)`

### Execution Loop:
1. Gemini generates response containing a `functionCall`.
2. `IvyBrain` catches `functionCall` and routes to `SafetyGate`.
3. If approved, `ToolDispatcher` executes the local action and produces a string result.
4. `IvyBrain` appends `functionResponse` part to the conversation history and calls Gemini again.
5. Gemini generates the final sarcastic natural language response synthesizing the tool result.

---

## 7. Confirmation & Security Model (Phase 3+)

### Tool Risk Matrix:
| Tool | Operation | Classification | Interception Policy |
|---|---|---|---|
| `open_app` | Launch application | **Safe** | Auto-execute |
| `calendar_event` | Read calendar | **Safe** | Auto-execute |
| `calendar_event` | Create/Modify/Delete | **Risky** | Confirmation Required |
| `file_op` | Read/List directory | **Safe** | Auto-execute |
| `file_op` | Write/Delete/Move | **Risky** | Confirmation Required |
| `run_shell` | Any command (`rm`, `kill`, `curl`, etc.) | **Risky** | Confirmation Required |
| `run_applescript` | Script execution | **Risky** | Confirmation Required |

### In-Character Confirmation Phrasing:
The confirmation prompt never drops Ivy's persona:
> *"You're about to run `rm -rf ~/Documents/Drafts`. If you regret this, don't blame me. Do it or chicken out?"*
> Options: `[Do it]` / `[Cancel]`

Confirmation uses a native modal `NSAlert` or in-popover confirmation banner. If cancelled, the tool returns `"User cancelled operation with prejudice."` to Gemini.

---

## 8. Persistence Design (Phase 5+)

- **API Key Storage**: Stored exclusively in the macOS Keychain under service name `com.ivy.assistant`, key `gemini_api_key`. Never written to `UserDefaults` or disk files.
- **Session History Storage**: Persisted to Application Support directory: `~/Library/Application Support/Ivy/history.json`.
  - Serialized via `JSONEncoder(outputFormatting: .prettyPrinted)`.
  - Loaded on app launch so conversation continuity is preserved across restarts.

---

## 9. Permissions & Entitlements (Phase 6+)

### Info.plist Keys:
- `LSUIElement = YES`: Hides app from the macOS Dock; runs purely as an accessory in the status bar.
- `NSAppleEventsUsageDescription`: "Ivy needs permission to automate macOS applications via AppleScript."
- `NSMicrophoneUsageDescription`: "Ivy needs access to your microphone for push-to-talk voice commands."
- `NSSpeechRecognitionUsageDescription`: "Ivy uses speech recognition to transcribe your voice."

### Sandboxing Trade-off:
- `com.apple.security.app-sandbox = NO`: Arbitrary shell execution and system-wide AppleScript require non-sandboxed mode.
- Hardened Runtime is enabled for Developer ID signing and Apple NotaryTool notarization.

---

## 10. Testing Strategy

1. **Unit Testing (`IvyTests`)**:
   - `GeminiDTOTests`: Test round-trip JSON serialization and deserialization against official Gemini REST payloads.
   - `GeminiClientMockTests`: Test `IvyBrain` turn logic with mocked HTTP responses (success, rate limit, invalid key, network timeout).
   - `PersonaTests`: Verify system instructions are correctly bundled into requests.
2. **Integration Verification**:
   - `IvyBrainLiveTest`: Direct integration test with real `GEMINI_API_KEY` (runnable via environment flag).
3. **Execution Floor & Coverage**:
   - Minimum 80% coverage on new `IvyCore` models and service code.
   - Zero Swift 6 concurrency compiler warnings.

---

## 11. Boundaries
- **Always**:
  - Enforce Swift 6 strict concurrency (`Sendable` types, `@MainActor` UI annotations).
  - Handle all network errors gracefully and show in-character error messages in the UI.
  - Intercept risky tools before execution.
- **Ask First**:
  - Adding any third-party SPM dependency.
  - Modifying the system persona or safety classifications.
- **Never**:
  - Commit API keys or credentials to version control.
  - Execute shell commands or file deletions without user confirmation.
  - Fall back to silent failure or empty `catch {}`.

---

## 12. Success Criteria for Phase 1 (Core Loop)
- [ ] Swift Package compiles cleanly with `swift build -Xswiftc -strict-concurrency=complete`.
- [ ] Unit tests pass via `swift test` with zero failures.
- [ ] Ivy lives in the macOS menu bar with an icon (`sparkle`).
- [ ] Clicking the icon reveals a polished popover with conversation history and input bar.
- [ ] User can enter an API key via UI or environment variable (`GEMINI_API_KEY`).
- [ ] Sending a message sends the turn history + Ivy system prompt to `gemini-3.8-flash`.
- [ ] Model responds in Ivy's distinctive sarcastic tone and appears in the chat scroll.
- [ ] Error states (invalid key, network offline) display helpful, in-character alerts.
