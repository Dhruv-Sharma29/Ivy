# Phase 8 — Production Hardening

## Goal
Nothing Ivy does should fail silently, leak resources, or need a relaunch to recover. Every failure the
user can hit gets a clear message, an automatic recovery where one is safe, and a manual recovery path
where it isn't. This is stability work: no new features.

## Baseline (what exists, and the gaps found so far)

| Area | Today | Gap |
|---|---|---|
| Live WebSocket | `GeminiLiveClient` detects drops; coordinator tears down to `.error` (Phase 4D/4E). Setup-ack watchdog (15 s). | No reconnect. A dropped socket ends the session; the user must restart Live. No handling of server `goAway` / session-resumption. |
| Gemini REST quota | `dailyQuotaExhausted` fails fast; per-minute 429/5xx retried with backoff (`RetryPolicy`). | No reset-time display, no pre-emptive back-off across requests, no Live quota handling, no model fallback option. |
| Audio devices | Capture engine restarts on `AVAudioEngineConfigurationChange`. Echo cancellation via voice processing. | Device unplugged mid-session, default-device switch, AirPods route change, playback engine config change: untested; the player engine isn't restarted. |
| Permissions | `PermissionManager` reports state; errors are recoverable. | No re-check when the app becomes active (user just granted in System Settings); no deep links per permission. |
| Keychain / storage | Keychain read errors fall back to env; corrupt settings → defaults; corrupt conversation files skipped. | Corrupt files are silently skipped forever (not quarantined); disk-full / write failures only logged; no Keychain "access denied" recovery UI. |
| Resources | Teardown serialised (Phase 5 race fix). Wake listener releases the mic. | No leak audit (tasks, engines, observers, sockets) over long sessions; no memory ceiling check (CONSTRAINTS: < 100 MB). |
| Performance / battery | — | Not measured. Idle wake-word listening, audio engines kept running, popover render cost unknown. |
| Accessibility | Basic SwiftUI defaults. | VoiceOver labels, keyboard navigation, reduced motion, contrast not audited. |
| Tests | 861 passing. | 260 fixed `Task.sleep` waits → flaky under load. One `scheduleBuffer` advisory warning. |
| Tooling | `scripts/run-ivy-app.sh` passes keys to `open --env KEY=value` (visible in `ps` briefly). | Should rely on Keychain; env fallback only for dev. |

## Scope
**In:** reconnect, quota UX, audio-device recovery, permission recovery, storage/Keychain recovery,
resource audit and fixes, performance + battery budgets, accessibility pass, test-suite determinism,
diagnostics bundle. **Out:** new features, UI redesign (Phase 17), new tools.

## Design

### 8.1 Live reconnect & session resumption
```text
socket drop / goAway
      │
      ▼
coordinator.state = .reconnecting(attempt n)   ← new state (UI: "Reconnecting…")
      │   stop mic → keep conversation token → drop partial model turn
      ▼
backoff: 0.5s, 1s, 2s, 4s (max 4 attempts, jitter)  ── fail ──► .error("Lost connection. Tap to retry.")
      │
      ▼ success
send setup (+ sessionResumption handle if the server gave one) → resume mic → .listening
```
- New `VoiceSessionState.reconnecting(Int)`; `isLive == true`, mic not streaming.
- Reconnect only for transport failures (`URLError` network codes, close code 1006/1011, `goAway`), never
  for auth (401/403), quota, or user stop.
- Pending tool confirmation during a drop: deny it (SafetyGate), send nothing; after reconnect the
  model is told the action was not performed.
- `NWPathMonitor` gates retries: if offline, wait for the path instead of burning attempts.
- Session-resumption handles are memory-only and bound to the current session token.

### 8.2 Quota & rate limits
- Parse `RetryInfo.retryDelay` and quota IDs from 429 bodies into `QuotaStatus { kind: perMinute|perDay,
  retryAfter: Date? }` exposed by `IvyBrain` and shown as a banner with a countdown ("Try again in 42 s" /
  "Daily limit reached — resets at 12:30 PM").
- Client-side token bucket per model: after a per-minute 429, delay the next request instead of failing.
- Live: map quota/`RESOURCE_EXHAUSTED` close reasons to the same banner.
- Optional setting "Fall back to a lighter model when the daily quota is used up" (off by default; the model
  list is a constant, never user-typed).

### 8.3 Audio-device recovery
- `AudioRouteMonitor` (CoreAudio `kAudioHardwarePropertyDefaultInputDevice/OutputDevice` listeners +
  engine configuration-change notifications) publishes route changes.
- Capture and player share one engine: on change → stop tap → rebuild converter for the new format →
  reinstall tap → restart engine; the player reschedules nothing (the interrupted buffer is dropped).
- Device removed with no replacement → `.error("Microphone disconnected")`, clean teardown.
- Same for the idle wake listener (restart on route change).

