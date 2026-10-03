# Ivy — Native macOS Personal Assistant

Ivy combines text chat, live voice, screen help and local Mac tools in a native SwiftUI app. It uses Gemini REST and Live APIs, with optional ElevenLabs text-to-speech. Risky tool actions require your explicit approval before execution.

## Current status

The desktop app, saved conversations, live voice, task engine and core Mac tools are implemented. The current local build is **1.0.0**, with an updated app and DMG in `dist/`.

**This is a development build, not a notarized public release.** The current DMG contains an **Apple silicon (`arm64`)** app. Its executable targets macOS 14 or newer; an Intel binary is not included. The release launches on the development Mac, but a reported launch failure on another Apple silicon Mac remains under investigation. Do not treat the minimum deployment target as proof that every supported OS version has been tested.

See [remaining work](tasks/remaining.md) for implementation gaps, hardware testing and release requirements.

## Features

- **Native workspace:** resizable main window, Dock presence, outline-leaf menu bar shortcut, Home, Library, Tasks and searchable Settings.
- **Conversation history:** search, pinned conversations, export and an Archived section that expands when opened.
- **Compact composer:** attachments, microphone and send controls. Return sends; Shift–Return inserts a newline at the cursor. Drafts are retained per conversation while the main view remains open.
- **Live voice:** Gemini voice sessions, local “Hey Ivy” interruption and global push-to-talk. Hold **Command–Shift–Space** while speaking, then release; Ivy submits the captured speech and stays connected to answer. Silent presses cancel. Speech queued during microphone or connection startup is preserved.
- **Screen help:** attach a screenshot, selected region, image or PDF. The screen-help shortcut can show a capture to an active Live session.
- **Tasks and Mac tools:** plan multi-step work with `/agent <goal>`, review the plan, approve risky steps and stop a running task. Tools cover files, applications, shell commands, AppleScript and other Mac services; developer tools use the selected workspace.
- **Native presentation:** adaptive glass surfaces, a draggable animated companion, copy/read-aloud feedback and a compact approval sheet.
- **Secure credentials:** keys saved through Settings live in macOS Keychain, outside plaintext settings and conversation history. Voice, macros, plans and external links cannot approve risky actions.
- **Conversation links:** `ivy://new` and `ivy://conversation/<UUID>` reveal Chat. Links never send messages or run tools; active requests, approvals, tasks and voice sessions block conversation switching.

## Requirements

| Use | Requirement |
|---|---|
| Current packaged app | Apple silicon Mac; executable deployment target is macOS 14.0+ |
| Build from source | Xcode with a Swift 6 toolchain and macOS SDK; this batch was verified with Swift 6.4 |
| Text chat and Live voice | Gemini API key |
| ElevenLabs Read Aloud | Optional ElevenLabs API key and voice configuration |

The Swift package has no third-party package dependencies. Physical-device and cross-Mac acceptance checks remain listed in the backlog.

## Install the current local build

1. Open `dist/Ivy-1.0.0.dmg`.
2. Drag **Ivy** onto the **Applications** shortcut.
3. Launch Ivy from Applications.
4. Open **Settings → API Keys** with **Command-comma** and save your Gemini key. Add ElevenLabs only if you want its Read Aloud playback.

### “Apple could not verify…”

The current DMG is Apple Development-signed and has not been notarized. Signature verification checks integrity; it does not establish that Gatekeeper will accept the download.

If you trust this build and its source, dismiss the warning with **Done**, open **System Settings → Privacy & Security**, and choose **Open Anyway** for the blocked item. Authenticate and confirm **Open**. The app may require its own approval after the DMG opens. Follow [Apple’s opening instructions](https://support.apple.com/en-us/102445).

Normal public distribution requires **Developer ID Application** signing, Apple notarization and a stapled ticket. An Apple Development certificate cannot replace that release process. See [release setup](docs/RELEASE.md).

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
| Command–Shift–Space, held | Push-to-talk; release to submit |
| Control–Option–Command–S | Screen help |
| Control–Option–Command–K | Command bar |
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

The audited 2026-10-03 integration batch passed **1,159 core tests and 18 native interface tests**. Changed executable lines in that workspace were **98.7% covered**, which is a changed-line measure, not total project coverage. Hardware, accessibility, performance and release acceptance checks remain outstanding.

To package from source:

```bash
./scripts/package-release.sh
```

**The packaging script replaces the entire `dist/` directory.** Preserve any artifacts you need before running it. It creates `dist/Ivy.app` and `dist/Ivy-<version>.dmg`, selecting Developer ID, Apple Development or ad-hoc signing based on the available identity. Packaging alone does not notarize the app.

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
