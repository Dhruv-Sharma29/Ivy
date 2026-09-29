# Ivy — Native macOS Pair-Programming & Voice Assistant

Ivy is a native macOS menu bar pair-programming assistant powered by the Gemini Multimodal Live API, Gemini REST API, and ElevenLabs text-to-speech. Ivy features real-time bidirectional voice streaming, barge-in wake phrase interruption ("Hey Ivy"), global push-to-talk chords (`Command + Shift + Space`), and secure tool execution through the `InteractiveSafetyGate`.

---

## Features

- **Menu Bar Assistant**: Unobtrusive macOS status item interface with persistent chat history.
- **Multimodal Live Voice**: Ultra-low-latency real-time voice conversations via Gemini Live WebSocket API (`models/gemini-3.1-flash-live-preview`).
- **Hey Ivy Interruption**: Local on-device speech recognition to interrupt AI speech mid-turn.
- **Global Push-to-Talk**: Zero-configuration system hotkey (`Command + Shift + Space`) powered by Carbon Events.
- **Interactive SafetyGate**: Human-in-the-loop approval card for all risky tool executions (`run_shell`, `file_op` writes, `run_applescript`, and `calendar_event`).
- **Keychain Security**: All API keys stored in macOS Keychain (`kSecClassGenericPassword`, service `com.ivy.assistant`). Zero credentials in source code or plaintext settings.
- **Hardened Runtime**: Signed with minimal entitlements and ready for Apple Notarization.

---

## Requirements

- **Operating System**: macOS 14.0 (Sonoma) or later (Apple Silicon & Intel)
- **Toolchain**: Swift 6.0+ / Xcode 16.0+ Command Line Tools
- **API Keys**:
  - Google Gemini API Key (Required for text and Live voice)
  - ElevenLabs API Key (Optional, for high-fidelity TTS playback)

---

## Getting Started

### 1. Development Build & Launch

Run Ivy as a signed local application bundle:

```bash
./scripts/run-ivy-app.sh
```

This compiles Ivy in debug mode, constructs `.build/Ivy.app`, signs it with Hardened Runtime, and launches it into your menu bar.

### 2. Configuring API Keys

1. Click the **Ivy** menu bar icon (`sparkle` symbol).
2. Click the **Gear** icon in the upper-right corner to open Settings.
3. Paste your Gemini API key and ElevenLabs API key.
4. Click **Save** next to each field. The key is written directly to the macOS Keychain and cleared from view memory.

Alternatively, export them in your development shell before running `scripts/run-ivy-app.sh`:
```bash
export GEMINI_API_KEY="your-gemini-key"
export ELEVENLABS_API_KEY="your-elevenlabs-key"
./scripts/run-ivy-app.sh
```

---

## Production Release & Packaging

To create a release-ready, codesigned application bundle and distributable DMG:

```bash
./scripts/package-release.sh
```

This produces:
- `dist/Ivy.app` (Hardened Runtime, Developer ID / Development signed)
- `dist/Ivy-1.0.0.dmg` (Mounted disk image with `/Applications` link)

### Notarization

To submit to Apple Notary Service and staple the ticket:

```bash
export NOTARY_PROFILE="your-stored-notary-profile"
./scripts/package-release.sh
```

For complete release signing and notarization setup, see [docs/RELEASE.md](docs/RELEASE.md).

---

## Permissions & Entitlements

Ivy requires the following macOS privacy permissions, requested strictly on-demand:

| Permission | Trigger Condition | Usage Description |
|---|---|---|
| **Microphone** | First Gemini Live voice session or PTT activation | Voice conversations with Ivy |
| **Speech Recognition** | Voice session connection | "Hey Ivy" wake phrase detection |
| **Calendar** | User-confirmed `calendar_event` tool call | Scheduling calendar events on your behalf |
| **Automation** | User-confirmed `run_applescript` tool call | Automating macOS applications |

For details on the Hardened Runtime vs. App Sandbox architecture, see [docs/PERMISSIONS_AND_SANDBOX.md](docs/PERMISSIONS_AND_SANDBOX.md).

---

## Testing & Quality Verification

Ivy maintains 100% Swift 6 strict concurrency compliance and rigorous test coverage:

```bash
# Run the complete test suite (830+ tests):
swift test

# Verify Swift 6 strict concurrency:
swift build -Xswiftc -strict-concurrency=complete

# Verify formatting and git diff:
git diff --check
```

---

## Architecture Documentation

- [`SPEC.md`](SPEC.md) — Comprehensive technical specification
- [`CONSTRAINTS.md`](CONSTRAINTS.md) — Quality bar, safety floors, and enforced metrics
- [`docs/RELEASE.md`](docs/RELEASE.md) — Production release, signing, and notarization guide
- [`docs/PERMISSIONS_AND_SANDBOX.md`](docs/PERMISSIONS_AND_SANDBOX.md) — macOS permissions and entitlements architecture
- [`docs/PERSISTENCE_AND_SECURITY.md`](docs/PERSISTENCE_AND_SECURITY.md) — Keychain, settings, and conversation storage
