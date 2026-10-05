# Ivy UI refresh and feature audit

Historical report from 2026-10-04. Superseded for Pointer features on 2026-10-05:
[the whole Pointer feature was removed](pointer-removal.md), including hover/circle voice selection.
The dated package/verification entries below are historical, not current installation instructions.

All future slices follow [Ivy's own interface requirement](../docs/roadmap/phase-20-assistant-workspace.md#ivys-own-interface--design-requirement):
references establish behavior; Ivy retains original leaf branding, task-first layouts, native settings,
companion controls and its own copy/assets. Each milestone is reviewed beside existing Ivy surfaces.

The supplied-media review informed the original workspace/notch/settings ideas. Its floating-pointer
requirements are superseded by the user's removal request.
The floating-pointer visual/settings slice was packaged on 2026-10-04 and removed on 2026-10-05.
Its entries below document that historical build only; the other additions remain planned.

## Implemented UI refresh

- Home: compact branded header, roomier assistant shortcuts and shared rounded cards.
- Library: larger type-icon wells and cleaner card spacing for saved conversations and task reports.
- Tasks: improved starter cards, icon spacing and report presentation.
- Settings: shared card styling and icon wells.
- Navigation: roomier targets and consistent sidebar spacing.
- Floating Command Bar: explicit Send/Open/Close controls, draft suggestions and reply-dependent sizing.
- Companion: pending tool approvals replace the status pill below the character with the reason and Cancel / Do it; hover reveals the original request,
  sharing the main-window request and retaining independent drag behavior on the character/status pill.

Quick suggestions fill a draft; capture and sending remain separate. Existing task, voice, archive and
approval behavior is preserved. Ivy retains its own artwork and identity. No third-party source or assets
were copied into this refresh.

These changes are included in the 2026-10-04 local v1.1.0 build-2 app/DMG rebuild, together with PTT
missed-release recovery. Previous artifacts are retained under `dist/Previous-Builds/`; hardware/native
glass checks remain pending. Phase 19/20 capabilities below remain planned.

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
  still require an in-app check. This update was included in the later 2026-10-04 local DMG rebuild.

## Compact confirmation verification — 2026-10-04

- Companion approval reduced from 344×300 to a 240×96-point bubble below the character, replacing
  the status pill; the native sheet is 280×100 points. Both show only the action reason and Cancel / Do it,
  with the original request available on hover. Obsolete Details snapshots were replaced with long/empty
  payload snapshots because the user explicitly removed that control; safety assertions remain intact.
- Long/empty previews and ordinary/long titles render in light and dark appearances; approval bounds
  remain inside the panel or parent window. Existing identity, cancellation and drag routing checks pass.
- 1,188 core tests plus 24 native interface tests passed (about 33 seconds combined).
  The drag assertion now explicitly checks the 96-point character alone during approval; the original
  character-and-pill assertion remains for ordinary states. The first run exposed that obsolete assumption.
- Changed executable-line coverage for the working tree: 106/122 (86.89%); confirmation/companion
  changes are 34/36 covered. Strict Swift 6 build passed without warnings/errors.
- Solid-surface companion previews were reviewed; this update is included in the 2026-10-04 local DMG rebuild.

## Retired floating pointer — historical 2026-10-04 build

Removed from source and the current app/DMG on 2026-10-05. The following is an archived verification record,
not a current feature list or installation guide.

- A 32-point folded-leaf vector follows beside the ordinary cursor with bounded smoothing, display
  transitions and edge offsets. It is a separate click-through, non-activating window and produces no input.
- Settings → Pointer offers Follow my cursor and Blue/Green/Amber/Red, with native segmented selection,
  a preview and searchable labels. Preferences persist; missing/corrupt old fields recover individually
  to the default off/blue state. The companion master switch also gates following.
- Hide/disable, Reduce Motion, sleep/inactive sessions, missing display geometry and shutdown stop the
  sampling loop. Wake/display/accessibility changes can restore an enabled visual. No screen capture,
  microphone, accessibility authorization, system-cursor movement or tool approval is performed.
- 1,192 core and 28 native tests passed, about 34 seconds combined. Changed executable-line coverage
  across the working tree is 306/332 (92.17%). New geometry is 37/37; the native controller is 134/141.
  Strict Swift 6 build passed without warnings/errors; warmed incremental build completed in 0.36 seconds.
- Original leaf/color previews were reviewed in both appearances. Solid-surface Settings card previews
  verify content/layout; offscreen native sidebar/header colors and glass rendering remain unreliable.
  Live appearance and real input delivery across displays/Spaces still
  required manual checking for that historical build. The current app/DMG excludes this slice.
- Phase 20's Ivy design requirement governs subsequent work: task-first Home, original leaf/status notch
  overview, context selection with clear memory scope, native grouped settings and original copy/assets.

### Pointer package verification

- Rebuilt `dist/Ivy.app` and `dist/Ivy-1.1.0.dmg`: version 1.1.0, build 2, arm64, ad-hoc Hardened Runtime.
- Release strict-concurrency compile completed without warnings/errors. The app signature verifies
  with deep/strict checks; DMG integrity and its regenerated SHA-256 sidecar both verify.
- Mounted the image read-only, verified its app signature, compared its executable byte-for-byte with
  `dist/Ivy.app`, checked the Applications link and ejected the verification volume.
- Previous app/DMG/checksum preserved in `dist/Previous-Builds/Floating-Pointer-2026-10-04-lA9sSo/`.
- DMG SHA-256: `906602aa7870e2176e25e4200ca335ffcf7777be59a3b7086307072efdeafa68`.
- No installed `/Applications/Ivy.app` was present to replace. No user data, version/tag, GitHub release
  or notarization was changed by that packaging run. This pointer package has been superseded.

## Selected feature additions

| Capability | Ivy foundation and planned addition |
| --- | --- |
| Floating task panel | Tool cards and task progress exist. Add a shared panel with status, Stop, approval access and task-specific follow-up. |
| Generated-file gallery and adjacent preview | Library currently catalogs conversations and task reports. Add actual output-file records, previews, Open, Reveal in Finder and drag-out. |
| Recurring tasks | Reminders and briefings exist; reminder triggers never run tools. Add a separate routine executor with reviewable scope, controls and failure recovery. |
| Screen-aware dictation anywhere | Conversational push-to-talk exists. Add scoped focused-app context and a separate mode to insert a transcript into the verified editor. |
| Specialist assistants and memory | Reuse conversation/profile/memory foundations for coding/research/studying/writing roles, goals and explicit context isolation. |
| Personal agent creation | Interview the user, draft distinct assistant profiles and create only reviewed proposals. |
| Daily suggestions | Propose bounded, deduplicated tasks from reviewed goals, authorized integrations and memory; acceptance does not approve risky tools. |
| Concurrent work and follow-ups | Run independent research/draft workers with separate context/results and linked continuations; serialize desktop input. |
| Compact Home/notch/menu-bar overview | Add a peek of real assistants, suggestions, tasks and files, with a no-notch fallback. |
| Step-by-step walkthroughs | Capture mapping, arrows and labels exist. Add remembered steps and progression from explicitly authorized fresh screen context. |
| Screen drawing | Add validated polygons/arrows/curves on explicitly shared captures. Hover/circle selection is cancelled. |
| Anchored companion arrows | Connect fresh companion bounds to the verified highlighted region with a screen-edge fallback; no cursor-follow decoration. |
| App connectors and multiple accounts | Add connector/authentication infrastructure, explicit account scope and isolated credentials. Documentation alone does not implement an integration. |
| Native Mac polish | Apply existing Ivy styling, compact confirmations, shortcuts, drag areas and accessibility to every new surface. |

Recommended workspace order: floating task panel → output-file gallery/preview → routine controls.
Computer control supplies shared input and observation foundations for dictation and walkthroughs.

Fourteen active workstreams are planned; 20.12 is cancelled in [Phase 20 — Assistant Workspace](../docs/roadmap/phase-20-assistant-workspace.md),
linked to [Phase 19 — Computer Control](../docs/roadmap/phase-19-computer-control.md) with a combined
milestone order. The pointer slice and [screen-question slice](screen-questions.md) are retired;
remaining workstreams stay open. Planning does not enable accounts, capture, background
execution or permissions.

Source checks for the important gaps: `ProactiveModels.swift` and `ProactiveEngine.tick` distinguish
notifications from tool execution; `WorkspaceLibraryModel.swift` defines conversation/report library
items; `TasksWorkspaceView.swift` presents task plans, progress and reports.
