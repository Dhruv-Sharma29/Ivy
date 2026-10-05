# Ivy — Native macOS Personal Assistant

Ivy combines text chat, live voice, screen help and local Mac tools in a native SwiftUI app. It uses Gemini REST and Live APIs, with optional ElevenLabs text-to-speech. Risky tool actions require your explicit approval before execution.

## Current status

The desktop app, saved conversations, live voice, task engine and core Mac tools are implemented. The current local build is **1.1.0 (build 4)**, with an updated app and DMG in `dist/`.

The local package includes the initial Ivy UI refresh: shared rounded cards in Home,
Library, Tasks and Settings, roomier navigation, and a floating quick-chat bar with draft suggestions
and explicit Send/Open/Close controls. The DMG was rebuilt on **2026-10-05** with compact companion
confirmations and push-to-talk missed-release recovery. Quit the running Ivy and replace it with this
updated app before testing the fix; older packages remain in `dist/Previous-Builds/`.
See [the UI refresh report](tasks/ui-refresh.md) for the changes and verification limits.
See [the latest package verification](tasks/ptt-startup-recovery.md) for artifact checks and rollback location.

**Latest update:** the Pointer feature has been removed, including its Settings page, floating
cursor decoration and hover/circle selection. Push-to-talk is voice-only. Enable it in
**Settings → General**, hold **⌘⇧Space** while another app is open, speak, then release.
The toggle now applies immediately; microphone release and approval safeguards remain in place.
Ordinary screenshot/window attachments, Screen Help annotation arrows and the animated companion remain available.
Pointer hover/circle selection is excluded from future work unless requested again.
See [the shortcut/removal report](tasks/pointer-removal.md) for verification limits.

**Push-to-talk startup recovery (build 4):** A Carbon press can arrive before physical keyboard-state
inspection confirms the hold. Ivy now treats an unobserved reading as unknown, rather than ending
voice immediately. Verified release, the release callback and Stop still close capture. A fresh press
works after a recovered release or Stop. Hardware acceptance over another app remains a manual check.
See [startup recovery verification](tasks/ptt-startup-recovery.md).

**Push-to-talk shortcut recovery (build 3):** Settings → General now shows registration errors and a
**Voice shortcut** picker. Keep the default **⌘⇧Space**, or choose **⌃⌥⌘Space** if the default conflicts.
Changes apply immediately. Ivy requests exclusive ownership of the selected PTT shortcut so another
app cannot silently suppress its notifications while registration appears successful. Quit the app
using a conflicting shortcut, choose the alternative, or toggle Push to talk off/on to retry.
This addresses a reproduced registration conflict; physical PTT operation in another app remains
a manual acceptance check. See [shortcut recovery verification](tasks/ptt-shortcut-recovery.md).

**This is a development build, not a notarized public release.** The current DMG contains an **Apple silicon (`arm64`)** app. Its executable targets macOS 14 or newer; an Intel binary is not included. The v1.1 artifact has passed packaging and signature checks, but a reported launch failure on another Apple silicon Mac remains under investigation. Do not treat the minimum deployment target as proof that every supported OS version has been tested.

See [remaining work](tasks/remaining.md) for hardware testing and release requirements, and [CHANGELOG.md](CHANGELOG.md) for the v1.1 additions.

The [next-feature plan](docs/roadmap/phase-20-assistant-workspace.md) covers computer control, screen-aware
dictation, personal/specialist assistants, concurrent jobs, daily suggestions, generated files, routines,
multi-account connectors, spatial guidance and a compact overview. These expanded capabilities are
planned; the roadmap includes their dependencies and acceptance
checks, plus an explicit Ivy design direction for original layouts, leaf branding and copy. Computer-control
components and offline tests exist, but the production task engine has no desktop coordinator configured.
Autonomous clicking, typing, scrolling and dragging are not available in this packaged app.

## Features

- **Native workspace:** resizable main window, Dock presence, outline-leaf menu bar shortcut, Home, Library, Tasks and searchable Settings.
- **Conversation history:** search, pinned conversations, export and an Archived section that expands when opened.
- **Compact composer:** attachments, microphone and send controls. Return sends; Shift–Return inserts a newline at the cursor. Drafts are retained per conversation while the main view remains open.
- **Live voice:** Gemini voice sessions, local “Hey Ivy” interruption and global push-to-talk. Hold **Command–Shift–Space** while speaking, then release; Ivy submits the captured speech and stays connected to answer. Silent presses cancel. Speech queued during microphone or connection startup is preserved.
  Push-to-talk replies use output-only playback, so releasing the shortcut closes the microphone even if Ivy has already started answering or is waiting for approval. If idle “Hey Ivy” listening is enabled, that separate feature continues using the microphone.
  A physical-key check while the shortcut is held also recovers missed release events. Releasing Space
  or a required modifier stops PTT capture; Stop resets the shortcut state for the next request.
