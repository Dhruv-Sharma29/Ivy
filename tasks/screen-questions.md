# Screen questions — 2026-10-04

Implemented and included in `dist/Ivy.app` and `dist/Ivy-1.1.0.dmg` (1.1.0, build 2, arm64).

## Try it

1. Enable push-to-talk in General settings. In Pointer settings, enable Hold shortcut to select and
   choose Voice key (⌘⇧Space). These are the new selection defaults; the visual Follow my cursor toggle
   controls the separate decorative leaf.
2. Open another app. Hold ⌘⇧Space, hover or draw around an area, and ask “What is this?” or
   “How does this work?” The dashed rectangle shows all included pixels, including lasso corners.
3. Release the shortcut. Ivy closes the microphone, captures/redacts the crop in memory, sends its
   labeled image first, then submits the buffered utterance and answers. Esc cancels during selection.
4. For a typed question, choose R/A in Pointer settings or use the menu's Ask about a screen area action.
   Freehand/Rectangle switch the gesture. Arrow keys position a hover crop; Return attaches it.
   Quick chat previews the crop and preserves existing draft text until explicit Send.

Grant microphone and Screen Recording permissions when requested. The selector opens after microphone
and speech-permission prompts close; a key released during those prompts is cancelled, so press again.
Capture denial shows recovery actions; granting permission never retries old coordinates automatically.

## Behavior and limits

- Reuses the existing voice hotkey handler; no competing registration. R/A alternatives update immediately.
- Speech is buffered only for a spatial voice turn, with a 30-second/960,000-byte PCM cap. Silence,
  failed or cancelled capture, mic denial, stale windows/displays and session stop send no buffered speech.
- The selector intercepts input only while explicitly selecting. Sleep, display changes, lock, shortcut
  changes, Esc and quit tear it down. Display wake cannot unlock an inactive session.
- Captures exclude Ivy and the configured protected-app list, are limited to a 2048-pixel long edge,
  and pass through existing local OCR/redaction and request limits. Audio and image bytes are not persisted.
- Voice uses a private capture result rather than staging an unused screenshot in the composer's tray.
  Typed selections stage in the tray; their geometry is recorded when actually sent for `point_at`.
- Turning off screen-question shortcuts keeps ordinary audio-only push-to-talk. The explicit menu action
  remains available. Active tasks, desktop control, chat work and approvals block selection.
- This is an initial 20.12 slice: bounding crops, not exact polygon masking or rich drawing. Typed images
  are snapshots; target freshness at typed submission, full walkthroughs and arbitrary key assignment remain open.

## Verification

- 1,298 core tests and 38 native UI tests passed; execution 3.037 s + 31.654 s (under the 60 s floor).
- Changed executable source lines: 407/486 covered (83.74%). Voice ordering, bounded buffering,
  cancellation, late-result rejection, permissions, redaction staging, geometry and lifecycle behavior
  use isolated fixtures. Native ScreenCaptureKit capture and most production callback wiring require
  live hardware validation; coverage is not evidence of a real microphone/screen capture.
- Swift 6 strict-concurrency debug/release builds: zero compiler warnings or errors. Warm incremental
  strict build: 0.18 s. Fixed two existing fixed-delay test synchronizations without removing assertions.
- Offscreen previews inspected: selected-area bounds, Quick chat crop review and Pointer settings.
  Settings card controls render correctly; offscreen macOS sidebar/header colors remain unreliable.
- Package signature verified; DMG CRC and SHA-256 verified; read-only mounted executable matches
  `dist/Ivy.app` byte for byte and the installer Applications link resolves correctly. Ad-hoc testing
  signing is retained; no notarization, GitHub upload, version tag or installed application was changed.
- Previous app/DMG/checksum preserved under
  `dist/Previous-Builds/Screen-Questions-2026-10-04-X5Bvr4/`.
- DMG SHA-256: `494eed6413a2810c2e63fe4b9fc4a676c96c5a56757a965937e72bd3e6b81fff`.

Still needed: a real shared-key voice test with microphone/Screen Recording enabled, Retina/external
display checks, and permission-denial/relaunch testing on the friend's Mac. No live screen or microphone
was recorded while running this verification.
