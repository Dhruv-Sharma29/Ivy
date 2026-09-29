# Phase 11 — Expanded macOS Tools

## Goal
Give Ivy a broad set of native capabilities, each one built on the same pipeline and each one as safe as the
five v1.0 tools.

```text
Gemini → argument validation → safety classification → SafetyGate → user confirmation if required
       → tool execution → structured result → Gemini
```

## Baseline
- Tools: `open_app` (safe), `run_applescript`, `calendar_event`, `file_op` (read safe; write/delete risky),
  `run_shell` (all risky). `IvyTool` protocol: `name`, `declaration`, `safetyClassification`,
  `validate(arguments:)`, `execute(arguments:)`; executors behind protocols (`WorkspaceProtocol`,
  `CalendarExecutorProtocol`, …) with mocks; `ToolRegistry.defaultRegistry`; `InteractiveSafetyGate` builds
  in-character `ConfirmationRequest`s; `ToolValidation` centralises path/argument checks.
- Every tool declaration is sent on every request (fine for 5, costly for 30).

## Scope
**In:** the tools below, a registry that scales (tool groups), per-tool permission handling, per-call
classification (e.g. read vs write), result redaction. **Out:** screenshots/vision analysis (Phase 14 builds
on the screenshot tool here), git/dev tools (Phase 16), third-party service APIs beyond Apple apps.

## Framework changes (slice 11.0)
1. **Per-call classification** already exists (`policy.classification(for:call:)`); formalise it on the
   protocol: `func classification(for arguments:) -> ToolSafetyClassification` (default = static).
2. **Tool groups & dynamic declarations:** `ToolGroup` (core, system, productivity, media, files, …). The
   brain sends core tools always and other groups when relevant (keyword router on the user message +
   "the model asked for a group" meta-tool `enable_tools(group)`), keeping requests small.
3. **Permission requirements** on each tool: `requiredPermissions: [PermissionType]`; the dispatcher checks
   *after* confirmation and before execution, returning a structured `permissionDenied` result with a
   recovery hint (Phase 8.4 deep link) — never prompting before the user approved.
4. **Result shaping:** `ToolResult` gains `summary` (for tool notes, Phase 9) and a size cap (8 KB) with
   truncation markers; sensitive fields redacted before returning to Gemini where noted.
5. Confirmation copy per tool (in character, but always stating exactly what will happen).

## Tool catalogue

| Tool | Actions | Classification | Permission / API | Key validation & limits |
|---|---|---|---|---|
| `clipboard` | read, write | read: **risky** (may hold secrets; confirm, redact keys in result); write: risky | `NSPasteboard` | text only; write ≤ 100 KB |
| `notify` | post local notification | safe | UserNotifications (auth on first use) | title ≤ 80, body ≤ 250 chars; rate limit 5/min |
| `finder` | reveal, open folder, get selection | safe | NSWorkspace / AppleScript (Finder) | path validation via `ToolValidation`; selection returns paths only |
| `file_search` | name/content search | safe (read-only) | `NSMetadataQuery` (Spotlight) | scope to user-home by default; ≤ 50 results; excludes Keychains/Library secrets paths (reuse Phase 3 deny-list) |
| `screenshot` | capture screen/window/region to memory | risky (screen content) | ScreenCaptureKit + Screen Recording TCC | never written to disk unless user asks to save; Phase 14 uses it for analysis |
| `window` | list, focus, move/resize, tile | list/focus safe; move/resize risky-low (confirm once per task) | Accessibility (AX) | only on-screen windows; validates bounds |
| `system_settings` | open a Settings pane | safe | URL schemes | allow-list of pane identifiers |
| `media` | play/pause/next/previous, now playing | safe | MediaRemote-free: AppleScript to Music/Spotify, media keys via `NSEvent` | allow-listed apps |
| `volume_brightness` | get/set output volume, mute, display brightness | safe (reversible) | CoreAudio / DisplayServices-free AppleScript for volume; brightness via IOKit public API where available | clamp 0–100; brightness may be unsupported → structured error |
| `network_bluetooth` | Wi-Fi on/off/status, Bluetooth status | status safe; toggling **risky** (can cut Ivy's own connection) | CoreWLAN (status), `networksetup` via shell executor | toggling Wi-Fi off warns that Ivy will lose connection |
| `reminders` | list, create, complete | list safe; create/complete risky | EventKit reminders (full access) | same date parsing as `calendar_event`; confirmation shows list + due date |
| `notes` | search, read, create | search/read safe-ish (**risky** read of full note body? → confirm once per note); create risky | AppleScript (Notes) + Automation TCC | body ≤ 10 KB; HTML sanitised |
| `contacts` | find (name → phone/email) | **risky** (personal data; confirm each lookup) | Contacts framework (`CNContactStore`) | returns only requested fields; ≤ 5 matches |
| `mail` | draft (compose window), search inbox headers | draft risky (never auto-send); search risky | AppleScript (Mail) / `mailto:` | **no send action**: Ivy opens a draft, the user presses Send |

Explicitly **not** provided: sending mail/messages directly, deleting reminders/notes/contacts, changing
security/privacy settings, keychain access.

## Per-tool slice template
For each tool: declaration + validation (with fuzz-style invalid-argument tests), executor protocol + system
implementation + mock, classification tests, confirmation copy, permission-denied path, result shaping,
manual test line. Order: notify → clipboard → finder → file_search → system_settings → media →
volume_brightness → reminders → window → screenshot → notes → contacts → mail → network_bluetooth.

## Info.plist / entitlements
New usage strings: `NSRemindersFullAccessUsageDescription`, `NSContactsUsageDescription`, screen recording
(prompted by ScreenCaptureKit), Accessibility (for `window`), plus Automation per app (existing
`NSAppleEventsUsageDescription`). Entitlements: `personal-information.addressbook`, `personal-information`
reminders via calendars entitlement; document each in `docs/PERMISSIONS_AND_SANDBOX.md`.

## Safety & privacy
- Every new tool has a SafetyGate classification test and a "natural language cannot approve" test.
- Personal-data tools (contacts, notes read, clipboard read, mail search) are risky by default and return the
  minimum fields; results are redacted before reaching Gemini where they may contain secrets.
- Tool notes (Phase 9) for personal-data tools store only "looked up a contact" — never the data.
- Rate limits per tool (notifications, Wi-Fi toggles) to stop model loops.

## Testing
- Mocks for every executor; no real TCC in tests.
- Dispatcher tests: permission check happens after confirmation and before execution.
- Registry tests: dynamic groups keep the default request ≤ N declarations.

## Risks
| Risk | Mitigation |
|---|---|
| Too many declarations confuse the model | Tool groups + router; eval set of 50 prompts for tool selection accuracy |
| Private APIs tempting for media/brightness | Public APIs or AppleScript only; unsupported → structured error |
| Accessibility permission for windows | Only requested when `window` is first confirmed |

## Exit criteria
All catalogue tools implemented with tests, docs and manual lines; tool-selection eval ≥ 90 % on the 50-prompt
set; no regression in v1.0 tool tests.

## Manual checklist
- [ ] "Remind me to call mom tomorrow at 6" → confirmation → reminder in Reminders.
- [ ] "What's on my clipboard?" → confirmation → contents (fake key redacted).
- [ ] "Find my resume PDF" → results from Spotlight.
- [ ] "Tile Safari left and Notes right" → Accessibility prompt once → windows tiled.
- [ ] "Email John the notes from today" → Mail draft opens; nothing sent.
- [ ] "Turn off Wi-Fi" → warning + confirmation; Cancel does nothing.
- [ ] Deny Contacts → clear message with a link to Settings.
