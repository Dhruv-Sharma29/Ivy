# Pointer removal and global push-to-talk — 2026-10-05

Historical build-2 verification. The removal remains in place; see [build-3 shortcut recovery](ptt-shortcut-recovery.md) for the latest package.

The user explicitly requested removal of the whole Pointer feature, including hover/circle selection
linked to voice. Its Settings page, floating cursor decoration, display polling, selector panels,
selection shortcuts/menu action, selected-region capture adapters, preview state and voice callbacks
are removed. Push-to-talk is voice-only. Existing explicit attachments, annotation tools and approvals
retain their separate behavior.

Old Pointer keys are ignored during settings decoding and omitted on the next save; other preferences
remain intact. No user data, Keychain entries or macOS permission grants were edited.

## Shortcut fix

Keyed Carbon shortcuts register and receive notifications at the dispatcher target, before
application-level handlers can consume them. Each manager still handles only its own hotkey identity.
A new native regression test reproduced the old failure with an application handler consuming events;
it passes with the dispatcher change, including release, multiple managers and unregister cleanup.
The test sends Carbon notifications only inside its own process; it never types into another app.

The push-to-talk setting now updates global registration immediately. Tests cover enabling, disabling
while held (the existing release watchdog closes capture), toggling again and retrying registration
after an error. Unrelated preferences do not replace its handler. Approval safeguards remain intact.

## Test retirement rationale

The four feature-only test files for floating pointer geometry/controller and spatial
question geometry/controller/voice were removed because the user cancelled their entire implementation.
This is feature removal, not deletion to bypass failing tests. Retained screen-attachment assertions
remain in release integration tests; native layouts now assert that Pointer is absent. New tests verify
legacy preference compatibility and global shortcut behavior. No retained test was skipped.

## Verification

- Full suite: 1,286 core tests in 181 suites (3.041 s) and 29 native UI tests in 5 suites (31.408 s).
  Total: 1,315 passing tests; combined execution 34.449 s.
- Changed executable source lines: 28/28 covered (100%), combining core and native UI coverage.
  Removal-only lines are excluded from the denominator.
- Swift 6 strict-concurrency debug and release builds: zero compiler warnings/errors. Warm build: 0.18 s.
- Release signing and credential scan passed. DMG SHA-256 and integrity verified; the read-only mounted
  executable matches `dist/Ivy.app`, its signature is valid, and Applications points to `/Applications`.
- Artifact: `dist/Ivy.app` and `dist/Ivy-1.1.0.dmg`, version 1.1.0 (build 2), arm64, ad-hoc Hardened Runtime.
- DMG SHA-256: `25057711dfe30e2afccc3338cc969076b3f24f61c530e38223a325571bfc2c31`.
- Previous package preserved in `dist/Previous-Builds/Pointer-Removed-2026-10-05-SifkLe/`.

Still needed: quit the old Ivy, install/open this package, enable General → Push to talk, focus another
app such as Safari or TextEdit, hold ⌘⇧Space, speak and release. Check that listening starts and the
microphone closes on release. Physical keyboard and microphone behavior across real apps has not been
verified by these isolated tests. No live audio or screen recording was performed during verification.