- **Tool feedback:** collapsible live tool cards with status, masked arguments and expandable output; diff **Apply…** drafts a file change for review without executing it.
- **Screen help:** attach a screenshot, a region captured with the macOS screenshot picker, an image or a PDF. The picker is separate from the removed hover/circle Pointer feature. The screen-help shortcut can show a capture to an active Live session. Inside the floating Command Bar, **Command–Shift–S** attaches the front window for review and explicit send.
- **Screen annotations:** Ivy can draw a temporary arrow and labelled highlight to show where a button, menu or other area is on the screen you shared.
- **Tasks and Mac tools:** plan multi-step work with `/agent <goal>`, review the plan, approve risky steps and stop a running task. Tools cover files, applications, shell commands, AppleScript and other Mac services; developer tools use the selected workspace.
- **Native presentation:** adaptive glass surfaces, a draggable animated companion, copy/read-aloud feedback and a compact approval sheet. Pending tool actions replace the companion's status pill with the action reason and **Do it / Cancel** controls.
- **Secure credentials:** keys saved through Settings live in macOS Keychain, outside plaintext settings and conversation history. Voice, macros, plans and external links cannot approve risky actions.
- **Conversation links:** `ivy://new` and `ivy://conversation/<UUID>` reveal Chat. Links never send messages or run tools; active requests, approvals, tasks and voice sessions block conversation switching.

## Understanding Ivy's feedback

### Tool cards: see what Ivy is doing

A tool is an action Ivy uses to help you, such as reading a file or opening an app. A tool card appears
in the chat timeline when that action starts. Click its disclosure arrow to expand or collapse the details.

| Card detail | Meaning | Example |
|---|---|---|
| Tool name | The action being used | `file_op` |
| Arguments | Inputs supplied to the action | Read `notes.txt` |
| Status | Whether the action is running, succeeded or failed | Succeeded |
| Output | The result or error returned by the action | File contents, or “file not found” |

Use these cards to check progress, understand a failure and see which action produced a result.
A running card may be waiting for your approval. The small confirmation shows only the action reason and **Cancel / Do it**. Hover over the reason to see the original request. The approval sheet and companion answer the same pending request. Hovering, dragging, opening or hiding the companion never approves an action.
Expanding a card does not approve or rerun anything. Credential fields are masked and long details are
clipped with a truncation notice. Detailed cards last for the current session/conversation; saved history
keeps condensed tool notes rather than the raw arguments and output.

### Annotation arrow: find something on your screen

Share a window using screen help or the attachment controls, then ask **“Find the Export button and
point to it in this shared window.”** Include the capture with that question. When Ivy uses its `point_at`
tool, an arrow points from the screen edge toward a
highlighted area, with a short label. The overlay disappears after about six seconds or when replaced
by another highlight.

This makes screen guidance easier to follow than a written description alone. It uses the last screenshot
you shared; it does not take another capture or click the target. The overlay lets your clicks pass through,
so you can interact with the app yourself. If the window moved since the screenshot, share it again.

Each shared capture has its own image ID and pixel dimensions, so Ivy can select the right image when
several windows are attached. Uploaded files and text-only captures can be discussed but cannot establish
where an arrow belongs on your current desktop. With Reduce Motion enabled, the arrow is stationary.

If screen capture is denied, use **Open Settings** in the capture error to enable Ivy under Screen &
System Audio Recording. Reopen Ivy if macOS asks, then choose **Retry Capture**. Retrying only attaches
the image; review it and send your question explicitly.

## Requirements

| Use | Requirement |
|---|---|
| Current packaged app | Apple silicon Mac; executable deployment target is macOS 14.0+ |
| Build from source | Xcode with a Swift 6 toolchain and macOS SDK; this batch was verified with Swift 6.4 |
| Text chat and Live voice | Gemini API key |
| ElevenLabs Read Aloud | Optional ElevenLabs API key and voice configuration |

The Swift package has no third-party package dependencies. Physical-device and cross-Mac acceptance checks remain listed in the backlog.

## Install the current local build

1. Open `dist/Ivy-1.1.0.dmg`.
2. Drag **Ivy** onto the **Applications** shortcut.
3. Launch Ivy from Applications.
4. Open **Settings → API Keys** with **Command-comma** and save your Gemini key. Add ElevenLabs only if you want its Read Aloud playback.

### “Apple could not verify…”

The current DMG contains an ad-hoc signed testing app and has not been notarized. Signature verification checks integrity; it does not establish that Gatekeeper will accept the download.

