# macOS Permissions, Entitlements & Sandbox Architecture (Phase 6)

## 1. Distribution & Sandbox Decision

### Production Target: Developer ID + Hardened Runtime
Ivy is a native macOS pair-programming assistant that executes shell commands (`run_shell`), manipulates files in arbitrary user-specified workspaces (`file_op`), opens applications (`open_app`), and executes automation scripts (`run_applescript`).

#### Evaluation of Mac App Store (App Sandbox)
If Mac App Store App Sandbox (`com.apple.security.app-sandbox = true`) were enabled:
1. **Shell Execution (`run_shell`)**: Apple Sandbox forbids child process invocation of arbitrary CLI tools outside the sandbox container (`/bin/zsh`, `git`, `swift`, `cargo`, compilers). Sandboxed apps cannot act as general coding assistants.
2. **Arbitrary Filesystem Access (`file_op`)**: Sandboxed apps are confined to `~/Library/Containers/com.ivy.assistant/Data/`. Accessing user project directories (e.g. `~/Desktop/Coding/...`) requires interactive `NSOpenPanel` user selection for security-scoped bookmarks. An agentic assistant performing multi-file edits cannot present a GUI file-picker prompt on every read/write.
3. **AppleScript & Automation (`run_applescript`)**: Scripting target applications via Apple Events is blocked unless individual static temporary exception entitlements are declared in advance for every target bundle ID.
4. **Push-to-Talk Global Hotkey (`GlobalHotkeyManaging`)**: Modifier-only chords (`Option + Control`) require Accessibility permissions (`AXIsProcessTrusted`), which sandboxed apps cannot prompt for or use.

#### Conclusion
Ivy uses **Hardened Runtime (`--options runtime`) with Developer ID signing and Apple Notarization**, the standard macOS architecture for developer utilities (comparable to VS Code, Raycast, Docker, Terminal, and Antigravity).

---

## 2. Production Entitlements (`Ivy.entitlements`)

| Entitlement | Value | Rationale |
|---|---|---|
| `com.apple.security.network.client` | `true` | Outbound network connectivity for Gemini REST, Gemini Live WebSocket, and ElevenLabs TTS. |
| `com.apple.security.device.audio-input` | `true` | Microphone capture for real-time Gemini Live conversational streaming. |
| `com.apple.security.personal-information.calendars` | `true` | EventKit calendar scheduling for the `calendar_event` tool. |
| `com.apple.security.automation.apple-events` | `true` | AppleScript automation for the `run_applescript` tool (prompts per target application). |

---

## 3. TCC Permission Lifecycles & Usage Descriptions

All permission usage descriptions are defined in `Info.plist`:

| Privacy Key | Description Text | Trigger Condition |
|---|---|---|
| `NSMicrophoneUsageDescription` | *"Ivy needs access to your microphone for live voice conversations."* | Only requested when user starts a Gemini Live or PTT session. Never at launch. |
| `NSSpeechRecognitionUsageDescription` | *"Ivy uses speech recognition to detect the 'Hey Ivy' wake phrase for interruption."* | Only requested when a voice session connects. Never at launch. |
| `NSCalendarsUsageDescription` | *"Ivy needs access to your calendar to schedule events on your behalf."* | Only requested when the user confirms and executes a `calendar_event` tool call. |
| `NSCalendarsFullAccessUsageDescription` | *"Ivy needs access to your calendar to schedule events on your behalf."* | macOS 14+ full access key for EventKit event creation. |
| `NSAppleEventsUsageDescription` | *"Ivy needs permission to automate macOS applications on your behalf."* | Only requested when the user confirms and executes a `run_applescript` tool call. |

---

## 4. Permission State & Graceful Degradation

- **Microphone Denied**: Live session immediately transitions to `.error("Microphone access was denied...")`. Audio engine and tasks are cleanly torn down.
- **Speech Recognition Denied / Unavailable**: Under `swift run` or when permission is denied, `isWakePhraseAvailable` is marked `false`. Live voice continues working via Push-to-Talk; the UI displays informative status (`"Hey Ivy" needs Ivy.app`).
- **Calendar Denied**: Tool execution fails cleanly with `CalendarError.permissionDenied`. Error is returned to the model as a structured `ToolResult` without crashing.
- **Automation Denied**: Apple Events error `-1743` (`errAEEventNotPermitted`) is caught and translated to a clear instruction guiding the user to System Settings.

## Phase 11 tools: permissions added

Every permission below is requested only after the user has approved the specific tool call that needs it
(`ToolDispatcher`: validation → SafetyGate → permission → execution). Nothing is requested at launch.

| Permission | Tool (actions) | Declared by | Notes |
|---|---|---|---|
| Reminders | `reminders` (all) | `NSRemindersUsageDescription`, `NSRemindersFullAccessUsageDescription` | EventKit; covered by the existing calendars entitlement |
| Contacts | `contacts` | `NSContactsUsageDescription`, entitlement `com.apple.security.personal-information.addressbook` | Every lookup is confirmed; only phone/email, at most 5 people |
| Screen Recording | `screenshot` | prompted by macOS (no usage string) | Image stays in memory unless the user asks to save it |
| Accessibility | `window` (move, tile) | prompted by macOS | Not needed for `window` list/focus |
| Notifications | `notify` | prompted by macOS on first use | Requires the app bundle |
| Automation (existing) | `notes`, `mail` search, `media`, `finder` selection | `NSAppleEventsUsageDescription` | macOS asks once per target app |

Not used: Location (so the Wi-Fi network name may be unavailable), Bluetooth (status comes from
`system_profiler`), Full Disk Access. When a permission is refused the tool returns a structured
`permissionDenied` result with the Settings deep link; Ivy never retries the prompt on its own.

## Phase 14: screen help

Screen Recording (prompted by macOS on first capture) is also used by "What am I looking at?" (⌃⌥⌘S), the 📎
capture menu and the region selector. Every capture follows a user action; none runs on a timer. Text recognition
is on-device (Vision). No new usage string or entitlement is needed.
