# Spec: Ivy — Native macOS Assistant

## Objective
Ivy is a lightweight, responsive native macOS desktop assistant built in Swift and SwiftUI, powered by Google's Gemini 3.8 Flash REST API (without the Google GenAI SDK). Ivy has a distinctive persona: sharp, sarcastic, witty, and impatient with vagueness, but reliably effective. Ivy pairs conversational AI with local macOS system automation (AppleScript, shell, application control, calendar, file management), backed by an uncompromising in-character confirmation gate for risky/destructive actions.

The initiative is built incrementally across 7 phases, starting strictly with **Phase 1: Core text-only chat loop**.

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
│   IvyApp (Window)       ──► MainWindowView             │
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
│   │   ├── IvyApp.swift              # @main SwiftUI Window + menu shortcut + Settings
│   │   ├── Views/
│   │   │   ├── IvyPopoverView.swift  # Main popover container view
│   │   │   ├── ChatMessageListView.swift # Scrollable message bubbles
│   │   │   ├── ChatBubbleView.swift  # Single message bubble (user vs ivy)
│   │   │   ├── MessageInputBar.swift # TextEditor / TextField + Send action
│   │   │   └── StatusIndicatorView.swift # Idle / Thinking / Error indicator
│   │   └── Resources/
│   │       └── Info.plist            # LSUIElement=true (companion/menu-bar app)
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
  - `invalidRequest` (HTTP 400 without an invalid-key reason; includes malformed bodies and unmet prerequisites). Preserve the server message, redact the supplied credential, and do not retry client errors.
  - `quotaExceeded` (HTTP 429)
  - `serverError(code, message)` (HTTP 5xx)
  - `decodingError(Error)`
  - `emptyResponse`

---

## 5. UI Architecture

### Desktop app shell (revised 2026-10-02)

- Ivy's visual refresh uses compact header rows, 20-point rounded cards,
  generous separation between groups, icon wells and restrained indigo emphasis. Home, Library, Tasks,
  Settings and the floating Command Bar share this rhythm. The Command Bar exposes Close, Open Ivy and
  Send controls and fits its height to replies/attachments while keeping its top edge stable;
  quick suggestions only fill its draft. Existing navigation, capture review, voice and
  approval rules still apply. Solid-surface previews verify layout and text; actual native glass
  appearance still requires an in-app visual check.

- macOS registers `ivy://new` and `ivy://conversation/<UUID>` for navigation only. Links reveal Chat in the main window, preserve per-conversation drafts, and never send prompts or run tools. Extra parameters and action URLs are ignored. Active requests, approvals, tasks, voice sessions and attachment processing block switching with a visible notice; missing conversations leave the current chat intact.

- Starting a live voice session opens Chat so its conversation and replies are visible.
- The composer is a compact glass bar with a plus attachment menu, native multiline editor, microphone and circular send action. Its placeholder, short draft text and 36-point icon controls share a vertical center line, with neutral attachment and microphone icons, indigo send emphasis, and immediate hover/press feedback. Long drafts grow and scroll with equal vertical padding. Shift–Return inserts a newline at the current selection without sending; Return sends once, respecting blocked turns. No persistent keyboard hint is shown.
- Ivy launches and reopens with its on-screen companion and menu-bar icon, without a Dock icon or Command-Tab entry. The native SwiftUI `Window("Ivy", id: "main")` opens only by explicit workspace actions, companion click, screen-help capture or a recognized deep link. On macOS 15+ workspace/settings scene launch and restoration are suppressed; macOS 14 hides its automatically created workspace through the existing window registration. First-run onboarding may still open for setup.
- Closing the main workspace window or choosing Work in Background from the File menu or menu bar leaves Ivy running with the companion visible. The action enables companion/idle visibility and clears Hide for Now. Voice, held PTT, chat and approved Tasks remain owned by the app and continue; it never approves a plan or a tool. Explicit background mode suppresses automatic workspace opening for suggestions and retains them for later. Work in Background hides only the registered workspace and retains its drafts; other app windows are independent. Closing/replacing the native workspace is observed without replacing SwiftUI’s window delegate. Open Ivy or clicking the companion restores the workspace. Quit stops Ivy and releases resources; a closed window is not Quit.
- Initial size: 1080 × 760 points; minimum content size: 560 × 480 points. Hidden title bar and toolbar remove the large top strip, while native window controls, resizing and full-screen support remain. A labeled New chat action is below the sidebar header; New Conversation remains in the File menu; Chat Instructions stays in the Conversation menu; Settings remains in the sidebar and Command-comma.
- `NavigationSplitView`: conversation sidebar and chat detail. The native sidebar toggle supports a compact chat layout.
- Menu bar extra: a small shortcut menu for Open Ivy, Work in Background, starting a conversation, ending voice, Settings and Quit.
- Branding uses the professional paired-leaf app icon in the app bundle, sidebar, empty state and Settings. The menu bar uses the outlined native leaf symbol, matching the companion's idle status icon, and keeps it visible across activity states. Icon packaging reads the same PNG master used by the app.
- Standard File commands: New Conversation (Command-N) and Open Ivy (Command-O). Settings uses the native Settings scene (Command-comma).

