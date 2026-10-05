# Push-to-talk shortcut recovery — 2026-10-05

Historical build-3 verification. The current package is build 4; see
[startup recovery](ptt-startup-recovery.md). Its previous artifacts are preserved under
`dist/Previous-Builds/Before-PTT-Build4-2026-10-05-fbddnM/`.

## Report and verified cause class

The user reported that ⌘⇧Space showed nothing over another app in the latest build. No running Ivy
process was available during inspection, so the exact cause on the user's running copy is unconfirmed.
The prior routing test delivered Carbon notifications inside one process; it did not establish physical
keyboard operation in another app.

Apple's installed CarbonEvents.h documents that an exclusive registrant suppresses non-exclusive
registrants while their registration can still succeed. Ivy used non-exclusive PTT registration and
kept registration errors on an environment property that Settings did not display.

An isolated two-process native probe reproduced that class of silent failure: one process owned an
unused four-modifier F18 shortcut exclusively, and the old driver reported successful registration.
The revised driver detected the conflict, stayed unregistered, then registered successfully after the
other process released it. The probe sent no keyboard events, recorded no audio, changed no focus,
and requested no TCC permissions. It is a registration test, not a physical PTT/audio test.

## Build 3 behavior

- General settings provides a Voice shortcut picker: ⌘⇧Space (default) or ⌃⌥⌘Space.
- Only the selected key is registered; changes apply immediately and persist. Older, unknown or
  wrongly typed settings recover to the default without discarding other preferences.
- Production PTT requests exclusive registration. A conflicting registration produces visible General
  feedback; quit the app holding that shortcut, select the alternative, or toggle PTT off/on to retry.
- A ready label confirms registration only; it does not prove microphone, network or provider health.
- Changing the key ends the old held recording, with a press-identity guard protecting a later press.
- PTT remains voice-only. No removed Pointer UI, selection adapter or image-before-voice hook returns.
  No extra keyboard-monitoring permission or automatic shortcut fallback was added.

## Verification and package

- 1,289 core tests in 181 suites (2.994 s) and 30 native UI tests in 5 suites (31.735 s): 1,319 pass.
- Changed executable lines: 63/65 covered (96.92%), combining core, UI and executable coverage.
- Strict Swift 6 debug/release builds passed without compiler warnings/errors. Warm build: 1.73 s.
  Release compile: 31.19 s.
- Native light/dark Settings previews cover conflict, ready and disabled states with opaque surfaces.
- Package credential scan, deep/strict signatures, DMG integrity and SHA-256 sidecar passed.
- Read-only DMG mount: app signature valid, executable exactly matches the staged app, metadata is
  1.1.0/build 3, Applications points to `/Applications`; verification volume ejected.
- Current artifacts: `dist/Ivy.app`, `dist/Ivy-1.1.0.dmg`, arm64, ad-hoc Hardened Runtime.
- DMG SHA-256: `bc07644a9a7ce460988cd24be4f3b8aa94f89fa89e4c2d8498cf5343dacc3448`.
- Executable SHA-256: `9a789ff09ed9181d76c49143b109e1a6dba26023bf6160c795bcca4cb2b12c4c`.
- Previous package preserved under `dist/Previous-Builds/Before-PTT-Build3-2026-10-05-KgDtsp/`.

## Manual acceptance still needed

Install the updated DMG, quit older copies, then confirm About shows build 3. Enable General → Push to
talk and Show the Ivy companion. Check General for a registration error; resolve it or choose the
alternative. Focus TextEdit or Safari, hold the selected shortcut, speak and release. Verify Listening
appears, the microphone closes on release and Ivy answers. Test Stop, a silent press and key switching.
If registration is ready but nothing appears, compare whether the same shortcut works with Ivy focused
and whether ⌃⌥⌘K opens the Command Bar over another app; collect shortcut/state diagnostics.
This physical keyboard/audio acceptance was not performed during automated verification.

No installed app, macOS grants, GitHub release, notarization or user data was modified.
