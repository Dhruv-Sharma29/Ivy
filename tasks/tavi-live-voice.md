# Tavi Live voice

Current artifacts are build 24, adding [explicit push-to-talk activity submission](ptt-activity-boundaries.md).
The build-21 output test below did not establish speech-input recognition; build 22 tests that separately.

Requested 2026-10-08 for local v1.1.0 build 21.

## Voice and model

Google's authenticated voice catalog returned Tavi as `en-us-tavi`, an en-US female prebuilt voice
with a Gulf Coast accent. Its persona includes Commercial Voiceover (Fashion Consultant).
Only this matching catalog record was retrieved; credentials were not printed or saved.

The existing `gemini-3.1-flash-live-preview` model rejected this exact voice with WebSocket close
code 1007: no matching speaker voice. `gemini-3.8-live` accepted it with `setupComplete`.
The app therefore uses `models/gemini-3.8-live` and `en-us-tavi` for Live voice and push-to-talk.
Both initial setup and reconnects retain the same voice ID.

Google's [voice catalog API](https://ai.google.dev/api/voices) documents the catalog, and its
[Live migration guide](https://ai.google.dev/gemini-api/docs/models/gemini-3.8-live) documents
the model change. Live 3.8 defaults to asynchronous tools; Ivy explicitly encodes `BLOCKING`
for Live declarations to preserve approval/result-before-reply ordering. The shared REST tool
schemas and saved voice preferences are unchanged. Unsupported thinking configuration is omitted.
Optional ElevenLabs Read Aloud remains separate from the Live voice.

## Provider verification

A short synthetic-text test used the same voice/model with input/output transcription,
500-ms silence tolerance and one harmless mock blocking function. Google accepted setup,
requested the test function once, received its mock result and returned 102,720 audio bytes
before completing the turn and closing normally (code 1000). No microphone recording, personal
conversation or real Mac action was sent. This confirms audio generation and tool protocol,
not subjective voice quality or physical microphone behavior.

## Try it

1. Quit and reopen the updated Ivy app from Applications.
2. Hold Command–Shift–Space, say “Hello Ivy, introduce yourself,” then release.
3. Listen for Tavi. Press the shortcut during the reply to interrupt and ask a new question.
4. Try a harmless app-opening request, then a request requiring approval. Review/approve only
   the action you intended; Ivy must wait for the explicit decision and actual tool result.

Microphone permissions, real keyboard capture in other apps, audible playback and long sessions
remain manual checks. Closing the workspace leaves the companion resident; Quit stops Ivy.

## Build and package verification

- Full suite: **1,367 tests pass** (1,324 core in 2.945 seconds; 43 native UI in 36.158 seconds;
  39.103 seconds combined). Three migration tests were added. Voice-lock, reconnect, interruption,
  release and approval assertions remain enabled and now expect the verified voice/model.
- Changed executable lines: **14/14 covered (100%)**. Strict Swift 6 debug/release builds passed
  without compiler diagnostics. Release compilation took 34.40 seconds; the warm strict build 0.18.
- Production source and packaged credential scans are clean. Existing synthetic test keys remain
  in security fixtures; no real credentials were printed, saved or added to the repository.
- App and mounted/installed executable comparisons, build metadata, Hardened Runtime ad-hoc
  signatures, arm64 architecture, DMG integrity, SHA-256 sidecar and Applications link passed.
  This friend-testing build remains unnotarized.
- `/Applications/Ivy.app` and `dist/Ivy.app` contain v1.1.0 build 21 with `LSUIElement=true`.
  Ivy was idle, quit normally, updated and relaunched. Its visible surface was the companion only.
- Executable SHA-256: `bd06ba54cea1ffa80decfabe255a04f6c6adb51db8984c4debfca531b3894396`.
- DMG SHA-256: `b369ab1d6847eded7294a25989938a226e14a14a6a530d0faf38f5454ca78b31`.
- Packaged rollback: `dist/Previous-Builds/Before-Tavi-Build21-2026-10-08-v2f6l_56`.
- Installed rollback: `dist/Previous-Builds/Before-Applications-Install-Build21-2026-10-08-jphlk8`.