### Conversation interface
- Neutral graphite and white surfaces use a muted indigo accent. The sidebar selection, controls, composer and Settings share this palette. Colors adapt to light, dark and increased-contrast appearances.
- Home is a compact workspace with a text introduction, six everyday prompt-drafting shortcuts (Research, Summarize, Write, Files, Explain and Plan a task), real current task state and recent conversations. Character artwork, neon gradients and playful slogans are excluded from the workspace. The professional leaf icon appears only as compact app branding. The navigation rail contains Home, Library, Tasks and a native Settings link. All rows have aligned symbols, equal heights and full-row click targets; navigation occupies a compact icon rail beside the scrollable history. Tasks uses the real task engine. File attachments, pasted text, browsing and coding remain available through Chat without separate sidebar destinations. Drafting an action opens Chat without sending. Home never simulates progress or executes a shortcut immediately.
- Library browses real saved conversations and finished task reports in adaptive cards or compact list rows. All, Conversations, Pinned, Task reports and Archived filters combine with title/preview search and newest/title sorting. All excludes archived conversations; Archived is explicit. Cards open the corresponding saved chat or task report; conversation menus pin, archive and export through existing library operations. New offers Conversation and Task. Attachments remain memory-only and are not presented as saved files.
- Tasks has its own searchable Current and Recent tasks sidebar and an in-panel task conversation/composer.
  New task and the six starter cards draft goals here without contacting the planner or executing tools.
  Draft creation stays available during voice, chat, attachments and active tasks; it does not interrupt
  existing work. Only task-plan submission is blocked by an active request. During the same session's
  in-flight planning submission, draft replacement waits until planning returns. Existing run drafts
  and the separate new-task draft are preserved when navigating between them.
  Sending a goal proposes a plan; Run this plan remains explicit and risky steps keep their own confirmation.
  Each plan/report shows a connected vertical execution flow: numbered nodes, tool, textual live status,
  dependency labels and expandable redacted arguments/output. Arrows show sequential execution order,
  not parallel work or invented dependency edges. Existing empty/planning/failed tasks show their actual state.
  Saved runs can be reopened and followed up in Tasks; a follow-up creates a new reviewable plan using bounded,
  redacted previous-goal/result context. Optional parent/origin metadata restores the thread without breaking
  old task JSON. Missing/cyclic parent links terminate safely. Per-run/new-task drafts remain separate from Chat.
  Tasks-origin results stay in Tasks rather than being appended to an unrelated Chat conversation. Compact
  cards outside Tasks retain their layout. Library has no composer; file drops/pastes keep their explicit Chat
  attachment path. Background scheduling and free-form non-task chat are not implied by this interface.
