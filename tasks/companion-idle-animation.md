# Idle companion animations — 2026-10-07

Current artifacts are build 20, retaining phone/laptop animations and [chat ordering](chat-feed-ordering.md),
and adding [blushing/clasped hands](companion-blush-animation.md).
[Dancing has been removed](companion-dance-removal.md). The measurements below describe the original build 7 delivery.

## Delivered in 1.1.0, build 7

Ivy now has three additional idle activities: checking a phone, typing on an open laptop and a
short dance. Each uses four matching pixel-art frames. The original real-activity sheet is preserved.
The new artwork lives in [IvyCompanionIdleSprites.png](../Sources/Ivy/Resources/IvyCompanionIdleSprites.png).

A random seed is chosen on each return to idle. Within each 48-second window, an activity starts
after 12–24 quiet seconds and lasts 9 seconds (phone), 11 seconds (laptop) or 5 seconds (dance).
Selection favors phone/laptop over dancing. Frame sampling is deterministic for a given seed/time,
does not allocate timers and uses the existing modest-rate TimelineView. Sprites are decoded and
cropped once, then reused. The 1,448×1,086 transparent sheet has a 4×3 grid of 362×362-pixel cells.

Listening, thinking, speaking, working, approval, error and dragging take priority immediately.
Hiding pauses the timeline. Reduce Motion uses the regular still idle pose, including while dragging.
Returning to idle or enabling motion starts another quiet interval. The status stays Ready: the props
are decorative, do not access devices or files, and never execute or approve tools.

## Verification

- Strict Swift 6 debug build passes without compiler warnings/errors.
- Full suite: 1,301 core tests in 182 suites (2.875 s) and 34 native UI tests in 5 suites
  (38.783 s): 1,335 passing tests. No tests were removed or skipped.
- Changed executable lines across current source changes: 446/477 covered (93.50%).
  The idle schedule and modified sprite code specifically: 65/65 covered (100%).
- Deterministic fixtures verify varied activities/timing, quiet intervals, bounded durations,
  all frame indices, invalid/extreme timestamps, state priority, dragging and Reduce Motion.
- All 12 transparent frames load from the bundled resource. Native render checks inspect actual
  96-point sprites in light/dark appearances. Review images are at `/private/tmp/ivy-idle-review/`.
- No real microphone input, provider requests or desktop app launches occur in these tests.

## Package verification

- Current artifacts: `dist/Ivy.app` and `dist/Ivy-1.1.0.dmg`, 1.1.0 (build 7), Apple silicon (`arm64`).
- Warm strict build: 0.35 s. Release build: 28.24 s, without compiler warnings/errors.
- Ad-hoc signature with Hardened Runtime; Apple notarization remains unconfigured.
- Package credential scan: zero leaks. Deep/strict signatures, DMG integrity and SHA-256 sidecar pass.
  A read-only mount verified version metadata, matching executable, matching new sprite asset and the
  Applications link. The verification volume was ejected. `git diff --check` and local doc links pass.
- DMG SHA-256: `4a883db477390662e43843b6b9c604a423e802ec9dbaa9ebff9616dd6371517d`.
- Executable SHA-256: `c5836ae076cd84978f711dcc3def8c0f87a85215ad0694811d4413514db06d9f`.
- Build 6 backup: `dist/Previous-Builds/Before-Idle-Build7-2026-10-07-G4jNb4/`.

## Try it

Quit the older Ivy copy, replace it with the updated app from the DMG and check About shows build 7.
In Settings → General, enable **Show the Ivy companion** and **Keep visible when idle**. Leave Ivy
ready for 12–24 seconds to see an activity; wait through later quiet intervals for other activities.
Ask a question, start voice or drag the companion to check immediate interruption. Enable the system
Reduce Motion setting to check the ordinary still idle pose.

## Artwork provenance and prompt

Generated with the built-in image-generation tool, using the existing
`Sources/Ivy/Resources/IvyCompanionSprites.png` only as a character/style reference. The original
sheet was not replaced. The selected output was copied into the repository resource directory and
added to Package.swift. The original generated output remains in the tool's generated-images folder.

Prompt used:

> Use case: stylized-concept. Asset type: production pixel-art animation sprite sheet for Ivy's small macOS desktop companion. Input image is the character/style reference only; create a NEW additional idle sheet, do not modify the original sheet. Exactly a regular 4-column by 3-row grid of 12 square transparent cells (overall aspect ratio 4:3). Each cell contains the SAME full-body Ivy character: long dark brown hair, green ivy-leaf hair clip on viewer's left, purple eyes, charcoal sweater, dark trousers and boots; match the chunky chibi pixel art, proportions, colors and clean dark outline of the reference. Consistent head/body scale and feet baseline in all cells. Character centered per cell, about 80% cell height, generous clear transparent margins; nothing crossing cell boundaries. Row 1 four consecutive animation frames of Ivy casually looking down at a small smartphone held in front of her chest, thumb tapping, slight blink, tiny head tilt. The phone is portrait-oriented and unmistakable. Row 2 four consecutive animation frames of Ivy typing on a small open laptop held at waist height, visible open lid and keyboard, looking down, alternating hands/blink. Row 3 four consecutive animation frames of Ivy doing a playful short dance: step left arms lifted, center arms bent, step right arms lifted, center slight bounce. Dance is full body, feet/arms change, hair follows slightly. Full character visible in every cell; avoid huge props obscuring her face. No text, no labels, no grid lines, no backgrounds, no shadows cast beyond character. Crisp visible square pixels rather than smooth painting. Real transparent alpha background.

No installed Ivy copy, user data, permissions or GitHub release was modified.
