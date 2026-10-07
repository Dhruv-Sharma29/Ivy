# Push-to-talk startup recovery — 2026-10-05

Build 4 is now preserved in `dist/Previous-Builds/Before-Task-Panel-Build5-2026-10-07-ziOkxd/`.
The current artifacts are build 7; see [idle companion verification](companion-idle-animation.md).
The results and checksums below describe the original build 4 verification.

## Report and reproduced failure path

The user reported that PTT starts and then quits. It remains unconfirmed whether only Listening stops
or the entire app exits; clarification was requested. No current Ivy crash report was found in the
local DiagnosticReports folder (only older retired reports). The exact hardware failure is unconfirmed.

The native driver previously returned false when the physical key-state table had not observed a
hold, even after Carbon delivered a press. The coordinator polls every 50 ms and ends PTT on false.
A native in-process Carbon notification with no physical keyboard event reproduces that disagreement:
the old physical-state calculation reports released, allowing the watchdog to cancel startup.
This proves a cancellation path in the code, not its frequency on the user's keyboard.

## Build 4 behavior

- Carbon press/release callbacks are authoritative. An initial unobserved physical reading is unknown,
  so it cannot end capture immediately.
- Polling recovers release only after observing the key or required modifiers held in that press.
  Verified key-first or modifier-first release ends input and unlocks the next native press.
- Fresh press notifications reset evidence and are deliverable after Stop or a missing release.
  The coordinator retains its existing idempotency against repeated starts.
- A real release callback still works if physical inspection remains unavailable. Stop, disabling PTT,
  errors and shutdown close resources. If physical inspection and release delivery are both unavailable,
  polling cannot prove a release; use Stop.
- The release closes microphone input, submits speech once and preserves the reply/approval flow.
  It never approves a tool. No Pointer feature or extra keyboard-monitoring permission is added.
- Shortcut choices and visible conflict feedback from build 3 remain available.

## Verification

- Strict Swift 6 debug build passed with no compiler warnings/errors.
- 1,292 core tests in 181 suites (3.211 s) and 30 native UI tests in 5 suites (31.605 s): 1,322 pass.
- Changed executable lines across the current uncommitted source changes: 105/108 covered (97.22%),
  combining core and native UI test binaries. Warm strict build: 0.19 s.
- Native Carbon notification tests verify unknown initial readings, authoritative release, fresh press
  after a recovered/missing release and press delivery after Stop. Pure state fixtures verify both
  key-first and modifier-first recovery, including an unreadable key with observable modifiers.
- Deterministic voice fixtures verify unknown polling retains capture, real release submits once and
  reply completion cleans up, alongside existing silence, connection, approval and lost-release tests.
- Tests record no real audio and send no physical keyboard events into other apps.

## Package verification

- Artifacts at verification: `dist/Ivy.app` and `dist/Ivy-1.1.0.dmg`, 1.1.0/build 4, arm64,
  ad-hoc signature with Hardened Runtime. Release compile: 28.79 s, no compiler warnings/errors.
- Package credential scan found zero leaks. Deep/strict app signatures, DMG integrity and SHA-256
  sidecar pass. Read-only mount verifies metadata, matching executable and Applications link;
  verification volume was ejected.
- DMG SHA-256: `9043eb6c0b100a55f00ae59059590c784acd40578da622a3f5179e63d99ad795`.
- Executable SHA-256: `a76bff4a82c1ec1ac99dde4115ab63684e8b66e9bfab85068898842f34b221ab`.
- Build 3 is preserved under `dist/Previous-Builds/Before-PTT-Build4-2026-10-05-fbddnM/`.

## Manual acceptance

Quit older copies, install the new app from the DMG and confirm About shows 1.1.0 (build 4).
Enable General → Push to talk and Show the Ivy companion. Check the shortcut registration status.
With TextEdit or Safari focused, hold the selected shortcut, speak, then release. Listening should
remain while held; the microphone should close on release while Ivy finishes the reply.
Repeat after Stop, after a silent press and after changing the shortcut. If the whole app exits,
collect the new Ivy crash report; this session-level cancellation fix is not evidence of a crash fix.
Physical cross-app keyboard/microphone acceptance was not performed by automated tests.

No installed app, macOS permissions, user data or GitHub release was modified.