- On macOS 26+, native Liquid Glass is shared across navigation selections, Home action cards, Settings cards and disclosure controls, task and confirmation surfaces, user message bubbles, attachment chips, composer controls, the command bar and companion labels. Related surfaces use GlassEffectContainer, static content never receives interactive hover behavior, and task cards embedded in another card omit their own glass surface. Workspace and Settings backgrounds use native behind-window vibrancy so wallpaper subtly influences the interface. Buttons use native glass styles while retaining their keyboard, disabled and confirmation behavior. Older systems use regular material and bordered buttons. Reduce Transparency and increased contrast replace glass and window vibrancy with opaque surfaces. Long replies, code blocks and text editors retain readable text treatments.
- Conversation sidebar: a 52-point icon rail for Home, Library and Tasks with Settings at its foot; compact Ivy branding, a search toggle and labeled New chat action; one-line Pinned and Recents lists with neutral selection and visible action menus; a separate Archived folder and workspace selection. Chat opens through New chat, a saved conversation or a drafted action, without a separate rail icon. Full conversation titles, timestamps and previews remain available in tooltips; search results include matching snippets. Archived starts collapsed; clicking anywhere on its header shows or hides its own scrolling list.
- Replies: selectable Markdown, horizontally scrolling code/diff blocks, copy and read-aloud actions. Action buttons briefly pulse on click; Copy shows a checkmark and “Copied” for two seconds, resetting on repeated clicks. Read Aloud immediately shows cancellable “Preparing…” progress, then Stop Reading during playback. Reduce Motion suppresses movement while retaining status feedback. User messages use a subtle indigo-tinted bubble.
- Empty state: a next action for setting up credentials, or suggestions that prefill the composer without sending anything.
- Composer: multiline text, Return to send, Shift-Return to insert a newline; text or attachments enable sending.
- Push-to-talk records while the shortcut is held. Releasing it stops microphone input, drains the last recorded frames and sends the Live API activity-end marker. Fresh PTT connections disable automatic activity detection and send activity-start before the first audio frame; duplicate release and silent input cannot create a second turn. Existing hands-free sessions retain automatic detection and audio-stream-end flushing. Ivy remains connected to answer, then closes after playback or a silent completed turn. Speech captured while connecting is submitted once the socket is ready. A silent press cancels; an existing hands-free session remains continuous. Repeated release never submits twice, and a new hold during thinking, speech or approval interrupts the old session and starts a fresh PTT request. The original playback stops, partial reply transcripts are retained as interrupted, pending approval is denied, and stale events from the old socket cannot reach the new request. Key repeat cannot restart a held request. Release during interruption cleanup is retained; explicit Stop/shutdown or a monitor failure cancels the restart. A silent replacement closes without a turn, and every replacement release closes microphone input.
  Release also closes capture if the server has already started its reply or requested approval, without cancelling either or submitting the same utterance again. Push-to-talk replies use an output-only audio engine so playback cannot reopen the microphone. Session teardown always releases capture-engine resources, including an engine restarted after its input stream closed. Opt-in idle wake listening remains a separate microphone user.
  While a registered PTT shortcut is held, a 50-ms release watchdog checks its actual key/modifier state
  independently of Carbon/flagsChanged callbacks. Releasing the key or a required modifier, or removing
  the shortcut, closes PTT input even if key-up is lost. The watchdog is press-identity-bound and stops
  on release or explicit Stop; it never polls during idle or ordinary hands-free listening. A connection
  failure releases voice resources but retains the hold check until release, preventing key-repeat from
  reconnecting. Stop resets the held state so a missed callback cannot block the next press. The check
  never answers an approval or cancels a reply.
- Live speech uses Gemini 3.8 Live (`models/gemini-3.8-live`) with Google's commercial Tavi voice
  (`en-us-tavi`). Initial setup and reconnects use the same voice ID. Live tool declarations explicitly
  use `BLOCKING` so replies wait for Ivy's existing approval and execution result; REST schemas are
  unchanged. Session setup omits unsupported thinking/proactive/affective options.
- Voice replies have a session/connection/turn-bound inactivity deadline. After PTT release, a turn
  without recognized transcription, a tool call or reply content times out after 8 seconds with a
  retry notice. Once progress is confirmed, 15 seconds without further reply content or completion
  closes the stale session and releases microphone, socket and playback resources. Real reply
  chunks renew the deadline. Empty payloads do not. Approval review, running/queued tools and local
  playback after turn completion are excluded. Tool results start a new reply deadline; interrupted,
  finished or replaced requests cancel old deadlines. No failed request or executed action is replayed.
