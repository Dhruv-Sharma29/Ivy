# Remaining work

Updated 2026-10-08 for the v1.1.0 build-24 friend-testing build. Original phase checklists are acceptance criteria,
not proof that every proposed feature has shipped. See [CHANGELOG](../CHANGELOG.md) for implemented scope.

## Implemented in this release

- Build 24 fixes the companion upper drag limit by allowing transparent panel space above the
  display. Visible content retains the existing screen bounds. See [verification](companion-top-edge.md).

- Build 23 shows script/command purposes in the compact companion approval; the app retains
  complete payload review. See [verification](script-approval-purpose.md).

- Build 22 explicitly marks PTT audio activity start/end; synthetic audio recognition and Tavi reply
  were verified after automatic-VAD input stalled. See [verification](ptt-activity-boundaries.md).

- Build 21 uses Google’s commercial Tavi voice on Gemini 3.8 Live with blocking Live tools.
  Google setup and short audio generation were verified; physical microphone/PTT listening remains manual.
  See [verification and testing](tavi-live-voice.md).

- Build 20 makes the companion the default launch surface without a Dock/Command-Tab entry.
  The workspace opens on demand. See [verification](companion-first-launch.md).

- Build 19 removes the sidebar background icon while retaining menu actions and close-to-background.
  See [verification](sidebar-background-button-removal.md).

- Build 18 refreshes Personality and Answer length in Personalization with explanatory choice cards.
  See [previews and verification](personality-settings-refresh.md).

- Build 17 bounds voice reply inactivity and recognition failure, preserving approvals and real tool
  execution without replaying commands. See [voice recovery verification](voice-reply-recovery.md).

- Build 16 adds detailed workspace approval review with scrollable action details and pinned decisions,
  preserving the compact companion card. See [verification](app-approval-details.md).

- Build 15 refines companion reason, decision buttons, speech captions and status typography with
  readable surfaces. See [companion text verification](companion-text-refresh.md).

- Build 14 refreshes the three Live voice preferences with explanatory option cards and keyboard/
  accessibility support. See [voice settings verification](voice-settings-refresh.md).

- Build 13 fixes task draft creation while voice/chat or another task is active, retaining submission
  and approval guards. See [drafting verification](new-task-drafting.md).

- Build 12 adds explicit background workspace controls and companion approval handoff while resident
  work continues. See [background verification](background-companion.md). Full login/notch/recurring agent
  execution remain separate planned work.

- Build 11 adds shortcut interruption and release-to-submit for a replacement question;
  see [PTT interruption verification](ptt-interrupt-reply.md). Physical cross-app audio checks remain pending.

- Build 10 adds a gentle blushing/clasped-hands idle moment; see [blush verification](companion-blush-animation.md).
- Build 9 removes companion dancing; phone/laptop idle moments remain. See [removal verification](companion-dance-removal.md).
- Build 8 fixes request/card ordering, including late voice transcription and stable status updates;
  see [chat ordering verification](chat-feed-ordering.md).
- Chat tool cards, diff-to-composer drafts, Command Bar front-window attachment and screen-edge annotation arrows.
- One-time pre-load rollback backup, v1.1.0 build 1 metadata, changelog and packaging that keeps old DMGs.
- Push-to-talk capture release during replies/approval, with output-only reply playback.
- Build 2 adds screen-pointing instructions, image IDs/dimensions, multiple-capture mapping, permission
  recovery actions and an animated arrow with Reduce Motion support. Core/UI fixtures pass; real
  screen capture and Gemini pointing still need the manual checks below.
- The 2026-10-05 local rebuild includes the UI refresh, compact companion confirmations, Pointer removal,
  dispatcher-based global shortcut routing and immediate PTT settings updates. 1,315 tests pass;
  real keyboard/microphone/TCC verification remains pending.

- Build 3 adds a configurable voice shortcut, visible registration feedback and exclusive PTT ownership.
  A two-process native registration probe verifies conflict detection/recovery; test a held physical
  shortcut over another app and verify microphone release separately. See [shortcut recovery](ptt-shortcut-recovery.md).

- Build 4 guards against immediate PTT cancellation from unobserved keyboard-state readings and
  preserves next-press recovery after release/Stop. See [startup recovery](ptt-startup-recovery.md) for
  native notification tests and the still-pending physical cross-app acceptance check.

- Build 7 introduced brief random idle animations; build 9 retains phone/laptop and removes dancing.
  See [companion idle verification](companion-idle-animation.md).
- Build 6 fixes VS Code/vscode app aliases and keeps Insiders separate; see [app lookup verification](app-name-resolution.md).
- Build 5 adds in-panel task conversations, follow-up plan context, separate drafts and live execution
  flows in active/saved tasks. See [the task-panel report](task-panel-flow.md). The Phase 20 floating
  task panel and unattended/recurring execution remain pending.

## Before broader distribution

- Build 24 is installed and verified, but the latest relaunch waits in an existing Keychain read
  before companion creation. macOS SecurityAgent is running; handle the access prompt locally,
  then verify visible launch and real dragging. Automated placement tests pass. No credential or
  Keychain permission was modified by this task.

