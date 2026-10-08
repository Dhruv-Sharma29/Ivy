# Blushing companion idle animation — 2026-10-07

## Prepared in build 10; included in 1.1.0, build 11

Ivy occasionally holds her hands together at her chest, blushes and softly blinks while idle.
Four matching pixel-art frames show an open-eye, half-closed, closed-eye and open-eye progression
with rosy cheeks. The new eight-second moment joins phone and laptop activities with equal selection
probability. Sampling stays deterministic for each randomly seeded idle episode, with one activity
per 48-second window after 12–24 seconds of quiet. Blush frames advance every 0.65 seconds.

Real listening/thinking/speaking/working/approval/error states, dragging, hiding and Reduce Motion
retain priority. The status remains Ready; this decorative pose does not imply a tool or action.
Dancing remains removed: indices 24–27 stay unavailable. New blush frames use indices 28–31.

## Artwork and integration

- Saved asset: [IvyCompanionBlushSprites.png](../Sources/Ivy/Resources/IvyCompanionBlushSprites.png).
  The original phone/laptop and real-activity sheets are preserved.
- Generated with the built-in `image_gen` tool using existing Ivy sprites as character/style references.
  No API-key workflow or third-party generation service was used. Actual alpha is preserved.
- The selected PNG is 1,254×1,254 pixels with four poses. Source-frame rectangles extract equal-size
  cutouts from uneven transparent gutters. The native sprite view preserves aspect ratio and uses
  a constant scale/baseline offset so she stays in place through the blink. Frames are cached once.
- Generation prompts are recorded below. The generated source sheet is saved in the repository,
  rather than referenced only from the generation cache.

## Verification

- Full coverage run: 1,306 core tests in 183 suites (3.089 s) and 35 native UI tests in 5 suites
  (34.826 s), totaling 1,341 passing tests. No tests were removed or skipped.
- Existing idle assertions now include blush selection/timing and all four new frames. Every idle
  activity is checked for immediate interruption by real states, hiding, dragging and Reduce Motion.
  The retired dance indices still return nil.
- Changed executable lines across the working tree: 83/84 covered (98.81%); companion animation/cache
  changes specifically: 25/25 covered (100%). Coverage was exported before the non-instrumented build.
- All four new frames load with transparent edges and opaque character pixels from the declared
  Swift package resource. Native light/dark galleries were inspected at `/private/tmp/ivy-idle-review/`;
  they show aligned clasped hands, rosy cheeks and a blink at actual companion size.
- Strict Swift 6 debug build passes without compiler warnings/errors. Recompile after coverage:
  10.31 s. Tests use offline provider/audio/tool fixtures, with no real microphone or desktop tools.

## Combined release

Build 11 includes this artwork and [PTT reply interruption](ptt-interrupt-reply.md). The final combined
coverage run passes 1,345 tests with 99.09% changed-line coverage; companion changes remain 100% covered.
See the interruption report for the final package and installation checks.

## Try it

Check About shows **1.1.0 (15)**. Enable **Show the Ivy companion** and **Keep visible when idle** in
Settings → General. Leave Ivy ready for 12–24 seconds. Blushing is one of three random idle activities,
so allow several quiet cycles to see it. Voice, tasks, approvals and dragging interrupt it immediately.
With system Reduce Motion enabled, Ivy uses the ordinary still idle pose.

## Generation prompts

Both calls used built-in image generation with `transparent_background: true`.

Initial generation, with the original real-activity and idle sheets as references:

> Asset type: transparent pixel-art animation sprite sheet for Ivy's native macOS on-screen companion. The two inputs are character/style references ONLY, not a sheet to overwrite. Generate ONE NEW PNG sprite sheet with EXACTLY FOUR full-body poses in a strict 2-column by 2-row equal square-cell grid. Transparent background with real alpha; no text, labels, cell borders, props or shadows. Match the referenced Ivy character precisely: chibi proportions, long dark chestnut hair, ivy-leaf hair clip on the viewer's left, lavender-purple eyes, charcoal oversized sweater, dark trousers and boots, crisp chunky pixel art and dark outlines. Preserve her identity, outfit, palette and the scale of the character inside each square cell: full body occupies about 85% of cell height with equal transparent margins. All four characters have the SAME baseline, body size and centered position. New requested idle action: a gentle shy smile, rosy pink BLUSH on both cheeks, both small hands held/clasped together at the center of her chest, shoulders relaxed. The hands must touch, NOT crossed arms and NOT two separate fists. Feet stay planted, no dance or waving. In row-major order, frame 1: eyes open, faint blush, hands softly clasped. Frame 2: slightly warmer blush, eyes softly half closed, same clasped hands. Frame 3: a brief closed-eye happy blink, deeper soft blush, same clasped hands. Frame 4: eyes open again, blush softens, same pose. Tiny natural breathing/head changes only, tightly aligned to make a smooth quiet animation loop. Keep all fingers/hands coherent and simple in the established pixel style. Output a square sheet, 2x2 grid, four aligned poses total.

Alignment refinement, using the first generated sheet as the edit target:

> Precise sprite-sheet alignment edit. Keep these SAME FOUR Ivy clasped-hands blushing pixel-art characters and their expressions, identity, clothing, palette and transparent alpha. Do not redesign them. Keep a square 2x2 equal-cell sprite sheet. Change ONLY their placement/alignment inside the four cells so the loop has NO sideways or vertical jumps. Every character must have its bounding-box horizontal center EXACTLY at its own cell center and its boots baseline EXACTLY 94% down its own cell. Each character has the SAME approximately 88%-of-cell body height. Use identical clear margins: 6% above hair, 6% below boots, horizontal symmetry. Top-left character currently sits too far right and too low; top-right too far left and too low. Bottom-left too far right; bottom-right too far left. Reposition these cutouts consistently to correct that. No cells overlap. Preserve the blush/open-half-closed-closed-open eye progression and hands touching/clasped at chest. No borders, text, props, background or shadows. Crisp chunky pixel art. Real transparent background. Four frames total, strict aligned 2 columns x 2 rows.