- Sending waits during a chat response, an approval, a running task, attachment processing or a live voice session. Ending an active voice session remains available.
- Draft text is retained separately for each conversation while the main view is alive.
- Conversation instructions use a multiline sheet and show validation failures in place.
- Storage notices and voice failures are visible. Confirmation state is shared with the existing safety gate; the UI never auto-approves an action.
- Chat and live voice approvals use one centered native sheet, shared with the instructions presentation so sheets never stack. The app-only detailed sheet shows the action title, original explanation and selectable action details in a scrollable review area. Cancel / Do it and the approval notice stay visible in a fixed footer. It is 460×400 points with details or 460×300 without details and fits the minimum workspace window. Long payloads scroll without truncating their content. The companion retains its separate compact reason-only card. Escape refuses the action, and only an explicit click or Command-Return approves it. Responses retain the request identity so an old sheet cannot answer a newer action.

### Settings

- Settings search sits above the section list with 24 points of separation.

- Settings hides the navigation toolbar to remove its empty header space. The selected page heading sits inside the content, with search and section navigation in the sidebar and compact native window controls above.
- Native searchable sidebar with General, Voice, Personalization, Screen, Proactive, Privacy & Data, API Keys, Permissions and About.
- Related controls sit in clearly titled cards with consistent spacing, readable descriptions and native switches. Voice preferences are separated into Live Conversation, Hey Ivy and Read Aloud.
- Personalization disclosure rows are buttons across their full width, including their text and whitespace; clicking the chevron is optional.
- Time zone, measurement system and preferred language come from macOS. Settings shows a read-only “From macOS” summary and only asks for optional name, pronouns and profession. Chat reads regional context for each request, and Live reads it at session configuration. System context overrides legacy manual regional fields in prompts without changing saved profiles or safety-layer precedence.
- Pickers and sliders share one label column, with aligned numeric values; remaining segmented pickers fill the same width and use equal segment widths and a consistent 28-point height. Narrow containers stack the label above the control. Personality (Polite, Light, Ivy, Roast), profile answer length (Brief, Balanced, Detailed), and Live voice pause tolerance, answer length and speaking pace use explanatory single-choice cards with equal widths, a subtle selection tint, outline and checkmark. Narrow containers stack these cards; keyboard focus, arrow navigation, selected accessibility state and increased-contrast outlines remain available. Speaking preferences that require a restart say so in their group.
- Existing secure credential storage and on-demand permission behavior remain intact.
- The old `alwaysShowInDock` preference is decoded for compatibility; Ivy always uses accessory activation and does not appear in the Dock.

### On-screen companion (revised 2026-10-07)
- The primary floating companion appears on launch and is a transparent, chunky pixel-art Ivy with dark hair, an ivy-leaf clip and a charcoal outfit. Character artwork stays in the companion; the main workspace retains its professional design.
- Real idle, listening, thinking, speaking, working, approval and error states choose distinct poses. Idle includes occasional blinking and a brief greeting on appearance; thinking has a skeptical side-eye, working uses a tablet, and approval folds her arms. Speaking reacts to output audio without inventing speech or progress.
- Cached sprite frames animate at a modest update rate, with visible idle breathing, blinking and gentle sway. Dragging adds a small lift, bob and tilt; non-idle activity poses remain recognizable and speaking still follows actual audio. Reduce Motion pauses the timeline and uses a static pose even during dragging; status text, captions and real task progress remain available.
- When shown while idle, Ivy occasionally checks a phone, types on a laptop or blushes with her hands
  clasped together at her chest using additional
  matching pixel-art frames. A seed chosen for each idle episode gives repeatable frame sampling with
  random activity/timing: one 8–11-second moment per 48-second window, after 12–24 seconds of quiet.
  Blushing uses a gentle four-frame blink/cheek-colour loop over eight seconds. Dancing remains removed.
  These are decorative; status stays Ready,
  no tools or devices are accessed, and real activity/approval or dragging takes priority immediately.
  Hidden companions pause animation; Reduce Motion uses the ordinary static idle pose. Returning
  to idle or turning motion back on starts with a quiet interval rather than resuming an interrupted activity.
