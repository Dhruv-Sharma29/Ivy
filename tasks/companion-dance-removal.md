# Companion dance removal — 2026-10-07

Current artifacts are build 24, retaining dance removal and [adding blushing/clasped hands](companion-blush-animation.md).
The verification below describes the original build 9 delivery.

## Delivered in 1.1.0, build 9

At the user's request, companion dancing has been removed. `CompanionIdleActivity` contains
only phone and laptop, with equal selection probability. Dance timing, bobbing and rotation code
are removed. Quiet lead-ins and the 48-second schedule remain, with phone moments lasting 9 seconds
and laptop moments 11 seconds. Ordinary idle breathing/blinking, real activity poses, dragging,
hidden-state handling and Reduce Motion retain their existing behavior.

The sprite cache extracts only the eight phone/laptop frames. Retired frame indices 24–27 return
nil, so the view cannot show them. The original source artwork is preserved; its third row is unused.
No image generation, artwork changes, tool execution or permission-policy changes were needed.

## Verification

- Existing idle tests were updated to the requested two-activity contract, rather than removed or
  skipped. They assert the complete activity list, selection of both remaining activities, frame
  bounds 16–23, zero extra bob/rotation, and unavailable retired frames. Duration, quiet intervals,
  invalid timestamps, reproducibility and real-state/Reduce Motion interruption checks remain.
- Full coverage run: 1,306 core tests in 183 suites (2.921 s) and 35 native UI tests in 5 suites
  (34.854 s), totaling 1,341 passing tests.
- Changed executable lines across the working tree: 63/64 covered (98.44%); the animation/cache
  changes specifically: 5/5 covered (100%). Coverage was exported before the non-instrumented build.
- Native fixtures load all eight transparent frames and render only phone/laptop galleries.
  Both light/dark previews inspected at `/private/tmp/ivy-idle-review/`.
- Tests use offline provider/audio/tool fixtures and do not use a real microphone or execute desktop tools.

## Build and package

- Swift 6 strict-concurrency debug build passes without compiler warnings/errors; recompile after
  coverage: 7.39 s, warm build: 0.18 s. Strict release build: 29.14 s.
- `dist/Ivy.app` and `dist/Ivy-1.1.0.dmg`: 1.1.0 build 9, Apple silicon (`arm64`).
- Ad-hoc signature with Hardened Runtime; notarization remains unconfigured. The package credential
  scan found zero leaks. Deep/strict signatures, DMG integrity and its SHA-256 sidecar pass.
- A read-only mount verified metadata, matching executable and the Applications link, then was ejected.
- DMG SHA-256: `2b0da960fd59b2d4cda85fbe6c4544b3ab6a5a46f91d1e7a335753792bf4a512`.
- Executable SHA-256: `1dc99f0cd02b2f6912d0d449c588b041610aafbe3dfc23f80d7caa68153fd3b7`.
- Build 8 package backup: `dist/Previous-Builds/Before-Dance-Removal-Build9-2026-10-07-lDGoo7/`.
- Installed `/Applications/Ivy.app` was replaced after a normal quit and reopened. Process inspection
  confirms it runs from that path; metadata, signature and executable match the verified build 9 package.
- Installed build 8 backup: `dist/Previous-Builds/Before-Applications-Install-Build9-2026-10-07-pMQL9x/`.
- Documentation/specs reflect the removal. Local doc links and `git diff --check` pass.

## Try it

Check About shows **1.1.0 (9)**. Enable **Show the Ivy companion** and **Keep visible when idle** in
Settings → General. Leave Ivy ready for 12–24 seconds. Idle activities can use a phone or laptop;
dancing is no longer selected. Voice, tasks, approvals and dragging still take priority immediately.
