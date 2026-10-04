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

## Before broader distribution

- Rebuild the DMG to include the unpackaged UI refresh and companion Do it / Cancel review card.
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

All pending; see [Phase 20 — Assistant Workspace](../docs/roadmap/phase-20-assistant-workspace.md) for
dependencies, acceptance criteria and the combined Phase 19/20 milestones.

- [ ] 20.1 Floating task panel — shared with the computer-control panel.
- [ ] 20.2 Generated-file gallery and adjacent preview — real file outputs, Open/Reveal/drag-out.
- [ ] 20.3 Recurring tasks — read-only work/results first; risky actions wait for review.
- [ ] 20.4 Dictation anywhere — separate voice mode, using the verified input driver.
- [ ] 20.5 Specialist assistants — coding/studying/writing contexts and approved memory.
- [ ] 20.6 Compact notch/menu-bar overview — tasks, conversations and files; no-notch fallback.
- [ ] 20.7 Step-by-step walkthroughs — Guide me mode; no automatic clicking.
- [ ] 20.8 App connectors and multiple accounts — explicit scopes, account isolation and real auth status.
