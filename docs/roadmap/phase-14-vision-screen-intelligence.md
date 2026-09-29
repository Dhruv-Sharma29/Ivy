# Phase 14 — Vision & Screen Intelligence

## Goal
"Ivy, what's wrong with this error?" — Ivy can see what you see, **only when you ask**: the whole screen, a
window, a region you draw, a dropped image or a PDF. It reads text on-device, understands UI, and answers in
chat or by voice. This is also the foundation for the Phase 17 on-screen companion (pointing/annotating).

## Baseline
- REST `GeminiClient` sends text/function parts only; no image parts.
- Live sends 16 kHz audio only (`realtimeInput`), no video/image frames.
- Phase 11 adds a `screenshot` tool (ScreenCaptureKit, memory-only) — Phase 14 makes it useful.
- No Screen Recording permission requested today.

## Scope
**In:** capture (screen, window, region, current app), "What am I looking at?" hotkey, drag-and-drop images,
image/PDF analysis, on-device OCR, UI element understanding, screen context in Live voice, privacy
controls. **Out:** continuous screen watching, background capture, storing screenshots, video recording.

## Design

### Capture service
```text
ScreenContextService (@MainActor)
 ├─ capture(.display | .frontWindow | .window(id) | .region(rect)) → CapturedImage (in memory, PNG/JPEG data)
 │     ScreenCaptureKit (SCScreenshotManager); excludes Ivy's own windows
 ├─ RegionSelectorOverlay  — full-screen transparent NSPanel, drag to select, Esc to cancel
 ├─ OCR (Vision VNRecognizeTextRequest, on-device) → [TextBlock(text, rect)]
 ├─ UI tree (optional, Accessibility API) → frontmost app name, window title, focused element role/label
 └─ Redaction pass: blur rects whose OCR text matches SecretRedactor patterns before upload
```
- **Triggers (explicit only):**
  - Hotkey ⌘⇧S (configurable): capture front window → open Ivy with the image attached + "What am I looking at?".
  - ⌘⇧S then drag → region.
  - Toolbar button in the chat composer: screen / window / region.
  - The `screenshot` tool (model-initiated) is **risky** → SafetyGate card shows *which* display/window will
    be captured, before capture.
  - Voice: "Hey Ivy, look at this" inside a Live session → capture front window (confirmation card if the
    setting "Ask before voice-triggered captures" is on — default on).
- Visual feedback: screen flash + menu-bar badge "Ivy saw your screen" for 3 s; macOS's own
  screen-recording indicator also shows.

### Model input
- REST: add `inlineData` image parts (`image/jpeg`, max 2048 px long edge, quality 0.8, ≤ 4 MB) plus OCR text
  and UI context as a text part (helps accuracy, reduces tokens when OCR suffices).
- Live: send a single JPEG frame via `realtimeInput.video`/`mediaChunks` on capture (no streaming video);
  the coordinator attaches it to the current user turn.
- "OCR-only" privacy mode (setting): send extracted text, never pixels.

### Images & PDFs
- Drag-and-drop onto the chat window/popover or paste (⌘V) images: PNG/JPEG/HEIC/WebP, re-encoded to JPEG,
  EXIF/GPS stripped.
- PDFs via PDFKit: text extraction per page (≤ 50 pages, ≤ 200 KB text); pages rendered to images only when
  the page has little text (scans) and only up to 10 pages; user sees what will be sent.
- Attachments appear as chips in the composer and thumbnails in the message; **conversation history stores a
  placeholder** ("[screenshot of Xcode — not saved]") plus OCR summary if the user enables "Keep text from
  images", never pixels.

### Screen-aware assistance (feeds Phase 17b)
- The model can return `annotations` via a `point_at` tool: `{ rect | ocrTextAnchor, label }` in screenshot
  coordinates; `AnnotationOverlay` maps them back to screen coordinates (display scale, multi-monitor) and draws
  a highlight + label for 6 s (heyclicky-style "draws on your screen"). Pure display: `point_at` is **safe**
  and cannot click or type.

## Work breakdown
| Slice | Deliverable | Acceptance |
|---|---|---|
| 14.1 | ScreenContextService capture (display/window/region) + permission flow | Capture excludes Ivy windows; denial → clear card with Settings link |
| 14.2 | Region selector overlay | Multi-monitor, Retina scale correct; Esc cancels |
| 14.3 | On-device OCR + secret blur | OCR text returned with rects; fake key on screen is blurred before upload (test with fixture images) |
| 14.4 | REST image parts + OCR text | "What's this error?" on a fixture screenshot answered; payload ≤ 4 MB |
| 14.5 | Hotkey "What am I looking at?" | One keypress → Ivy opens with capture attached |
| 14.6 | Drag/drop/paste images + EXIF strip | GPS removed (test); chips + thumbnails |
| 14.7 | PDF analysis | Text PDFs and scanned PDFs handled within limits |
| 14.8 | Live image frame | "Hey Ivy, look at this" answers about the window in voice |
| 14.9 | `point_at` + AnnotationOverlay | Highlights the right element on fixture layouts, multi-display |
| 14.10 | Privacy settings + history placeholders | No pixels on disk (test scans Application Support) |

## Safety & privacy
- Capture only on explicit user action or confirmed tool call; never timers, never background.
- Ivy's own windows excluded; optional per-app exclusion list (e.g. 1Password, banking) → capture refuses
  with a message when that app is frontmost.
- No screenshot or PDF image is written to disk; memory released after the request.
- OCR secret blur on by default.

## Testing
- Fixture images (terminal error, Xcode error, settings pane, fake-key screen) for OCR/blur/payload tests.
- Fake capture service for UI/flow tests; no TCC in tests.
- Coordinate-mapping tests for annotations (scale factors 1×/2×, two displays, negative origins).

## Risks
| Risk | Mitigation |
|---|---|
| Sensitive content uploaded | Explicit trigger, visual feedback, exclusion list, OCR-only mode, secret blur |
| Large payloads / cost | Downscale, JPEG, OCR text first, page limits |
| Annotation misplacement | Anchor by OCR text when possible; test mapping thoroughly |

## Exit criteria
All slices accepted; "no pixels on disk" test; exclusion list honoured; manual checklist passed.

## Manual checklist
- [ ] ⌘⇧S on a terminal error → Ivy explains it.
- [ ] Region-select a chart → Ivy describes it.
- [ ] Drop a photo → GPS stripped, Ivy describes it.
- [ ] Analyse a 20-page PDF and a scanned PDF.
- [ ] Open 1Password (excluded) and press ⌘⇧S → refused with message.
- [ ] Put a fake API key on screen → blurred in the preview of what's sent.
- [ ] "Where's the export button?" → Ivy highlights it on screen.
