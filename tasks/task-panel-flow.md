# Task conversations and execution flows — 2026-10-07

The current package is build 7, which retains these changes and adds the app-name lookup fix
and [idle companion animations](companion-idle-animation.md). The verification below describes build 5.

## Delivered in 1.1.0, build 5

Tasks now contains its own goal composer and conversation. New task, the task starter cards,
and `/agent` prompts open this panel. Starter cards only draft a goal; sending requests a plan,
and Run this plan remains a separate decision. Ordinary Chat keeps its own draft and messages.

Each live or saved plan shows numbered steps connected by arrows. The diagram represents the
engine's sequential execution order; dependency labels show explicit prerequisite step IDs.
It does not imply parallel execution. Every node shows its tool and status, with expandable,
redacted arguments and output. Failed and skipped steps include their reason. Empty plans show
their actual state instead of invented steps. Both narrow layouts and light/dark appearances
were checked using native SwiftUI rendering.

Follow-ups stay in Tasks and give the planner the preceding goal, outcome and step outputs.
That context is redacted and limited to 4,096 characters. Each follow-up requires a fresh plan
review and does not inherit permission to execute. Destructive actions still use SafetyGate.
Parent task IDs and the task-workspace origin persist alongside existing task history, and
older records without these fields still decode. Workspace task reports do not append to
ordinary Chat. Drafts are retained independently for the new task and each selected task
while the session remains open.

## Scope and limits

- The conversation is a chain of task goals, plans and results; general conversation remains
  in Chat. A goal starts planning rather than an unrestricted background chat request.
- History retains the engine's existing 20-run limit. A parent no longer in history ends the
  visible chain. Missing parents and cycles are handled without looping.
- The change does not implement concurrent tasks, recurring execution or the separately
  planned floating task panel. Approval and tool execution policies are unchanged.
- Automated checks use offline planner/tool fixtures. Live provider execution and physical
  cross-app keyboard/microphone acceptance were not performed for this UI change.

## Verification

- Strict Swift 6 debug build passes with no compiler diagnostics; warm build: 0.19 s.
- `swift test` passes: 1,298 core tests in 182 suites (4.333 s) and 31 native UI tests in
  5 suites (35.909 s), totaling 1,329 tests.
- Changed executable line coverage: 358/388 (92.27%), combined across core and UI binaries.
- Tests verify no tools execute while drafting or waiting for plan review, fresh follow-up
  review, prior-output context, independent drafts, persistence compatibility, missing/cyclic
  parents, planning errors, redaction, context bounds and isolation from Chat.
- UI checks cover new tasks, initial `/agent` routing, selected history, all step statuses,
  expanded details and empty flows at narrow and wide widths in light and dark appearances.
- `git diff --check` passes. No tests were removed or skipped.

## Package

- `dist/Ivy.app` and `dist/Ivy-1.1.0.dmg`: 1.1.0, build 5, Apple silicon (`arm64`).
- Release build: 37.87 s, no compiler warnings/errors. Package credential scan: zero leaks.
- Ad-hoc signature with Hardened Runtime; Apple notarization is not configured.
- Deep/strict signature verification, DMG integrity and SHA-256 sidecar pass. A read-only
  mount verified build metadata, an identical executable and the Applications link, then
  the verification volume was ejected.
- DMG SHA-256: `39aaf26f714b2bc87082df4395d2a89a5587e63bd6eb16e4942426676b6a952e`.
- Executable SHA-256: `a0264525be2d86b91ac85622446e241624e0de0ac06188280272bdd72d35ba14`.
- Build 4 backup: `dist/Previous-Builds/Before-Task-Panel-Build5-2026-10-07-ziOkxd/`.

## Try it

Quit the older copy and replace it with the app from the new DMG. About should show build 5.
Open Tasks → New task, type a goal, and send. Review the connected steps, then choose Run this
plan. Expand Details to inspect inputs and outputs as statuses change. After completion, send
a follow-up in the same composer; its new plan appears in the task conversation. Select an
older task in the sidebar to reopen its saved flow. Start another new task to check its draft
is independent of ordinary Chat.

The installed app, user data, macOS permissions and GitHub release were not modified.
