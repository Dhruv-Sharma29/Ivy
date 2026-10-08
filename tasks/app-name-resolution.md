# Installed app name resolution — 2026-10-07

The current artifacts are build 17, which retain this fix, phone/laptop
[idle companion animations](companion-idle-animation.md) and [chat ordering](chat-feed-ordering.md).
[Dancing has been removed](companion-dance-removal.md).
[Blushing/clasped hands](companion-blush-animation.md) is an additional idle moment.
The verification below describes build 6.

## Report and cause

The `open_app` tool failed for `VS Code` even though `/Applications/Visual Studio Code.app`
exists on this Mac. The resolver searched for `VS Code.app` by exact filename and had no alias.
The previous error only proved lookup failed; it could not determine download status.

## Build 6 behavior

- `VS Code` and `vscode` resolve to `Visual Studio Code.app` in the existing application search
  directories. Whitespace around the name and case-insensitive `.app` suffixes are handled.
- `VS Code Insiders`, `vscodeinsiders` and `vscode-insiders` resolve separately to
  `Visual Studio Code - Insiders.app`. A missing edition does not launch another edition.
- Exact installed bundle names take priority across search directories before alias fallback.
  Unknown names are not fuzzy-matched. Existing app-name validation and safety policies remain.
- Missing-app feedback identifies a lookup failure and explains extracted `.app` placement in
  `/Applications` or `~/Applications`. It does not claim the app has not been downloaded.
- No software is installed or downloaded by this lookup. It retains the existing application
  search locations; arbitrary Downloads folders are not scanned.

## Verification and package

Regression tests exercise real `SystemWorkspace` resolution against temporary fixture bundles:
aliases, optional suffixes, edition separation, unknown names and exact-name precedence.
Case-insensitive lookup is checked by filesystem identity, accounting for macOS volumes that
preserve spelling but compare paths without case. Existing dispatcher and brain error contracts
remain covered. No test launches an app.

A read-only probe against the actual installed app resolved `VS Code`, `vscode.app` and
`Visual Studio Code` to `/Applications/Visual Studio Code.app`. Launch behavior itself was not
exercised by this probe.

- Strict Swift 6 debug build passes without compiler diagnostics.
- Full suite: 1,301 core tests in 182 suites (3.063 s) and 31 native UI tests in 5 suites
  (35.658 s), totaling 1,332 passing tests.
- Changed executable lines, including the preceding task-panel changes: 381/412 covered
  (92.48%). App lookup/error changes specifically: 23/24 covered.
- No tests were removed or skipped. Missing-app assertions now include the more specific
  lookup wording while preserving the `not found` contract consumed by dispatcher/brain tests.
- Warm strict build: 0.21 s. Release build: 28.70 s, without compiler warnings/errors.
- `dist/Ivy.app` and `dist/Ivy-1.1.0.dmg` contain 1.1.0, build 6, Apple silicon (`arm64`).
  The app uses an ad-hoc Hardened Runtime signature; Apple notarization remains unconfigured.
- Package credential scan found zero leaks. Deep/strict signatures, DMG integrity and the
  SHA-256 sidecar pass. A read-only mount confirmed build metadata, matching executable and
  Applications link; the verification volume was ejected.
- DMG SHA-256: `2117f6b2fd1546e7465e16b8a997c42d92b02832b49e9fef4708282f97625282`.
- Executable SHA-256: `31bc8fba418a42a47a01733f0988949c988fa526a14c9f24d815148a0e47f83f`.

Build 5 is preserved at `dist/Previous-Builds/Before-App-Alias-Build6-2026-10-07-2IB8Zg/`.
Build 6 retains the task-panel changes documented in [task-panel verification](task-panel-flow.md).

## Try it

Quit the older Ivy copy and replace it with the app from the updated DMG. About should show
1.1.0 (build 6). Ask “Open VS Code.” An earlier failed tool card is a record of that attempt;
retrying creates a new result rather than rewriting its history.

No installed Ivy copy, macOS permissions, user data or GitHub release was modified.

## Follow-up verification after installing build 7

The user quoted another missing-app reply. Its exact text and failed `open_app(name: VS Code)`
records were found in saved voice history from 2026-10-07 at 18:56 (Asia/Calcutta), before the
build-7 installation. The running `/Applications/Ivy.app` was verified as build 7 with the same
executable as `dist/Ivy.app`. A separate read-only lookup again found the installed bundle.
An explicit launch probe using the production `SystemWorkspace` resolver and launcher then
opened `/Applications/Visual Studio Code.app` successfully. This verifies native resolution and
launch, not a fresh Gemini voice turn; old failed history remains unchanged. No additional code
change or package rebuild was needed for this follow-up.
