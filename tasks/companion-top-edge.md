# Companion upper drag limit — 2026-10-08

Requested after Ivy stopped well below the menu bar when dragged upward. This is the first
implemented reliability fix in [the model-readiness plan](../docs/roadmap/phase-21-model-readiness.md),
delivered in v1.1.0 build 24. The remaining model, evaluation and workspace slices stay planned.

## Diagnosis and change

The companion has a fixed transparent panel, with a smaller visible character/status stack
aligned toward the bottom. The controller already clamps and restores positions using the
measured visible stack. AppKit's separate whole-window top constraint nevertheless reserved
the transparent upper margin, pushing Ivy down.

A native regression reproduced this before the fix: the desired panel origin was y=790,
but AppKit's constraint returned y=699 on the test display (91 points lower). The regression
failed with the existing implementation and passes after the fix.

`CompanionPanel.constrainFrameRect(_:to:)` now preserves the requested panel frame. The
existing controller still clamps the character, captions and approval controls to the usable
screen area when dropped, restored or resized. Only invisible panel space can extend above
the display. The visible companion stays below the menu bar/camera area. Drag thresholds,
saved placement, keyboard activation, approvals and companion artwork/layout are unchanged.

Apple documents the independent window constraint in
[NSWindow.constrainFrameRect(_:to:)](https://developer.apple.com/documentation/appkit/nswindow/constrainframerect(_:to:)).

## Verification

- New native tests exercise the real `CompanionPanel` frame constraint and frame setters,
  top-edge placement, nil-screen handling, every edge and caption/approval expansion.
- Full suite: 1,333 core tests in 2.877 seconds and 45 native UI tests in 36.420 seconds;
  1,378 tests pass in 39.297 seconds combined execution.
- Changed executable-line coverage across the current working tree: 119/119 (100%);
  the placement fix itself is 5/5 covered.
- Strict Swift 6 debug build: 7.40 seconds, zero compiler diagnostics. Warm build: 0.18 seconds.
- Changed-file credential scan and `git diff --check` pass.

## Build and artifact verification

- Release compile: 29.36 seconds, zero compiler diagnostics; packaged credential scan clean.
- App and read-only DMG signatures verify with ad-hoc Hardened Runtime signing; arm64,
  build 24 and `LSUIElement=true` metadata are correct. The DMG contains its Applications link.
- DMG integrity/checksum and mounted/packaged/installed executable comparisons pass.
- Ivy was idle and quit normally before installing `/Applications/Ivy.app` build 24.
  Relaunch starts the installed process; native UI inspection timed out. A one-second process
  sample shows startup waiting in `SecItemCopyMatching` while reading existing Keychain credentials,
  before companion creation. This does not establish a successful visible relaunch; a local
  Keychain prompt check was requested. macOS SecurityAgent is running; the computer-use tool blocks
  access to that system app, so its access dialog requires local user handling. No Keychain
  permission or credential was changed.
- Executable SHA-256: `85f7648ac48a6c51cc578b602289de3308793345b19b59d0d5e4274e89488432`.
- DMG SHA-256: `add82f7757510ecccfa899d6a33c24ac14090b2b9193ae2d2367794962aac0fb`.
- Previous package: `dist/Previous-Builds/Before-Top-Edge-Build24-2026-10-08-Kl1hkO/`.
- Previous installed app: `dist/Previous-Builds/Before-Applications-Install-Build24-2026-10-08-ooN42Q/Ivy.app`.

## Try it

Drag Ivy upward by the character or status pill. The visible stack should reach the usable
screen's top edge, instead of leaving the large empty gap. Release, then ask a question that
shows a caption or approval; expanded content should remain onscreen. Try another display,
relaunch and confirm the saved placement still works.

Real pointer dragging on the user's displays remains a manual acceptance check; the native
regressions verify the AppKit constraint and frame behavior without moving the user's pointer.
