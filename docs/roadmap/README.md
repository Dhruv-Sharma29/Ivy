# Ivy v1.1 Roadmap

Current source audit and prioritized backlog: [remaining work](../../tasks/remaining.md). Historical phase checklists may predate the desktop UI and later integration fixes.

Planned next capabilities: [Phase 19 — Computer Control](phase-19-computer-control.md) and
[Phase 20 — Assistant Workspace](phase-20-assistant-workspace.md). Together they cover Mac input,
adaptive tasks, a floating panel, generated files, routines, dictation, specialists, a compact overview,
walkthroughs and connectors. Phase 20 specifies the combined build order. These features are planned,
not shipped; the first milestone is reviewed Calculator/TextEdit control with a shared floating panel.

v1.0 (Phases 1–7) shipped the core: menu-bar chat on Gemini REST, five SafetyGate-guarded macOS tools,
ElevenLabs TTS, Gemini Live voice (Kore) with "Hey Ivy" barge-in and idle wake, ⌘⇧Space push-to-talk,
Keychain credentials, persisted settings/history, hardened-runtime signing and notarization.

v1.1 turns Ivy from a capable menu-bar utility into a real Mac companion app: reliable, context-aware,
screen-aware, agentic, and with a proper app window of its own.

| Phase | Plan | One-line goal |
|---|---|---|
| 8 | [Production Hardening](phase-08-production-hardening.md) | Nothing Ivy does today should fail silently, leak resources, or need a relaunch to recover. |
| 9 | [Smarter Conversations](phase-09-smarter-conversations.md) | Many conversations, searchable and organised, with context that stays sharp over long chats. |
| 10 | [Advanced Voice](phase-10-advanced-voice.md) | Voice that feels like talking to a person: fast, interruptible, resilient. |
| 11 | [Expanded macOS Tools](phase-11-macos-tools.md) | A broad, safe native toolset behind the same validation → SafetyGate pipeline. |
| 12 | [Proactive Ivy](phase-12-proactive-ivy.md) | Opt-in reminders, briefings and follow-ups — Ivy speaks first, but never acts alone. |
| 13 | [Personalization](phase-13-personalization.md) | Ivy adapts to you (tone, length, shortcuts) without storing anything sensitive. |
| 14 | [Vision & Screen Intelligence](phase-14-vision-screen-intelligence.md) | "What am I looking at?" — screenshots, regions, OCR, images, PDFs; on hotkey only. |
| 15 | [Agentic Workflows](phase-15-agentic-workflows.md) | Multi-step tasks with a plan, checkpoints, verification and recovery. |
| 16 | [Developer Mode](phase-16-developer-mode.md) | Git, builds, tests, logs, PRs — a project-aware pair programmer. |
| 17 | [UI/UX 2.0](phase-17-ui-ux-2.md) | A native Ivy workspace: chat window, sidebar, on-screen companion and onboarding. |
| 18 | [Final Integration & Release](phase-18-final-integration.md) | Regression, audits, signed/notarized v1.1.0, changelog, tag. |

## Planned extensions after the current release

| Phase | Plan | Goal |
| --- | --- | --- |
| 19 | [Computer Control](phase-19-computer-control.md) | Scoped Mac clicking/typing, adaptive execution, verification and cancellation. |
| 20 | [Assistant Workspace](phase-20-assistant-workspace.md) | Eight selected Ivy additions, with shared foundations and milestone releases. |

Both phases are unimplemented. Their numbering does not assign a release version or alter the existing DMG.

## Recommended order

Numbering is kept as agreed, but a few dependencies shape the build order:

```text
8 Hardening ──► 9 Conversations ──► 17a App shell (window + sidebar) ──► 10 Voice
                                                 │
                                                 ├──► 11 Tools ──► 16 Developer Mode
                                                 ├──► 13 Personalization
                                                 ├──► 14 Vision ──► 17b On-screen companion
                                                 └──► 15 Agentic ──► 12 Proactive
                                                                        │
                                              17c Polish & onboarding ◄─┘ ──► 18 Release
```

- **Phase 17 is split** into 17a (app shell: main window, conversation sidebar — built right after Phase 9 so
  every later phase has a place to put its UI), 17b (the on-screen companion, after Phase 14), and 17c
  (onboarding, animation, accessibility polish, last).
- **Phase 15 before 12**: proactive features reuse the task engine and its approval checkpoints.
- **Phase 11 before 16**: developer tools are specialised Phase 11 tools.

## Invariants every phase must keep

1. **SafetyGate is authoritative.** Every tool call: Gemini → argument validation → safety classification →
   SafetyGate → explicit user confirmation if risky → execution → result → Gemini. Natural language, voice,
   macros, plans, schedules and personalization can never approve a risky action.
2. **Kore stays the locked Live voice** (`models/gemini-3.1-flash-live-preview`). ElevenLabs stays for TTS.
3. **Privacy by default.** Microphone, screen and background features are opt-in, visibly indicated, and
   on-device wherever possible. Screenshots and audio are never persisted.
4. **Secrets live only in the Keychain.** Never in settings, history, logs, exports, prompts or files.
5. **Swift 6 strict concurrency, zero warnings, no new SPM dependencies without asking first** (SPEC §11).
6. **Deterministic tests.** No real network, microphone, Keychain, TCC or clock in unit tests; poll with
   timeouts instead of fixed sleeps. Full suite < 60 s (CONSTRAINTS.md).
7. **Nothing starts on launch** (mic, Live, screen capture, tools, speech) unless the user opted into it.

## How each phase runs

```text
Claude  → implementation (incremental slices, tests with each slice)
AGY     → test-driven-development (independent tests against the plan's acceptance criteria)
You     → manual test (each plan ends with a checklist)
AGY     → code-review-and-quality
```

Every plan follows the same shape: goal, baseline, scope, design, work breakdown (slices with acceptance
criteria), safety/privacy, testing, risks, exit criteria, manual checklist.

## Hardening follow-ups after Phase 12 (2026-10-01)

Found in a full code review; tests in `Tests/IvyTests/HardeningFollowUpTests.swift`.

| Fix | Where |
|---|---|
| Tools are **risky unless they declare otherwise** (the protocol default used to be safe) | `Tools/IvyTool.swift` |
| `file_op` refuses credential files (`.netrc`, `.git-credentials`, `.npmrc`, `.docker`, `.kube`, `.config/gh`, `.env`, …), shell history and private app data (cookies, Safari, Messages, Mail, browser profiles, Ivy's own data). Contents are not redacted on read, so a read-edit-write never destroys a real secret | `ToolValidation.prohibitedPathSegments` |
| Live: several tool calls in one turn are **queued**, each with its own card (the first used to be denied silently); the server's `toolCallCancellation` denies a waiting card and skips queued calls | `GeminiLiveVoiceCoordinator`, `LiveEvent.toolCallCancelled` |
| `run_shell`: output is collected asynchronously; a timeout kills the **whole process tree** (libproc); a background child holding the pipes no longer hangs the call | `SystemShellExecutor` |
| REST Gemini key is sent in the `x-goog-api-key` header only, never in the URL | `URLSessionGeminiClient` |
| Deleting the conversation from the header asks first | `IvyPopoverView` |

Fixed in the 2026-10-03 integration batch: HTTP 400 now reports `invalidRequest` unless Google identifies an invalid key. Offline tests still use 400 as a generic request failure, without recommending credential replacement.

Known follow-up: AppleScript still runs on the main actor (`NSAppleScript` isn't thread-safe; moving it means an `osascript` process).
