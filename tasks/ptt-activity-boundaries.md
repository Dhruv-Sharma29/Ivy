# Push-to-talk activity submission

Requested 2026-10-08 after the Tavi build displayed “I couldn't confirm what you said.”

## Diagnosis and fix

The recognition watchdog closed a PTT request without input transcription, a tool call or reply.
A locally synthesized 16-kHz mono PCM phrase reproduced a connected session with no recognition
or output for 30 seconds when using automatic activity detection plus `audioStreamEnd`.
The previous model configuration also stalled on this synthetic automatic-VAD test, so this is
not proof that every automatic-VAD session fails or that Tavi itself is defective.

Using the same audio with automatic detection disabled and explicit `activityStart` / `activityEnd`
produced 25 input-transcript characters and 142,560 Tavi audio bytes, completed in 7.6 seconds
including connection and paced input, and closed normally. No microphone recording or personal
conversation was sent. Google's [Live VAD documentation](https://ai.google.dev/gemini-api/docs/live-api/capabilities)
specifies this manual activity protocol.

Build 22 selects manual activity detection before connecting a fresh PTT session. The first audio
frame is preceded by one start marker; releasing the shortcut drains capture and sends one end
marker. It does not use an automatic-VAD flush for that session. Silent presses still cancel,
duplicate release cannot submit twice, reconnects retain manual mode and reset activity identity,
and marker failures are surfaced without replay. Input mode cannot change on an active socket.
Existing hands-free sessions retain their automatic input configuration.

Tavi (`en-us-tavi`), Gemini 3.8 Live, explicit tool approval, response timeouts and companion UI
are retained. The fix does not increase the recognition timeout to hide stalled input.

## Try it

1. Open the updated Ivy from Applications; the companion is the default launch surface.
2. Hold Command–Shift–Space and say “Hello Ivy, what is two plus two?”
3. Release the shortcut. The microphone must stop and Ivy should answer with Tavi.
4. Hold the shortcut during the reply to interrupt, ask another question and release.
5. Try a silent hold; it should cancel without submitting a request.

Physical microphone/keyboard behavior, audio-device routing and subjective playback quality
still need a user test. The synthetic provider test and production coordinator fixtures verify
the submission protocol, rather than establish all device behavior.

## Build and artifact verification

- **1,373 tests pass**: 1,330 core tests in 2.966 seconds and 43 native UI tests in 36.616 seconds
  (39.582 seconds combined). Six PTT protocol regression tests cover the production client/coordinator,
  markers, reconnects, duplicate release, switching back to automatic mode and surfaced failures.
- Changed executable lines across the local working tree: **79/79 covered (100%)**. Strict Swift 6
  debug/release builds have zero compiler diagnostics; the warm strict build took 0.33 seconds.
- Production source and packaged credential scans and `git diff --check` pass.
- Installed, packaged and read-only mounted apps are **v1.1.0 (22)**, arm64, `LSUIElement=true`,
  with verified ad-hoc Hardened Runtime signatures. Executables match; DMG integrity, SHA-256
  sidecar and Applications link pass. This friend-testing build remains unnotarized.
- Ivy was idle and quit normally for installation. The updated app relaunched with only its companion.
- Executable SHA-256: `a2b012e33ce2cbb2c896e3d0826abc7f15eae18eb5ce657f110aacad0fc70cad`.
- DMG SHA-256: `7f6dd077151951404ce4be05b13f24461c35bc26fddeed3b46511779fdaa8942`.
- Release build: 32.62 seconds.
- Packaged rollback: `dist/Previous-Builds/Before-PTT-Activity-Build22-2026-10-08-n8bp2pys`.
- Installed rollback: `dist/Previous-Builds/Before-Applications-Install-Build22-2026-10-08-U63DqU`.
