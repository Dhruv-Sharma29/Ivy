# Remaining work

Updated 2026-10-04 for the v1.1.0 build-2 friend-testing build. Original phase checklists are acceptance criteria,
not proof that every proposed feature has shipped. See [CHANGELOG](../CHANGELOG.md) for implemented scope.

## Implemented in this release

- Chat tool cards, diff-to-composer drafts, Command Bar front-window attachment and screen-edge pointer.
- One-time pre-load rollback backup, v1.1.0 build 1 metadata, changelog and packaging that keeps old DMGs.
- Push-to-talk capture release during replies/approval, with output-only reply playback.
- Build 2 adds screen-pointing instructions, image IDs/dimensions, multiple-capture mapping, permission
  recovery actions and an animated arrow with Reduce Motion support. Core/UI fixtures pass; real
  screen capture and Gemini pointing still need the manual checks below.
- The 2026-10-04 local rebuild includes the UI refresh, compact companion confirmations and a
  physical-shortcut release check for PTT. 1,212 offline tests pass; real keyboard/TCC verification is pending.

## Before broader distribution

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

- [Phase 19 — Computer Control](../docs/roadmap/phase-19-computer-control.md) is the 2026-10-04 build plan
  for scoped Mac clicking, typing, scrolling, dragging, browser workflows and adaptive task execution.
  All ten slices are pending. Begin with session/permissions, read-only interface inspection, native
  input primitives and Stop/takeover controls, tested in Calculator and an unsaved TextEdit document.
- The current screen annotation points only; creating this plan does not enable cursor control or
  change the existing DMG. Phase 20 now plans the complementary features and their shared build order.

## Planned assistant-workspace features

Expanded 2026-10-04 to cover both requested feature lists. All fifteen complete workstreams remain open; existing
voice, memory, pointers and companion confirmations provide foundations only. See
[Phase 20 — Assistant Workspace](../docs/roadmap/phase-20-assistant-workspace.md) for the full coverage
matrix, dependencies, acceptance criteria and combined Phase 19/20 milestones.
The optional folded-leaf floating pointer and its settings are implemented and included in the latest
local app/DMG rebuild. Anchored target arrows, real input control and the other workspace additions remain
pending. Every UI slice follows the roadmap's explicit Ivy identity/design requirement.

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
- [ ] 20.12 Spatial context — hold shortcut, circle/select a region and submit a question about the exact crop.
- [ ] 20.13 Screen drawing — validated polygons, arrows and curved paths with accessible explanations.
- [ ] 20.14 Anchored companion arrows — fresh cursor/companion/region mapping with display-aware fallback;
  optional cursor-follow visual/color/Hide settings are implemented and packaged locally.
- [ ] 20.15 Native Mac integration/polish — draggable panels, shortcuts, animation, accessibility and compact approvals.

Build order: control foundation + shared panel → generated files + routines → adaptive control + dictation
→ specialists + goal interview → spatial guidance/drawing + advanced control → connectors
→ concurrent work + personalized suggestions → compact Home + final polish.
Follow-up conversations are part of 20.1/20.5/20.11. Voice/text can accept a task proposal; risky tool
actions still need their own explicit confirmation. Planning itself never enables runtime permissions.
