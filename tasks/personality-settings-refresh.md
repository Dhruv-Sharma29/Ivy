# Personality settings refresh — 2026-10-08

Delivered in v1.1.0 build 18. Personality and profile Answer length now use the same explanatory
choice cards as Live voice preferences. Cards have a short description, selected checkmark and
restrained outline, hover/press feedback, native keyboard focus and bounded arrow selection.
They sit in equal-width columns when space permits and stack in narrow windows.

Personality retains Polite, Light, Ivy and Roast with their original stored values. Answer length
retains Brief, Balanced and Detailed. Both use their existing model setters and persistence;
rendering the controls does not write preferences. The companion, approval card and voice
coordinator source files are byte-identical to their pre-task copies.

## Verification

- Full suite: **1,362 tests pass**, comprising 1,321 core tests in 3.133 seconds and 41 native UI
  tests in 36.104 seconds (39.237 seconds combined). No tests were removed or skipped.
- New native test exercises the actual panel's selection bindings, reloads saved values, checks
  personality bounds and arrow navigation, preserves unrelated fields and ensures rendering
  does not mutate the profile. Full-panel fixtures cover light/dark at 340 and 720 points and
  increased contrast at the narrow width, using an offline in-memory store.
- Changed executable source lines across the local working tree: **502/508 covered (98.82%)**.
  PersonalizationPanel has **14/14 changed executable lines covered**. This is changed-line
  coverage, not total project coverage.
- Strict Swift 6 debug/release builds pass with zero compiler diagnostics. Warm incremental
  build: 0.21 seconds; release build: 31.90 seconds. Source/package credential scans and
  `git diff --check` pass.
- Native wide light/dark and narrow dark previews were visually inspected. Descriptions and
  selection outlines remain readable; narrow choices stack. Preview directory:
  `/private/tmp/ivy-personality-review`.
- Packaged, read-only mounted and installed apps all contain **1.1.0 (18)**, arm64, with
  verified ad-hoc Hardened Runtime signatures. DMG integrity, SHA-256 sidecar, Applications
  shortcut and mounted/installed executable equality pass.
- Executable SHA-256: `e37e03052811bf616a4373fcc3b56993a940668cf8e4708c4718f870c72929c5`.
- DMG SHA-256: `515b809b1b28a1163f92a3c0671b854fc30de367ef9838146eb429be65b183c6`.
- Previous packaged build retained at
  `dist/Previous-Builds/Before-Personality-UI-Build18-2026-10-08-ibDyM3`.
- Previous installed app retained at
  `dist/Previous-Builds/Before-Applications-Install-Build18-2026-10-08-wSuTDv`.

The current session was left running. Installed UI inspection encountered concurrent user
interaction, so relaunch and physical keyboard/click checks remain manual. Native previews
verify layout and production bindings; they do not establish full VoiceOver behavior.
The friend-testing package remains unnotarized. The system's `hdiutil` deprecation notices
did not prevent successful verification.

## Try it

Finish active work, choose Quit Ivy, then open Ivy from Applications. Confirm **Settings → About**
shows **v1.1.0 (18)**, then open **Settings → Personalization**. Choose a personality and answer
length, leave the pane and return to confirm the selection. Keyboard users can focus a card and
use left/right arrows or Space. Existing preferences should remain selected after relaunch.
