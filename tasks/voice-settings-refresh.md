# Voice settings refresh — 2026-10-08

Current artifacts are build 24, retaining this design and [refining companion text](companion-text-refresh.md).
The release measurements below describe the original build 14 delivery.

## Delivered in 1.1.0 (14)

The Live conversation preferences replace the wide, heavy segmented bars with three separate rows
of rounded choice cards. Each row explains the preference; each option includes a short description.
The selected card uses Ivy's restrained indigo tint, a thin outline and a checkmark. Text retains
semantic system colours, and unselected options remain quiet. Pointer hover and immediate press
feedback make the entire card feel clickable without adding movement.

Equal-width cards sit side by side when space permits and stack vertically in narrow containers.
Native buttons retain keyboard focus/activation and VoiceOver labels. Left/right arrows move the
selection within the preference group, stopping at its ends. Selection is also announced through
the selected trait, and increased contrast strengthens outlines. There is no positional animation;
the design remains static with Reduce Motion and uses the existing settings surface's opaque
fallback under Reduce Transparency.

The choices bind to the same persisted pause tolerance, response length and pace fields. Defaults,
saved values, Live provider behavior and the group's restart guidance are retained. Other settings
controls retain their existing layout.

## Verification

Native fixtures verify saved answer-length changes and reopening the preferences, bounded arrow
navigation and an empty-option safety case. Previews exercise the three actual choice groups in
light/dark appearances at 300- and 600-point widths, with increased contrast at the narrow width.
The existing full Voice pane previews also render the updated controls. All services are offline.

- **1,351 tests passed**: 1,311 core tests in 2.859 seconds and 40 native UI tests in 37.535 seconds.
  No tests were skipped or removed. Changed executable source lines across current local changes:
  **279/280 covered (99.64%)**, including all 80 changed executable lines for this voice UI.
- Strict Swift 6 build passed with no compiler diagnostics; warm incremental build: 0.17 seconds.
  Release build: 28.08 seconds. Source/package credential scans and `git diff --check` passed.
- Light/dark wide and narrow previews were visually inspected. Wide cards align evenly; narrow
  cards stack without clipped labels or descriptions. The existing full Voice pane was rendered.
  Preview files are in `/private/tmp/ivy-voice-style-review`.
- Packaged, mounted and installed apps are **1.1.0 (14)**, Apple silicon, with verified ad-hoc
  Hardened Runtime signatures. This friend-testing release remains unnotarized.
- DMG integrity, SHA-256 sidecar, mounted/installed executable equality and Applications link passed.
  Executable SHA-256: `0abfaf1ce6591c3bce66b5d27300add1163a4cea34ee8156233542619e564470`.
  DMG SHA-256: `3923ba45137f83ec09d19934ba253b6806c5b4f3ab91284f617f6ff5e52df0cb`.
- Build-13 packaged and installed copies were retained in `dist/Previous-Builds`. The Mac was locked
  during final installed-app inspection; the running session was left uninterrupted. Relaunch is
  required to load build 14. Physical click, keyboard and microphone checks remain manual.

## Try it

Relaunch the updated app, confirm About shows **1.1.0 (18)** and open **Settings → Voice**. Choose
an option in Live conversation or focus its buttons and use left/right arrows. Restart Ivy when
applying speaking preferences, as the group notes.
