# Capability Map: Ivy (macOS Assistant)

The table below is the original v1 module map, not a complete current feature inventory. For current
shipping status use [README](README.md) and [remaining work](tasks/remaining.md).
As of 2026-10-05, the Pointer visual/settings and hover/circle selection modules are removed.
Voice-only push-to-talk, explicit capture attachments, Screen Help annotations and the companion remain.
Computer-control source components are separate and still need production integration.

| Module id | Responsibility | Depends on |
|---|---|---|
| `core-chat` | Menu bar popover UI, Ivy system prompt, Gemini 2.0 Flash REST client & streaming/turn management | — |
| `tool-engine` | Gemini function calling schema declarations, tool dispatch (AppleScript, shell, app launcher, calendar, file ops), functionResponse loop | `core-chat` |
| `safety-gate` | Action risk classification (safe vs destructive) & Ivy in-character modal confirmation gate | `tool-engine` |
| `voice-pipeline` | Push-to-talk hotkey, speech-to-text (`SFSpeechRecognizer`), text-to-speech (`AVSpeechSynthesizer` / ElevenLabs REST) | `core-chat` |
| `persistence-settings` | macOS Keychain API key management, local conversation history JSON store, settings UI | `core-chat` |
| `system-permissions` | Hardened runtime entitlements, Info.plist privacy descriptions, runtime permission auditing & graceful recovery | `safety-gate`, `voice-pipeline` |
| `portfolio-polish` | Dynamic menu bar status icons (idle/listening/thinking/speaking), codesign & notarytool build scripts, README & demo | `core-chat`, `tool-engine`, `safety-gate`, `voice-pipeline`, `persistence-settings`, `system-permissions` |

**Build order:** `core-chat` → `tool-engine` → `safety-gate` → `persistence-settings` → `voice-pipeline` → `system-permissions` → `portfolio-polish`