### 8.4 Permission recovery
- `PermissionManager.refresh()` on `NSApplication.didBecomeActiveNotification`; UI rows update live.
- Per-permission "Open Settings" deep links (`x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`, etc.).
- A feature blocked by a denied permission shows one inline card, never repeated prompts.

### 8.5 Storage & Keychain recovery
- Corrupt conversation/settings files are **quarantined** (moved to `…/Ivy/Quarantine/<date>/`) and
  reported once ("1 conversation couldn't be read and was set aside"), never deleted.
- Atomic writes already used; add a free-space check and a surfaced error when a save fails
  ("History couldn't be saved — disk full").
- Keychain `accessDenied` / `interactionNotAllowed` → credential row shows "Keychain access denied — re-enter
  key"; saving re-creates the item.
- Schema versioning for settings/conversations (`schemaVersion` field + migrations) so Phase 9 can evolve
  the format safely.

### 8.6 Resource & leak audit
- Instruments (Leaks, Allocations) scripted runs: 30 Live sessions, 100 chat turns, 50 wake cycles.
- Invariants asserted in tests: after `stopSession` all tasks are nil, the tap is removed, engines stopped,
  no NotificationCenter observers leak (count via injected center), sockets closed.
- `deinit` logging in DEBUG for coordinator, listener, engines.

### 8.7 Performance & battery budgets
| Metric | Budget |
|---|---|
| Idle CPU (no wake word) | < 0.5 % |
| Idle CPU (wake word on) | < 3 % (measure; if above, add energy-gated recognition: only feed the recognizer when input level crosses a threshold) |
| Memory | < 100 MB steady state after 1 h of use |
| Popover open → first frame | < 50 ms |
| Message list with 1,000 messages | scrolls at 60 fps |
| Live first audio after end of speech | ≤ 2 s p50 (already logged by `[LIVE METRICS]`) |
- Audio engines stopped when idle (none left running after a session). App Nap left enabled when idle.

### 8.8 Accessibility
- Every control labelled for VoiceOver (mic, send, gear, trash, confirmation buttons, credential rows).
- Full keyboard path: ⌘N new chat, ⌘, settings, Return send, Esc cancel, Tab order through confirmation cards.
- Respect Reduce Motion (Phase 4E symbol effects), Increase Contrast, Dynamic Type sizes in the popover.
- Confirmation cards announced with `.accessibilityAddTraits(.isModal)`.

### 8.9 Crash & error recovery
- MetricKit (`MXMetricManager`) diagnostic payloads stored locally (no third-party service, no upload).
- "Export diagnostics" button: a zip of redacted logs (`SecretRedactor`), version, settings (non-secret),
  permission states — no conversations, no keys.
- Top-level guard: a failed subsystem (voice, tools, history) degrades that feature, never the app.

### 8.10 Test determinism
- Replace fixed sleeps with a shared `waitUntil(timeout:condition:)` helper (Tests/IvyTests/Support/).
- Inject a `Clock` into coordinator timers (setup watchdog, wake silence timeout, backoff) so timeout tests
  run instantly.
- Fix the `scheduleBuffer` advisory with the completion-callback-type overload so the build is warning-free.

## Work breakdown

| Slice | Deliverable | Acceptance |
|---|---|---|
| 8.1 | Reconnect state machine + backoff + path monitor | Drop mid-listening → reconnects ≤ 4 attempts; auth/quota errors never retry; tool confirmation denied on drop |
| 8.2 | QuotaStatus + banner + token bucket | 429 per-minute delays next call; per-day shows reset time; no retries on per-day |
| 8.3 | AudioRouteMonitor + engine rebuild | Unplug/replug headset mid-session: session continues or errors cleanly; no crash, no silent mic |
| 8.4 | Permission refresh + deep links | Granting mic in Settings then returning updates UI without relaunch |
| 8.5 | Quarantine + schema versioning + save-failure surfacing | Corrupt file moved to Quarantine and reported once; v1.0 files migrate |
| 8.6 | Leak invariants + Instruments runs | 30 sessions: no growth in tasks/engines/observers |
| 8.7 | Budgets measured + fixes | Table above met on an M-series MacBook Air |
| 8.8 | Accessibility pass | VoiceOver can complete a chat + confirmation end to end |
| 8.9 | MetricKit + diagnostics export | Export contains no secrets (scanned by test) |
| 8.10 | Test helpers, clock injection, zero warnings | 0 fixed sleeps in new tests; full suite 5× green; 0 warnings |

## Safety & privacy
- Reconnect never replays user audio or re-executes a tool.
- Diagnostics export passes `SecretRedactor` and a test asserting no key patterns.
- Quarantined files keep their original permissions (0600).