- Drag the character or status pill freely; a four-point threshold distinguishes dragging from clicking. A drag never opens the app. Dropped positions are remembered relative to their display and clamped by visible content bounds, allowing the character and status pill to reach the screen edges despite the panel's transparent margins. Bounds adapt when captions change size; a main-display fallback handles a saved display disappearing. There is no automatic corner snap. The panel is non-activating; a normal click opens Ivy and right-click provides Open Ivy, end voice, stop task and hide actions. Animation stops while hidden. All approvals remain in the existing confirmation flow.
  AppKit's full-window top-edge constraint is overridden for this transparent companion panel;
  the controller owns visible-content clamping. Empty panel space may extend above the display,
  while the character, caption and approval controls remain below the menu bar in the usable area.
- A pending chat/task or Live tool approval replaces the companion's status pill below the character
  with only its action reason and Do it / Cancel buttons in a 228×88-point bubble. Script/command tools
  include a plain-language `reason` describing the goal and material changes; the companion displays
  that reason instead of a generic execution title. The app keeps the technical title, purpose and full
  script/command. Reasons are whitespace-normalized and credential-redacted; older calls without one
  show a neutral requested-script/command fallback. A reason never authorizes execution. The compact reason
  uses smaller medium-weight type; both buttons have equal widths and 28-point targets with readable
  neutral/accent text even when the panel is inactive. Approval and speech/error bubbles use opaque
  adaptive surfaces and a subtle outline, as do status pills, so desktop colours cannot wash out their text. Speech captions
  are left-aligned at 13 points with comfortable line spacing; status pills use 12-point type. The original request
  is available on hover, keeping long commands out of the default bubble. It mirrors the same
  identity-bound request as the main-window sheet; it never creates or approves another request.
  Showing, dragging, hiding or clicking the character does not approve. Buttons stay outside the drag
  surface, and repeated/stale responses are ignored. The panel grows while reviewing and returns to its
  normal size afterward, keeping its complete visible content inside the selected display. When the
  companion is disabled/hidden, the existing main-window approval remains available. In background mode the workspace sheet is suppressed so it cannot bring back the hidden window; hiding an existing sheet hands the same pending request to the companion instead of denying it. Reopening the workspace restores its detailed review if the request is still pending.

---

## 6. Tool / Function-Calling Architecture (Phase 2+)

Tools are declared via JSON Schema in `tools: [{functionDeclarations: [...]}]`:
1. `run_applescript(script: String)`
2. `open_app(name: String)`
3. `run_shell(command: String)`
4. `calendar_event(title: String, date: String)`
5. `file_op(action: String, path: String)`

Application lookup prefers the exact installed bundle name (case-insensitive, with optional `.app`).
Known names `VS Code`/`vscode` resolve to `Visual Studio Code.app`; `VS Code Insiders` resolves
separately to `Visual Studio Code - Insiders.app`. Aliases search the existing system/user application
directories and never install software, use fuzzy matches or substitute another edition.

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

Confirmation uses a native sheet in the desktop window or an in-popover confirmation banner in the legacy popover. If cancelled, the tool returns `"User cancelled operation with prejudice."` to Gemini.

---

## 8. Persistence Design (Phase 5+)

- **API Key Storage**: Stored exclusively in the macOS Keychain under service name `com.ivy.assistant`, key `gemini_api_key`. Never written to `UserDefaults` or disk files.
- **Session History Storage**: Persisted to Application Support directory: `~/Library/Application Support/Ivy/history.json`.
  - Serialized via `JSONEncoder(outputFormatting: .prettyPrinted)`.
  - Loaded on app launch so conversation continuity is preserved across restarts.

---

## 9. Permissions & Entitlements (Phase 6+)

### Info.plist Keys:
- `LSUIElement = YES`: Runs as a companion/menu-bar Mac app; the workspace is available on demand.
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
- [ ] Ivy launches/reopens into companion mode without a workspace, Dock icon or Command-Tab entry.
- [ ] Work in Background and closing the workspace preserve running voice/chat/tasks and show companion progress/approval. Suggestions do not reopen it. Open Ivy/companion restores the workspace; Quit shuts down.
- [ ] The menu bar Open Ivy action and companion open the same workspace.
- [ ] User can enter an API key via UI or environment variable (`GEMINI_API_KEY`).
- [ ] Sending a message sends the turn history + Ivy system prompt to `gemini-3.8-flash`.
- [ ] Model responds in Ivy's distinctive sarcastic tone and appears in the chat scroll.
- [ ] Error states (invalid key, network offline) display helpful, in-character alerts.