- [Phase 21 — Reliability and model readiness](../docs/roadmap/phase-21-model-readiness.md) is the
  current phased delivery plan. Companion upper drag-limit repair starts 21.1; voice hardware acceptance,
  provider support/evaluations and the floating task panel are the first milestone. Existing Phase 19/20
  scope and cancelled Pointer work remain unchanged.

- Test the rebuilt DMG's UI refresh, compact companion Cancel / Do it card and PTT release on hardware.
  The companion card implements tool approval access; the full Phase 20 floating task panel remains pending.
- Reproduce and resolve the reported launch failure on the second Apple silicon Mac; obtain its macOS version
  and failure details. The arm64 build targets macOS 14+, but those systems have not all been exercised.
- Test a real v1.0 → v1.1 upgrade and rollback in a separate user account, including Keychain access.
- Run every phase's manual checklist: real mic/speakers/AirPods, key release while replying/approving,
  screen-capture permissions/excluded apps, multiple displays, task approvals and notification navigation.
- Complete the Phase 8/18 Instruments and performance audit (idle CPU, hour-long memory, launch/scroll,
  voice latency and repeated-session/capture leak checks).
- Reconcile all module-roadmap acceptance criteria against implemented behavior. In particular, the
  interactive region selector still uses a protected temporary capture file that is deleted after reading;
  a fully in-process selector remains future work.
- Optional public-release path: Developer ID signing, notarization/stapling and clean-download Gatekeeper
  checks. Deferred for the user's free GitHub/friend-testing distribution.
- Publish a GitHub release only when requested; local artifacts/tags do not publish it automatically.

## Planned computer-control feature

- [Phase 19 — Computer Control](../docs/roadmap/phase-19-computer-control.md) has source components and
  offline tests, but is not wired into production: `IvyAppEnvironment` creates `TaskEngine` without a
  `ComputerControlCoordinator`; adaptive execution fails when it is absent. Source/fixture checks
  are not proof of working Mac control in the packaged app.
- Next: integrate the coordinator, scoped authorization, input tools and Stop/takeover controls into
  the actual app, then verify reviewed Calculator/TextEdit tasks and all affected entry points.
  Re-audit slice acceptance and perform real permission/input testing before marking it shipped.
- Current Screen Help annotations only point; they cannot click, type, scroll or drag. Removing the
  Pointer decoration/selection feature does not cancel the separately planned computer-control work.

## Planned assistant-workspace features

Expanded 2026-10-04 to cover both requested feature lists. Fourteen active workstreams remain open and 20.12 is cancelled; existing
voice, memory, screen annotations and companion confirmations provide foundations only. See
[Phase 20 — Assistant Workspace](../docs/roadmap/phase-20-assistant-workspace.md) for the full coverage
matrix, dependencies, acceptance criteria and combined Phase 19/20 milestones.
The floating Pointer feature and 20.12 hover/circle selection were removed on 2026-10-05 at the
user's request. Push-to-talk is voice-only; its global shortcut routing and immediate settings updates
are covered by regression tests. See [the removal report](pointer-removal.md) for hardware checks.
Other workspace additions remain pending and follow Ivy's identity/design requirement.

- [ ] 20.1 Floating task panel — shared with the computer-control panel.
- [ ] 20.2 Generated-file gallery and adjacent preview — real file outputs, Open/Reveal/drag-out.
- [ ] 20.3 Recurring tasks — read-only work/results first; risky actions wait for review.
- [ ] 20.4 Screen-aware dictation — focused-app context, separate transcription/insertion mode and verified destination.
- [ ] 20.5 Specialist assistants — coding/research/studying/writing contexts, goals and separately scoped approved memory.
- [ ] 20.6 Compact Home/notch/menu-bar overview — assistants, suggestions, tasks and files; no-notch fallback.
- [ ] 20.7 Step-by-step walkthroughs — Guide me mode; no automatic clicking.
- [ ] 20.8 App connectors and multiple accounts — explicit scopes, account isolation and real auth status.
- [ ] 20.9 Personal agent creation — resumable goals interview and reviewed creation of several assistants.
- [ ] 20.10 Daily suggestions — authorized goals/memory/integrations, Start/Edit/Later/Dismiss and deduplication.
- [ ] 20.11 Concurrent work — bounded research/draft workers, linked finished-agent follow-ups and one desktop-input lane.
- 20.12 Removed from scope — hover/circle selection and its voice integration cancelled by the user.
- [ ] 20.13 Screen drawing — validated polygons, arrows and curved paths with accessible explanations.
- [ ] 20.14 Companion-anchored guidance — fresh companion/region mapping with a screen-edge fallback.
- [ ] 20.15 Native Mac integration/polish — draggable panels, shortcuts, animation, accessibility and compact approvals.

Build order: control foundation + shared panel → generated files + routines → adaptive control + dictation
→ specialists + goal interview → spatial guidance/drawing + advanced control → connectors
→ concurrent work + personalized suggestions → compact Home + final polish.
Follow-up conversations are part of 20.1/20.5/20.11. Voice/text can accept a task proposal; risky tool
actions still need their own explicit confirmation. Planning itself never enables runtime permissions.
