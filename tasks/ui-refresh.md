# Ivy UI refresh and feature audit

Updated 2026-10-04. This report distinguishes implemented source changes from planned capabilities.

## Implemented UI refresh

- Home: compact branded header, roomier assistant shortcuts and shared rounded cards.
- Library: larger type-icon wells and cleaner card spacing for saved conversations and task reports.
- Tasks: improved starter cards, icon spacing and report presentation.
- Settings: shared card styling and icon wells.
- Navigation: roomier targets and consistent sidebar spacing.
- Floating Command Bar: explicit Send/Open/Close controls, draft suggestions and reply-dependent sizing.
- Companion: pending tool approvals show a scrollable review card above the character with Do it / Cancel,
  sharing the main-window request and retaining independent drag behavior on the character/status pill.

Quick suggestions fill a draft; capture and sending remain separate. Existing task, voice, archive and
approval behavior is preserved. Ivy retains its own artwork and identity. No third-party source or assets
were copied into this refresh.

These source changes are not yet included in the existing v1.1.0 build-2 DMG.

## Verification recorded for the refresh

- Strict Swift 6 build passed without warnings or errors.
- 1,182 core tests and 20 native interface tests passed; combined execution was about 32 seconds.
- Changed executable-line coverage for the full working tree: 271/306 (88.6%).
- Light/dark, compact Home, Library/Tasks and solid-surface Command Bar previews were reviewed.
- The Command Bar reports its content height and resizes around a stable top edge; a native reply fixture
  and panel geometry checks cover growth and height limits.
- Offscreen native glass captures do not reliably render material/vibrancy. Solid-surface previews
  verified spacing and text; actual glass appearance still needs an in-app visual check.

These are results from the UI refresh verification, not a fresh hardware/provider/DMG test.

## Companion approval follow-up verification

- Added chat/Live request routing and native panel lifecycle fixtures: review does not approve;
  replacement and repeated responses cannot authorize another request; hiding leaves approval pending.
- Light/dark previews cover ordinary and long requests, content bounds and pointer routing around the drag surface.
- 1,182 core tests and 24 native interface tests passed on the full rerun (about 34 seconds combined).
  The first run hit timing failures in two existing voice tests; both passed on rerun.
- Changed executable-line coverage for the full working tree: 399/442 (90.27%).
- Swift 6 complete strict-concurrency build passed without warnings/errors; the warm incremental build
  completed in under one second.
- Previews use solid surfaces to verify layout; live glass appearance and real provider/hardware flows
  still require an in-app check. This update is not in the existing DMG.

## Selected feature additions

| Capability | Ivy foundation and planned addition |
| --- | --- |
| Floating task panel | Tool cards and task progress exist. Add a shared panel with status, Stop, approval access and task-specific follow-up. |
| Generated-file gallery and adjacent preview | Library currently catalogs conversations and task reports. Add actual output-file records, previews, Open, Reveal in Finder and drag-out. |
| Recurring tasks | Reminders and briefings exist; reminder triggers never run tools. Add a separate routine executor with reviewable scope, controls and failure recovery. |
| Dictation anywhere | Conversational push-to-talk exists. Add a separate mode to insert a transcript into the verified focused editor. |
| Specialist assistants | Reuse conversation/profile/memory foundations for separate roles and explicit context isolation. |
| Compact notch/menu-bar overview | The main window, floating Command Bar and companion exist. Add an optional overview of real tasks, conversations and files, with a no-notch fallback. |
| Step-by-step walkthroughs | Capture mapping, arrows and labels exist. Add remembered steps and progression from explicitly authorized fresh screen context. |
| App connectors and multiple accounts | Add connector/authentication infrastructure, explicit account scope and isolated credentials. Documentation alone does not implement an integration. |

Recommended workspace order: floating task panel → output-file gallery/preview → routine controls.
Computer control supplies shared input and observation foundations for dictation and walkthroughs.

All eight additions are planned in [Phase 20 — Assistant Workspace](../docs/roadmap/phase-20-assistant-workspace.md),
linked to [Phase 19 — Computer Control](../docs/roadmap/phase-19-computer-control.md) with a combined
milestone order. All remain unimplemented. Planning does not enable accounts, capture, background
execution or permissions.

Source checks for the important gaps: `ProactiveModels.swift` and `ProactiveEngine.tick` distinguish
notifications from tool execution; `WorkspaceLibraryModel.swift` defines conversation/report library
items; `TasksWorkspaceView.swift` presents task plans, progress and reports.