### v1.1 release integration (2026-10-03)
- Display-only, session-scoped tool cards show redacted arguments, status and bounded output in chat;
  cards link to their triggering user message and appear directly below it, even when a Live voice
  transcription arrives after execution starts. Late chunks of that voice turn merge into one user
  message with stable identity. Missing/unsaved transcripts and legacy unlinked cards retain
  chronological placement; request links do not persist raw card payloads.
  raw tool payloads never enter persisted history or request context. Chat/tasks/Live share display events.
- Diff Apply opens a target sheet and appends a reviewable file_op proposal to the existing composer;
  the actual write still requires SafetyGate approval and the full updated file, not a diff as content.
- Command Bar local ⌘⇧S attaches the front non-Ivy window to the shared reviewed tray. Capture does not send;
  submission is blocked by active voice/tasks, capture work or pending approvals.
- point_at draws a click-through screen-edge arrow, highlight and label on the relevant display.
- Screen guidance uses the shared image's actual pixel dimensions and screenshot_id. A request with several
  eligible captures must identify its target; files and text-only images cannot reuse a previous desktop mapping.
  Captures are still explicit, and only sending an attachment makes its mapping available to point_at.
- Permission-denied screen captures show a readable explanation, Open Settings and explicit Retry Capture.
  Opening Settings never retries or sends a capture automatically.
- Annotation arrows enter from the screen edge over 0.35 seconds; Reduce Motion shows the complete arrow
  immediately and removes the highlight pulse. Labels and highlights remain click-through for six seconds.
- Before production stores load, v1.1 secures a one-time v1.0 durable-data/settings backup. Backup failure
  uses temporary stores with a visible warning, without loading/migrating original data. Keychain is excluded.
- Marketing version 1.1.0; build 1 is the original release, build 2 adds the screen-guidance follow-up.
  Friend-testing packaging preserves old DMGs; notarization remains deferred.

---

## Pointer removal and global voice contract (2026-10-05)

- The Pointer Settings page, cursor-follow visual, hover/freehand/rectangle selector and shared
  voice-selection callbacks are removed at the user's request. Old Pointer preference keys are ignored
  when decoding settings and are omitted on the next save.
- Push-to-talk is voice-only from any app. Keyed hotkeys register and receive notifications at the
  Carbon dispatcher target before application handlers; each manager handles only its own identity.
- Enabling/disabling push-to-talk updates the global registration immediately. Disabling during a held
  press uses the existing release watchdog to close capture without approving or cancelling a reply.
- Explicit screen attachments and screen-help tools continue using their existing permission and review flow.
- Build 3 adds a persisted choice of ⌘⇧Space (default) or ⌃⌥⌘Space for voice-only PTT.
  Changing the key re-registers immediately and ends any old held press without closing a newer press.
  Production PTT registration requests exclusive ownership; a conflict remains unregistered and its
  error is visible in General settings. Existing settings recover to the default when the choice is
  absent, unknown or wrongly typed. A ready label confirms registration, not microphone/network health.
  No extra keyboard-monitoring permission, screen selection or automatic fallback is introduced.
- Build 4 treats Carbon press/release callbacks as authoritative. Physical-state polling only
  infers a missed release after observing the key or modifiers held during that specific press;
  unobserved state is unknown, not released. Press notifications reset this evidence and remain
  deliverable after Stop; the coordinator ignores duplicate starts. Actual release, disabling PTT
  and explicit Stop still close input. If both physical
  inspection and release delivery are unavailable, use Stop; polling cannot prove that release.

## 13. Computer Control Architecture (Phase 19)

