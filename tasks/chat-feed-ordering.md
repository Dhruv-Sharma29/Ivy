# Chat request and tool-card ordering — 2026-10-07

Current artifacts are build 20, retaining this fix and [dance removal](companion-dance-removal.md),
and adding [blushing/clasped hands](companion-blush-animation.md).
The verification below describes the original build 8 delivery.

## Delivered in 1.1.0, build 8

Tool/script cards now appear directly below the user request that triggered them. The reported
`finder` card appeared above “Open DBS MS folder” because chat sorted all items by timestamps:
voice tools can start before the final user transcript is appended to the conversation.

Typed dispatch passes the user message ID to display activity. Live assigns a stable request ID
for each voice turn, captures it before queued tool execution and uses it for the late transcript.
Additional input chunks from the same turn merge into that user message without changing its ID
or initial timestamp. Completing/interruption/shutdown advances the voice turn identity.

`ChatFeedTimeline` groups cards below known user parents. Multiple cards retain start-time order,
using original record order on ties. Stable message/card IDs preserve disclosure identity through
status updates. Unlinked cards, missing parents and disabled transcript saving retain chronological
placement; Ivy does not invent a question. Raw card arguments/output remain redacted, bounded and
session-only. Approval, tool execution, model history and saved conversation formats are unchanged.

This fixes placement, not the missing-folder error in the screenshot. New requests use the link;
existing unlinked activity does not acquire a guessed parent, and cards are not restored from history.

## Verification

- Five new core regressions cover late transcripts, several turns, equal-time calls, all statuses,
  missing/non-user parents, empty timelines, forwarded activity/reset, merged input and saving disabled.
- A Live/environment fixture delivers a tool before any transcript and checks question/card/reply
  order, then delivers input in late chunks in a second turn. It verifies queued calls keep that turn's
  ID even after turn completion. Typed function-calling integration also asserts its parent ID.
- Full coverage run: 1,306 core tests in 183 suites (2.945 s) and 35 native UI tests in 5 suites
  (34.425 s), totaling 1,341 passing tests. No tests were removed or skipped.
- Changed executable lines: 58/59 covered (98.31%); the new timeline helper is 34/34 (100%).
- Strict Swift 6 build passes without compiler warnings/errors. Recompile after coverage: 7.37 s;
  warm strict build: 0.18 s. Coverage data was exported before the non-instrumented build.
- Native chat fixtures use the reported question and a tool with an earlier timestamp in light/dark
  appearances. Both rendered previews were inspected at `/private/tmp/ivy-feed-order-review/`.
- Tests use offline provider/audio/tool fixtures; no real microphone, provider request or folder
  opening was needed. Physical voice delivery remains a manual acceptance check.

## Package and installation

- `dist/Ivy.app` and `dist/Ivy-1.1.0.dmg`: version 1.1.0, build 8, Apple silicon (`arm64`).
- Release strict-concurrency build: 31.00 s, with no compiler warnings/errors. The package credential
  scan found zero leaks. Ad-hoc signing uses Hardened Runtime; Apple notarization remains unconfigured.
- Deep/strict signatures, DMG integrity and the SHA-256 sidecar pass. A read-only mount verified
  build metadata, matching executable, retained idle sprite asset and the Applications link, then
  was ejected. Local documentation links and `git diff --check` pass.
- DMG SHA-256: `8c5e2f8fc153fdea637b8c900dddb3b595d956c7678daa9588f622a1a4d63e29`.
- Executable SHA-256: `d436976f543a438b19f8f1c72f2d50d3709738b34d22b956cfa3538e8b91815a`.
- Previous package backup: `dist/Previous-Builds/Before-Chat-Order-Build8-2026-10-07-DLkdMR/`.
- Installed `/Applications/Ivy.app` was replaced after a normal quit and reopened. Process inspection
  verified it runs from that path, and its metadata/executable/resource match the verified package.
- Previous installed app backup: `dist/Previous-Builds/Before-Applications-Install-Build8-2026-10-07-P8WdZV/`.

## Try it

Check About shows **1.1.0 (8)**. Ask “Open Calculator” by text, then by push-to-talk. After the voice
transcript appears, its `open_app` card should be below that question, followed by Ivy's reply.
Expand the card to inspect arguments/output. Repeat with another request and check each card stays
with its own question. The actual tool may succeed or fail; its status should not move it above the request.
