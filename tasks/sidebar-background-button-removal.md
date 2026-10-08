# Sidebar background button removal — 2026-10-08

Build 19 removes the icon above Settings in the navigation rail, including its action, hover hint
and accessibility identifier. Home, Library, Tasks and Settings retain their existing layout.
Background mode remains available through **File → Work in Background**, the Ivy menu-bar menu,
and closing the workspace. Voice, task execution and companion behavior are unchanged.

The removal reuses the existing native sidebar snapshots and background-lifecycle regression
suite; no extra test mirrors this simple view deletion.

## Verification

- Full suite: **1,362 tests pass**, with 1,321 core tests in 2.978 seconds and 41 native UI tests
  in 36.278 seconds (39.256 seconds combined). No tests were removed or skipped.
- Strict Swift 6 build passes without compiler diagnostics; warm build: 0.20 seconds.
- Changed executable source lines across the local working tree: **494/501 covered (98.60%)**.
  This is changed-line coverage, not project-wide coverage. The icon deletion adds no executable lines.
- The native dark sidebar fixture was inspected and shows Settings without the background icon
  above it. The light fixture uses transparent material and is insufficient for appearance QA.
  Existing background lifecycle tests pass; physical installed-app interaction remains manual.
- Source credential scan and `git diff --check` pass.


## Package

- Release build passes with zero compiler diagnostics (30.20 seconds); package credential scan is clean.
- Packaged, read-only mounted and installed apps contain **1.1.0 (19)**, arm64, with verified
  ad-hoc Hardened Runtime signatures. DMG integrity, checksum sidecar, Applications link and
  executable comparisons pass. The testing package remains unnotarized.
- Executable SHA-256: `67bb151f3ac3f2f96e86d046a9bb5012e509e62295b875e10eaac7000e1463c2`.
- DMG SHA-256: `97d52e8d3bc337a0c638471427e9ae8dbb4e40b36ac691c631e032ee5a580a19`.
- Packaged rollback: `dist/Previous-Builds/Before-Sidebar-Removal-Build19-2026-10-08-aM8wla`.
- Installed rollback: `dist/Previous-Builds/Before-Applications-Install-Build19-2026-10-08-VzJ1Tc`.
- The running session was left uninterrupted. Quit and reopen Ivy, confirm About shows build 19,
  then check the sidebar: Settings remains at the bottom without the background icon above it.