## Testing
- Fake transport that drops on demand / sends `goAway`; fake path monitor; fake route monitor.
- Clock-injected backoff and timeouts.
- Property test: random interleavings of start/stop/drop/route-change never leave a live tap or task.

## Risks
| Risk | Mitigation |
|---|---|
| Reconnect loops burn quota | Max attempts, jitter, path gating, never retry quota/auth |
| Voice processing breaks on some devices after route change | Fallback: disable echo cancellation for that session and show a hint |
| Instruments work is manual | Codify invariants as tests; keep Instruments as a release checklist step |

## Exit criteria
All slices' acceptance met; full suite deterministic (5 consecutive green runs); zero warnings; budgets met;
manual checklist passed.

## Manual checklist
- [ ] Turn Wi-Fi off mid-conversation → "Reconnecting…" → on → conversation continues.
- [ ] Exhaust the daily quota → banner with reset time; per-minute limit → auto-delay.
- [ ] Switch from speakers to AirPods mid-session; unplug a USB mic mid-session.
- [ ] Deny mic, then grant it in System Settings → Ivy updates without relaunch.
- [ ] Corrupt a conversation file → reported once, file in Quarantine.
- [ ] 1 hour of mixed use: memory < 100 MB, no audio engine running while idle.
- [ ] VoiceOver: send a message, approve a confirmation, start/stop Live.

---

## Implementation status (2026-09-30)

| Slice | Status | What shipped |
|---|---|---|
| 8.1 Reconnect | Done | `VoiceSessionState.reconnecting(n)`; backoff 0.5 s × 2ⁿ, 4 attempts in the app (0 for injected sessions); `NetworkPathChecking` waits for the network; auth/quota/policy errors never retry (`LiveError.isRecoverable`); a pending confirmation is denied on drop; connection-epoch guard ignores failures from the dead socket. Not done: server `goAway` / session-resumption handles. |
| 8.2 Quota | Done | `QuotaStatus` (per-minute / per-day, reset time); server `retryDelay` honoured when ≤ 10 s, surfaced as a countdown otherwise; the brain stops sending requests that cannot succeed; live banner. Not done: optional model fallback. |
| 8.3 Audio devices | Done (needs a hardware pass) | Capture and the idle wake listener rebuild their tap/converter for the new device on every `AVAudioEngineConfigurationChange`; no input device → the session ends with "The microphone was disconnected." Verified in the app for the voice-processing reconfiguration; plug/unplug not yet tried by hand. |
| 8.4 Permissions | Done | Per-permission deep links (`PermissionType.settingsURL`), "Open Settings" on denied rows, statuses refresh when the app becomes active. |
| 8.5 Storage / Keychain | Done | Corrupt conversation files move to `Application Support/Ivy/Quarantine/<date>/` and are reported once; `schemaVersion` on conversations (newer files are skipped, not quarantined); failed saves surface in the UI; `CredentialSource.keychainInaccessible` and item repair on re-save. |
| 8.6 Resources | Done (tests) | `activeTaskCount` invariant over 30 sessions, abnormal ends, and a retain-cycle test. Instruments Leaks runs still to do by hand. |
| 8.7 Performance | Measured, partly met | See table below. |
| 8.8 Accessibility | Partly done | VoiceOver labels on icon buttons, Reduce Motion honoured, ⌘, toggles settings, confirmation approval moved from Return to **⌘Return** (a stray Return can no longer approve a risky action). A full VoiceOver walkthrough is still a manual item. |
| 8.9 Diagnostics | Done | `DiagnosticsReport` (versions, settings, permission states, credential *sources*, redacted log tail), MetricKit crash payloads kept locally (last 5). The "Export Diagnostics…" button was not actually wired up until Phase 17c (Settings › Privacy & Data). |
| 8.10 Tests / warnings | Partly done | Zero compiler warnings; shared `waitUntil` helper (`Tests/IvyTests/Support/`); all new tests poll. The ~260 older fixed sleeps are not yet converted; timer durations are injectable but there is no virtual clock. |

### Measured on a MacBook Air (Ivy.app, debug build)

| Metric | Budget | Measured | Verdict |
|---|---|---|---|
| Idle CPU (wake word off) | < 0.5 % | 0.0 % | met |
| Idle memory before any voice session | < 100 MB | ~80 MB | met |
| Memory after a Live session (echo cancellation on) | < 100 MB | ~175 MB, flat across 5 sessions | **not met** — Apple's voice-processing models stay mapped; no growth, so not a leak |
| CPU during Live (listening, echo cancellation on) | — | 24–34 % of one core | cost of voice processing (libBNNS/vDSP in the profile), not Ivy code |
| CPU after a session ends | ~0 % | 0.0 % | met (audio engine released) |
| Idle CPU with wake word on, popover open time, 1,000-message scroll | see 8.7 | not measured | open |

Turning "Echo cancellation" off in settings avoids both the CPU and the memory cost (headphones recommended).