The following describes the computer-control subsystem design and source components. It is not a
shipped capability: the production `IvyAppEnvironment` does not configure a `ComputerControlCoordinator`
on its `TaskEngine`, so adaptive desktop runs fail without that dependency. Source/fixture tests do not
establish real-app or hardware acceptance. Integrate and verify the entry points before claiming completion.
The removed Pointer visual and hover/circle selectors remain outside this design's scope:

1. **Explicit Session Authorization & Exclusivity**:
   - Desktop control requires explicit user consent scoped to a specific target application and window.
   - The session model enforces strict validity tokens; expired, stopped, or paused sessions cannot emit input events.
   - Exclusivity: Enforces a single desktop-input lane (`isDesktopControlActive`). Concurrent desktop sessions cannot race and are rejected with explicit user-facing conflict explanations.
   - Intended entry points: Main Window Chat (`/desktop <goal>`), Command Bar and Gemini Live Voice. Their production coordinator/tool wiring and end-to-end acceptance remain pending.

2. **SafetyGate Invariants & Injection Defense**:
   - All synthetic input actions (`ui_click`, `ui_type`, `ui_key`, `ui_scroll`, `ui_move`, `ui_drag`) default to risky and require exact SafetyGate confirmation or explicit session bounds.
   - Physical takeover: Physical user input (mouse movement, key press) or focus change immediately pauses the session and yields control without cursor fighting.
   - Voice safety: Voice interaction cannot approve risky action cards; approval requires direct user interaction with the confirmation sheet.
   - Prompt injection defense: Adversarial text embedded within document bodies or web pages cannot expand authorization scope, bypass confirmation, or trigger unapproved actions.
   - Prohibited applications: Credential surfaces, security dialogs, and system utilities (`Keychain Access`, `System Settings`, `CoreAuthUI`, `SecurityAgent`, `loginwindow`) are strictly barred from computer control.

3. **Observation & Target Verification**:
   - Element inspection uses bounded, asynchronous Accessibility (`AXUIElement`) traversal with strict node limits (200), depth bounds (10), and 5-second timeouts.
   - Coordinate transforms handle Retina (2x) and standard (1x) display scaling, multi-monitor topologies, and negative virtual screen origins.
   - Target freshness verification validates coordinates prior to execution (5-second TTL). Moved, covered, or missing elements invalidate requests and require fresh observation.
   - Result verification: API event return does not constitute task success. Verified outcomes require visible state transitions in post-observation snapshots; ambiguous states are classified as uncertain and prohibited from automatic repeated submission.

4. **Ephemeral Observation & Redaction**:
   - Screenshots and accessibility trees are strictly ephemeral in memory and are never serialized to disk, task stores, or chat export logs.
   - Tool card presentation (`ToolActivity`) and persistent task records (`TaskStep`, `TaskRun`, `FileTaskStore`) mask typed text in `ui_type` and replace observation payloads with redacted placeholders.

5. **Measured Limits & Platform Support**:
   - **Supported OS**: macOS 14.0+ (Sonoma) and macOS 15.0+ (Sequoia).
   - **Tested Architecture**: Apple Silicon (`arm64`); Intel (`x86_64`) untargeted and untested.
   - **Windows / Linux**: Explicitly unsupported (macOS native AppKit / CoreGraphics only).
   - **Execution Budgets**: 20 actions/steps, 40 total primitive calls (including observation), 15-minute duration cap, and maximum 2 replans per task run.
   - **Offline Reliability Evaluation**: The 30-task fixture evaluation models Calculator, TextEdit, a local browser, Finder and safety edge cases; it is not real-app acceptance:
     * Task completion / safe gate enforcement rate: 100% (30 / 30, target ≥90%).
     * False success rate: 0%.
     * Wrong-app input rate: 0%.
     * Confirmation bypass rate: 0%.

6. **Distribution & Packaging**:
   - Release builds packaged via `scripts/package-release.sh`.
   - Friend-test builds packaged via `scripts/package-friend-test.sh`, generating standalone testing DMGs under `dist/Previous-Builds/Friend-Test-Computer-Control-<date>/` while preserving release artifacts.
   - Signing: Developer ID, Apple Development, or ad-hoc (`-`) with Hardened Runtime and minimal entitlements. Notarization is deferred for friend-test builds (requires manual Gatekeeper override via right-click Open).