If you trust this build and its source, dismiss the warning with **Done**, open **System Settings → Privacy & Security**, and choose **Open Anyway** for the blocked item. Authenticate and confirm **Open**. The app may require its own approval after the DMG opens. Follow [Apple’s opening instructions](https://support.apple.com/en-us/102445).

For the standard verified public download flow, use **Developer ID Application** signing, Apple notarization and a stapled ticket. An Apple Development certificate cannot replace that release process. See [release setup](docs/RELEASE.md).

### “The application Ivy can’t be opened”

This generic Finder message does not identify the cause. Record the affected Mac’s chip and macOS version, then launch the installed executable from Terminal to obtain the actual error:

```bash
/Applications/Ivy.app/Contents/MacOS/Ivy
```

Adjust the path if Ivy is installed elsewhere. Also check the installed copy’s signature:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/Ivy.app
```

Include the error output when reporting a problem. Possible causes include an incompatible OS/runtime, a damaged copy or a signing failure; the reported recipient-Mac issue has not yet been diagnosed. Redact any personal information or credentials before sharing logs.

## Develop locally

From the repository root:

```bash
./scripts/run-ivy-app.sh
```

The script builds a debug app in `.build/Ivy.app`, signs it with an available Apple Development identity (or ad-hoc fallback), and launches it. It replaces any running Ivy process, so finish active work first. Diagnostics go to `~/Library/Logs/Ivy.log`.

Use the signed app bundle for microphone, speech recognition and macOS permission testing. `swift run Ivy` is useful for development, but the project disables speech-recognition interruption under that launch path.

Configure keys in Settings. For development, the launcher also forwards `GEMINI_API_KEY` and `ELEVENLABS_API_KEY` from its shell environment. Do not put real keys in source files, tracked configuration or commands saved in shell history.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| Command–Shift–Space, held (default) | Push-to-talk; release to submit |
| Control–Option–Command–Space, held | Optional PTT alternative selected in General settings |
| Control–Option–Command–S | Screen help |
| Control–Option–Command–K | Command bar |
| Command–Shift–S inside the command bar | Attach the front window for review; does not send it |
| Command–N | New conversation |
| Command–F | Search conversations |
| Command-comma | Settings |
| Return / Shift–Return | Send / insert a newline |
| Command–Return in an approval | Explicitly approve the displayed action |
| Escape in an approval | Cancel |

Global shortcuts can be disabled or configured in Settings. See the [keyboard map](docs/KEYBOARD.md) for additional commands and context.

## Privacy and permissions

Permissions are requested when a feature needs them. Idle wake listening and background features are opt-in. macOS privacy grants are separate from Ivy’s per-action safety approval.

| Permission | Feature |
|---|---|
| Microphone | Live voice and push-to-talk |
| Speech Recognition | Wake phrase and interruption |
| Screen Recording | Screen/window capture |
| Calendar / Reminders | Relevant EventKit tools |
| Contacts | Confirmed contact lookups |
| Automation | AppleScript and tools that control other apps |
| Accessibility | Window movement or resizing |
| Notifications | Notifications and proactive reminders |

Saved conversation history excludes attached image data. Screen privacy indicators and temporary-file handling still have follow-ups in the backlog. See [permissions and entitlements](docs/PERMISSIONS_AND_SANDBOX.md) and [persistence and security](docs/PERSISTENCE_AND_SECURITY.md).

## Build, test and package

```bash
swift build -Xswiftc -strict-concurrency=complete
swift test --enable-code-coverage
swift build -c release -Xswiftc -strict-concurrency=complete
git diff --check
```

Tests use isolated fixtures for network, credentials and audio. Native interface tests render previews in `/private/tmp/ivy-ui-review`; those tests do not establish behavior on a real microphone, AirPods or another Mac.

The 2026-10-05 Pointer-removal and global-shortcut build passed **1,286 core tests and 29 native interface tests** (1,315 total; combined execution 34.449 seconds). Changed executable-line coverage was **100% (28/28)**, not total project coverage. Strict debug and release builds passed without warnings; the warm build took 0.18 seconds. Signature, DMG integrity, checksum and mounted-binary comparison passed. These are existing build results, not fresh hardware verification. Real keyboard/microphone behavior in other apps, Gemini screen pointing, accessibility, performance and broader release acceptance checks remain pending. See [the verification report](tasks/pointer-removal.md).

To package from source:

```bash
./scripts/package-release.sh
```

**The packaging script stages and verifies new artifacts before replacing the app and current-version DMG. Older DMGs are retained for rollback.** It creates `dist/Ivy.app` and `dist/Ivy-<version>.dmg`, selecting Developer ID, Apple Development or ad-hoc signing based on the available identity. Packaging alone does not notarize the app.

After installing a Developer ID Application certificate and configuring a notary credential profile:

```bash
export CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export NOTARY_PROFILE="your-stored-notary-profile"
./scripts/package-release.sh
```

The profile refers to credentials stored in Keychain. The configured pipeline submits to Apple and staples the ticket; verify the resulting release before distributing it. Setup details are in [docs/RELEASE.md](docs/RELEASE.md).

## Project documentation

- [Remaining work](tasks/remaining.md) — current implementation and release backlog.
- [v1.1 roadmap](docs/roadmap/README.md) — module plans and acceptance criteria.
- [SPEC.md](SPEC.md) — behavior and architecture.
- [CONSTRAINTS.md](CONSTRAINTS.md) — quality and safety requirements.
- [Release guide](docs/RELEASE.md) — signing, packaging and notarization.
- [Permissions](docs/PERMISSIONS_AND_SANDBOX.md) — privacy grants and entitlements.
- [Persistence and security](docs/PERSISTENCE_AND_SECURITY.md) — credentials and saved data.
- [Keyboard map](docs/KEYBOARD.md) — shortcut reference.

The original `tasks/plan.md` and `tasks/todo.md` are historical v1 checklists. Use the audited remaining-work tracker for current status.
