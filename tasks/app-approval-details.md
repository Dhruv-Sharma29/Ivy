# Detailed app approvals

Current artifacts are build 20, retaining this app/companion UI and adding [voice reply recovery](voice-reply-recovery.md).


Implemented 2026-10-08 in v1.1.0 build 16.

## Behavior

The workspace uses a separate detailed native approval sheet. It shows the original action title,
explanation and selectable action details. Calendar requests show the event title, date/time and
duration supplied by the safety gate; scripts and commands show their actual requested text.
File previews retain the safety gate's existing preview limit. This UI does not invent missing details.

A scrollable review area contains long explanations and details. A pinned footer keeps the approval
notice and Cancel / Do it available. The sheet measures 460×400 points with details, or 460×300
without details, and fits the 560×480 minimum workspace. Appearance follows Ivy's adaptive surfaces.

The companion source and compact card are unchanged from build 15. Light and dark companion
approval images are byte-identical to the before-change snapshots. Background approval handoff
still presents that compact card.

Escape refuses; Command-Return or clicking Do it approves. Plain Return cannot approve.
Repeated answers are guarded. Existing request identity checks, cancellation and the single-sheet
presentation remain in place; rendering never executes an action.

## Verification

- 1,351 tests pass: 1,311 core tests in 2.855 seconds and 40 native UI tests in 38.183 seconds.
- Native sheet tests retain the single-sheet and full minimum-window containment assertions.
  Long/empty requests and a calendar request render in light and dark appearances.
  The former 280×100 assertions were updated because the user requested app-only detailed review;
  compact companion assertions and identity/cancellation checks are retained.
- Changed executable source lines across local changes: 410/416 (98.56%); the new sheet is 87/92
  (94.57%). Uncovered sheet lines are the one-response callback guard, not the review layout.
- Strict Swift 6 build passes with zero compiler diagnostics; warm build completes in 0.18 seconds.
- Secret scan matches only pre-existing synthetic credential/redaction test fixtures.
- Previews: `/private/tmp/ivy-app-approval-review/approval-calendar-dark.png` and
  `approval-calendar-light.png`; long-request and empty-detail previews are in the same directory.
- The Mac is locked, so a physical check of the installed app remains pending. Offscreen native
  windows and rendered content were verified; no approval was granted during preview generation.

## Try it

Relaunch Ivy, keep the workspace open, and ask it to create a calendar event. Review its actual
explanation and details, then Cancel if this is only a UI test. Work in Background retains the
small companion card rather than the detailed workspace sheet.

## Package verification

- `dist/Ivy.app`, `/Applications/Ivy.app` and the app mounted from `dist/Ivy-1.1.0.dmg` all
  contain version 1.1.0 build 16 and the same arm64 executable. Strict deep signature checks pass;
  signing remains ad hoc with Hardened Runtime for local friend testing.
- DMG integrity and SHA-256 sidecar checks pass. The image includes the Applications link.
- Executable SHA-256: `e2c2f7510f88e05c3cef667719c1f6eb8425ac61c87fc8570aaf33dac02b72b8`.
- DMG SHA-256: `1c6c8ac8d27a1907302a9972089786066197d3de3e8731aa4d71dc1734512f48`.
- Previous package: `dist/Previous-Builds/Before-App-Approval-Build16-2026-10-08-SPpp9a/`.
- Previous installed app: `dist/Previous-Builds/Before-Applications-Install-Build16-2026-10-08-DgmK3u/`.
- The existing running process (PID 56448) was left uninterrupted. Relaunch to load build 16.
- macOS reports deprecation notices for the system's `hdiutil` commands; image verification succeeds.
