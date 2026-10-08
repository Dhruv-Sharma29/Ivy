# Voice reply recovery

Implemented 2026-10-08 in v1.1.0 build 17.

## Problem and behavior

Previously, setup had a timeout but a released voice request could wait indefinitely for model
output or a missing turn-complete event. Local voice activity detection confirms sound energy,
not accurate recognition; noise could therefore leave a one-shot request in Thinking.

The coordinator now owns a response inactivity deadline. A PTT turn without a nonempty recognized
transcript, tool call or reply content closes after 8 seconds with “I couldn't confirm what you
said. Please try again.” Confirmed turns and streaming replies close after 15 seconds of inactivity
with “Ivy's voice reply stalled. Please try again.” New reply content renews that deadline.
Blank transcripts and empty audio chunks do not count as progress.

Cleanup releases the microphone, playback, socket and session tasks. A fresh shortcut hold starts
a new request; partial transcripts are retained. Commands are not automatically replayed, because
a real action might have finished before its spoken confirmation stalled. This bounds failure
recovery; it does not claim to improve the provider's actual inference speed or infer that a
recognized transcript accurately represents the user's intended question.

Approval review and pending/running tools have no model response deadline. A finished tool starts
a new deadline while its result is sent and the spoken follow-up is awaited. Audio playback after
turnComplete retains its normal drain lifetime. Completion, interruption, reconnect and shutdown
cancel response deadlines. Session token, connection epoch and deadline identity checks prevent
old callbacks from closing replacement sessions.

The app and companion appearance remain as in build 16.

## Verification

Ten deterministic regression cases exercise noisy/unrecognized input, recognized-but-stalled
speech, streaming progress, missing completion, unlimited approval review, real slow tool execution,
expiry racing interruption, text-only progress, deadline-monitor failure and withdrawn queued tools. They use a controllable deadline clock and real
coordinator/dispatcher flows with fake microphone, socket and executors. Tests confirm no repeated
submission, no approval granted by timeout and no second tool execution.

The first full run exposed test synchronization issues: task bookkeeping clears before awaited
teardown settles, and TOOL_EXECUTION is published before the actor enters execute. Checks now wait
for completed teardown, actual tool startup and registration of a renewed deadline, while retaining
all resource and safety assertions. The final queued-tool check verifies that removing the last
withdrawn queued call resumes the model deadline after the real tool finishes.

## Manual checks

Relaunch Ivy to load build 17. Hold Command-Shift-Space, speak a short request, then release.
Repeat with an unclear/noisy utterance. If the service cannot confirm input or stops responding,
Ivy should show a retry notice rather than remain Thinking. Hold the shortcut again for a new
request. A pending approval should remain available until you decide; a long-running approved task
should not be cancelled by this voice deadline.

Real microphone/provider timing and physical cross-app shortcut checks remain pending while the
Mac is locked. Offline regression tests do not establish live response latency.

## Automated verification results

- Final full suite: 1,361 tests pass, with 1,321 core tests in 2.914 seconds and 40 native UI tests in
  38.214 seconds. No tests were removed or skipped.
- Changed executable source lines across the local working tree: 488/494 covered (98.79%). All
  108 changed executable lines in the voice coordinator are covered; no threshold was weakened.
- The companion view and compact confirmation card remain identical to the before-change source.
- Source credential scan is clean. No provider credentials or live API requests are used by the tests.

- Swift 6 strict concurrency build passes with zero compiler warnings/errors. Warm incremental
  build completes in 0.17 seconds. The full rebuild after instrumented tests takes 6.51 seconds.

## Packaged and installed

- `dist/Ivy.app`, the app mounted read-only from `dist/Ivy-1.1.0.dmg`, and `/Applications/Ivy.app`
  contain 1.1.0 build 17 with identical arm64 executables. Strict deep signature checks pass.
- DMG integrity and SHA-256 sidecar checks pass; the image retains its Applications link.
  Signing remains ad hoc with Hardened Runtime for friend testing.
- Executable SHA-256: `cfbb6d6d765849ba3940a72fd45d23ff9d1d1e2f800ae0722c28954cb255e0a6`.
- DMG SHA-256: `6132061e00616304c42e6c892b4888b32b371959934508abb8302e83423b7799`.
- Package rollback: `dist/Previous-Builds/Before-Voice-Recovery-Build17-2026-10-08-vveyN2/`.
- Installed app rollback: `dist/Previous-Builds/Before-Applications-Install-Build17-2026-10-08-ANVz8H/`.
- Running process PID 56448 was left uninterrupted. Relaunch Ivy to load build 17.
- The system's `hdiutil` deprecation notices do not prevent successful image verification.
