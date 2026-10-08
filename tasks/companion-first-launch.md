# Companion-first launch — 2026-10-08

Build 20 makes the on-screen companion Ivy’s default surface. Launching or reopening Ivy shows
the companion and the menu-bar icon without a Dock icon or Command-Tab entry. Opening the
workspace from the menu bar, companion, screen-help capture or recognized deep link remains
explicit. Closing the workspace keeps app-owned voice/chat/approved tasks running. Quit stops
Ivy. First-run onboarding still opens when setup is needed.

## Implementation

- Bundle `LSUIElement` is true and runtime activation is accessory, including launch completion.
- The main controller starts in background mode. Launch/reopen shows the companion and clears
  temporary hiding without approving or restarting tasks.
- Workspace and Settings use suppressed launch and disabled restoration on macOS 15+. A public
  SceneBuilder availability wrapper retains macOS 14 scene support; registration hides its
  automatically created workspace, with a deferred identity/mode guard so explicit opening wins.
- The menu-bar label installs the native workspace open action before a workspace exists.
- Startup keeps proactive suggestions pending instead of opening the workspace.

The macOS 15+ scene API availability was checked in the local SDK. See Apple’s
[scene launch documentation](https://developer.apple.com/documentation/swiftui/scene/defaultlaunchbehavior(_:)).

## Verification

Native regression tests exercise launch state, an automatically created window, companion
visibility, suppression of unsolicited suggestions, explicit workspace reopening, and early
menu-bar route installation. Existing voice/task/approval lifecycle tests remain enabled.

- Full suite: **1,364 tests pass**, with 1,321 core tests in 3.159 seconds and 43 native UI tests
  in 36.459 seconds (39.618 seconds combined). No tests were removed or skipped. The metadata
  and reopen assertions were updated because Dock launch is explicitly replaced by companion launch.
- Changed executable source lines across the working tree: **524/533 covered (98.31%)**. This
  is changed-line coverage, not total project coverage.
- Strict Swift 6 build passes with no compiler diagnostics. Source credential scan and
  `git diff --check` pass.

## Package and installed app

- Release build: 33.90 seconds, zero compiler diagnostics. Final incremental strict build: 2.03 seconds.
- Package credential scan is clean. Packaged, read-only mounted and installed apps contain
  **1.1.0 (20)**, arm64, `LSUIElement=true`, and verified ad-hoc Hardened Runtime signatures.
  DMG integrity, SHA-256 sidecar, Applications link and executable comparisons pass.
- Executable SHA-256: `2cd4e49dc7e0be41998b20b6009996f52a0ea69815372c3ff0312ba3b9e4ad9c`.
- DMG SHA-256: `7387edbcd097346839f85efb0d48ce4fe8d2ed9e62a746bc34f62d847a2c288e`.
- Packaged rollback: `dist/Previous-Builds/Before-Companion-Launch-Build20-2026-10-08-7zwBI4`.
- Installed rollback: `dist/Previous-Builds/Before-Applications-Install-Build20-2026-10-08-3JKVQ6`.
- Installed Ivy was idle and quit normally, then relaunched through native app control. Its first
  visible window contained only the companion (`ivy.companion`), with no workspace. The workspace
  was subsequently observed during concurrent user interaction. Closing it returned to the same
  companion-only state; Ivy was left running that way.
- Dock UI inspection timed out. Dock suppression is verified by bundle metadata and the runtime
  accessory-policy tests; direct visual Dock confirmation and macOS 14 physical launch remain manual.
  No force-quit was used and no running task was interrupted.
- The testing package remains unnotarized. The system’s `hdiutil` deprecation notice did not prevent
  successful image verification.

## Try it

Open Ivy from Applications: the companion appears with the menu-bar leaf, and the workspace stays
closed. Click the companion or choose **Open Ivy** in the menu bar to review chat/tasks/settings.
Close the workspace to keep only the companion. **Quit Ivy** stops it.

