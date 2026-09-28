# Persistence & Security (Phase 5)

## Credentials (Keychain)

```
IvyBrain / VoicePlaybackManager / GeminiLiveVoiceCoordinator
        ↓  CredentialProvider            (Security/CredentialProvider.swift)
KeychainCredentialProvider  ──fallback──▶ process environment (migration only)
        ↓  KeychainStore                 (Security/KeychainStore.swift)
SystemKeychainStore → Security.framework → login Keychain
```

- Items are `kSecClassGenericPassword`, service `com.ivy.assistant.credentials`, one account per `CredentialKey`
  (`gemini-api-key`, `elevenlabs-api-key`), stored as UTF-8 `Data`, `kSecAttrAccessibleWhenUnlocked`.
- All identifiers live on `CredentialKey`; nothing else names a service, account, or environment variable.
- `KeychainError` (`itemNotFound`, `duplicateItem`, `accessDenied`, `invalidData`, `unexpectedStatus`) never
  carries or prints a secret.
- Clients never hold keys as observable/UI state. The brain publishes only `geminiCredentialSource`
  (`keychain` / `environment` / `missing`); Live re-reads the key at every session start; ElevenLabs resolves it
  per request.

### Migration

Lookup order is Keychain → `GEMINI_API_KEY` / `ELEVENLABS_API_KEY`. Environment values are **never** copied into
the Keychain automatically; the user saves a key explicitly in Settings (gear → paste → Save). Existing
`export …` / `scripts/run-ivy-app.sh` workflows keep working. Remove a Keychain copy with **Remove** (the
environment fallback, if set, then applies again).

Signing note: Keychain item access is tied to the app's code signature. `scripts/run-ivy-app.sh` signs with an
Apple Development identity when one exists, so grants survive rebuilds; ad-hoc or unsigned (`swift run`) builds
may trigger a Keychain access prompt after each rebuild.

## Settings

`IvySettings` (Persistence/SettingsStore.swift) — non-secret preferences only, stored as one JSON blob in
UserDefaults under `ivy.settings.v1`:

| Setting | Default | Applies |
|---|---|---|
| `persistConversationHistory` | on | immediately |
| `restoreLastConversation` | on | next launch |
| `showLiveTranscript` | on | immediately |
| `echoCancellation` | on | next launch |
| `pushToTalkEnabled` | on | next launch |

Corrupt bytes or a wrong type fall back to defaults; a missing or invalid single field falls back to its own
default while valid fields are kept. `SettingsModel` (MainActor, observable) saves on every change.

## Conversation history

`ConversationStore` (Persistence/ConversationStore.swift) with `FileConversationStore`: one JSON file per
conversation in `~/Library/Application Support/Ivy/Conversations/` (directory `0700`, files `0600`, atomic writes).

- In memory: `IvyBrain.messages` (active conversation, `conversationID` is its boundary).
- On disk: `Conversation` → `[StoredMessage]` with id, role, text, timestamp, isError.
- Persisted: user and model text only. **Not** persisted: tool-call turns, tool arguments and results,
  thought signatures, audio, credentials. Text passes through `SecretRedactor` first.
- Saved after every turn (success or error), so an abrupt quit loses nothing. Clear (trash) deletes the saved
  copy and starts a new conversation. Unreadable files are skipped, never fatal.

## Startup & shutdown

`IvyAppEnvironment` (Persistence/IvyAppEnvironment.swift) builds the graph in a fixed order:
settings → credentials → conversation restore → voice → Live (idle) → push-to-talk hotkey.
Launch never starts the microphone, Gemini Live, speech or a tool.

Quit (`IvyAppDelegate.applicationShouldTerminate` → `environment.shutdown()`): a pending approval is denied
(never executed), history is saved, TTS stops, Live is torn down (mic tap, socket, audio queue, PTT state) and
the hotkey is unregistered. Nothing about a Live session is persisted, so no stale session survives a restart.

## Security boundaries

- Secrets: Keychain only (plus read-only environment fallback). Never in UserDefaults, files, logs, source,
  SwiftUI state or history.
- Logs: kinds, counts, sizes, ids and state names only. `IVY_DEBUG_WIRE` payload dumps exist only in DEBUG
  builds and go to stderr only.
- Tools, SafetyGate, filesystem/shell/AppleScript/calendar validation and Live session-token protection are
  unchanged from Phases 2–4E.

## Testing

`Tests/IvyTests/Phase5PersistenceSecurityTests.swift` with fakes in `Tests/IvyTests/Fakes/Phase5Fakes.swift`
(`InMemoryKeychainStore`, `InMemorySettingsStore`, `InMemoryConversationStore`, `RecordingGeminiClient`).
Tests never touch the real Keychain; settings use a throwaway `UserDefaults` suite and files a temp directory.
The audit suite scans `Sources/` for hard-coded keys and for log statements that interpolate secrets,
transcripts, payloads or tool results.
