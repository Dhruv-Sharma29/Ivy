# Background companion workspace — 2026-10-08

Current artifacts are build 24; [companion-first launch](companion-first-launch.md) is now the default. The sidebar background icon was removed; File/menu-bar actions and
closing the workspace still support this behavior. See [removal verification](sidebar-background-button-removal.md).
The release measurements below describe the original build 12 delivery.

## Behavior in 1.1.0, build 12

Choose **Work in Background** from **File → Work in Background**,
or Ivy's menu-bar menu. The workspace hides, its draft stays in memory, and Ivy's existing voice,
chat and approved Tasks continue. Closing the workspace with its red close button also leaves Ivy
resident with the companion visible. The action enables **Show the Ivy companion** and **Keep visible
when idle**, and clears a previous **Hide for Now** so the user has a visible status/approval surface.
Those companion preferences remain adjustable in General settings.

Ivy shows the actual Listening/Thinking/Speaking/Working state and task progress in the companion.
The same tool approvals remain accessible through **Do it / Cancel** below the character. Background
mode never approves a task plan or tool. Opening the companion or choosing **Open Ivy** restores the
full workspace for plan review, detailed arguments, history and task results. End Voice Session and
Stop Task remain in the companion context menu. **Quit Ivy** still stops work and releases resources.

A proactive suggestion cannot reopen the workspace while this background mode is active. It remains
available to review when the user explicitly returns. Explicit Open Ivy, companion clicks,
conversation links and screen-attachment review retain their navigation behavior.

This uses the existing resident app and task engine. It does not add execution after Quit, during Mac
sleep, unattended recurring agents, a notch overview or the separately planned floating task panel.
Only the menu-bar icon remains available. Launch now shows the companion without the workspace; no login/startup
preference is changed.

## Implementation

- `MainWindowController` tracks only the native workspace window through a noninteractive SwiftUI
  window reader. It retains SwiftUI's window delegate, observes native close and exposes background
  presentation state. Background hides only that window; Settings/command bar/companion are separate.
- The controller and the application environment own presentation/work for the app lifetime. No close
  or hide callback calls voice Stop, brain Cancel or task Cancel. Explicit Quit retains existing shutdown.
- `CompanionController.showForBackground` enables companion visibility, clears transient Hide for Now
  and refreshes the existing panel. Its approvals remain tied to the original request identity.
- The observed workspace root propagates presentation changes into Chat. In background, its sheet binding
  returns nil so a hidden parent cannot present an approval sheet. Dismissing a pre-hide binding consults
  the live controller and does not deny the request; the companion keeps it pending. Reopening restores
  the detailed sheet if the request remains unanswered. Suggestions are not consumed by the hidden chat.
- Build 19 removes the sidebar background button. File/menu-bar actions continue to use the same
  controller, and closing the workspace retains background behavior.

## Verification

Native lifecycle fixtures verify both hide and close while a PTT hold is recording, preserve the reply
and close input on release, update companion state, and reopen the same workspace. Unrelated windows
remain visible and their close events cannot trigger background mode. A two-step approved task reads
only its own fixture inside the existing permitted home scope, succeeds while hidden and saves both
step outputs and its report. No file safety validation is relaxed. A pending approval is revealed again
when entering background and never answered by display/hide; dismissing an old workspace sheet binding
leaves it pending. Suggestions do not automatically reopen the window.

Fixtures use offline provider/audio/hotkey services; their file work reads only a disposable test fixture.
Physical cross-app shortcuts, microphone/speaker behavior and the native app's final appearance require
manual verification. Broader phase-20 work remains on the roadmap.

### Build 12 release checks

- Full coverage test run: **1,349 passing tests** (1,310 core and 39 native UI tests), with
  no skipped tests. Native UI execution took 36.859 seconds; core execution took 2.849 seconds.
- Changed executable source lines: **190/191 covered (99.48%)**. All 81 executable lines added
  for this background UI behavior were covered. Strict-concurrency build passed without compiler
  warnings or errors; the warm incremental build took 0.17 seconds.
- Release packaging produced **1.1.0 (12)** for Apple silicon. Both the packaged and mounted apps
  passed strict code-signature verification. The signature is ad hoc with Hardened Runtime; this
  testing release is not Apple-notarized.
- The DMG checksum, mounted executable, companion sprite resource and Applications link were
  verified. Executable SHA-256: `bcf46db20cfd0cc94706db2f133c6793306ca73464a2d8a50e407d0725f52081`.
  DMG SHA-256: `2b261f44f8c0e4da928a1d11a9fe817a29f6ad30b9bf77d74a6ffb764b0a0dbd`.
- Build 11 packaged and installed copies were retained in `dist/Previous-Builds`. The installed
  `/Applications/Ivy.app` is now **1.1.0 (12)**; its executable and sprite resource match the package,
  and its strict code-signature verification passed. The Mac was locked during final UI inspection.
  The running build-11 session was left uninterrupted, so relaunch is required to load build 12.
  A physical workspace/companion handoff and microphone check remain pending until the Mac is unlocked.

## Try it

1. Confirm About shows **1.1.0 (15)**.
2. Start a voice request or review and run a Tasks plan.
3. Choose **Work in Background**, or close the workspace with the red button.
4. Work in another app. Ivy's companion should show its current status and real task progress.
5. Use **Do it / Cancel** on a pending tool request. Right-click Ivy for End Voice Session or Stop Task.
6. Click the character or choose **Open Ivy** to inspect the reply, saved task report or full approval.

Closing/hiding the workspace keeps the app resident. Choosing **Quit Ivy** ends that resident session.
