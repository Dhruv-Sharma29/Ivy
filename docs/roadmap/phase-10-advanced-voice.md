# Phase 10 — Advanced Voice Experience

> **PTT release recovery — 2026-10-04:** A press-bound 50-ms physical key/modifier check recovers a
> missing Carbon/flagsChanged key-up. It ends only the PTT hold, preserves replies and approvals, and
> stops on release/explicit Stop. Connection failures retain only this hold check until release, blocking
> repeat-driven reconnections. Stop resets the hold so a later press can start normally. Offline regression
> fixtures cover held/released state, connection buffering, early replies, approval, shortcut removal
> and polling failures; real keyboard/TCC behavior still requires the manual release check.

## Goal
Talking to Ivy should feel like talking to a person: it notices when you've finished, stops the instant you
cut in, hears "Hey Ivy" reliably, shows that it's listening, and survives device switches and sleep — while
Kore stays the voice.

## Baseline
- Live: `GeminiLiveVoiceCoordinator` state machine (IDLE → CONNECTING → LISTENING → THINKING →
  TOOL_CONFIRMATION → TOOL_EXECUTION → SPEAKING → INTERRUPTING), server VAD decides end of turn, mic audio
  is only sent while LISTENING.
- Barge-in: while SPEAKING, mic audio goes to `SystemWakeWordDetector` (server-based SFSpeech, partial
  results) → `WakePhraseMatcher` (hey/ivy variants, fragment stitching) → stop playback, discard the
  interrupted turn.
- Echo cancellation: shared `AVAudioEngine` with voice processing; it **suppresses the user's voice** while
  Ivy speaks (recognizer input peaks ~20–80 vs ~10,000), clipping the first word.
- Idle wake: `SystemWakeWordListener` (on-device) → `WakeWordController` → one-turn wake session.
  Words said in the same breath as "Hey Ivy" are lost (Live starts after the chime).
- Latency metrics logged (`[LIVE METRICS]`); first audio ≈ 1.5–2 s after end of speech.
- ElevenLabs TTS has no voice settings UI; text-chat TTS cannot be interrupted by voice.

## Scope
**In:** turn-taking tuning, client VAD, faster/more reliable barge-in and wake word, wake pre-roll,
audio level indicators + state animations, voice settings (TTS speed/stability, response length/pace),
device selection and switching, background session recovery (sleep/wake, network), local voice commands.
**Out:** changing the Live voice (Kore locked), custom wake-word training, new third-party audio libraries.

## Design

### 10.1 Turn-taking
- Configure Live `realtimeInputConfig.automaticActivityDetection` (start/end sensitivity, `prefixPaddingMs`,
  `silenceDurationMs`) with tuned defaults and a hidden "patience" setting (short / normal / long pause).
- Client-side energy VAD (RMS over 20 ms frames, adaptive noise floor) drives UI ("hearing you…") and the
  wake-session silence timeout — replaces the fixed amplitude gate in `containsVoice`.
- Optional explicit activity signals (`activityStart/End`) in PTT mode: key-down/up are exact turn boundaries.

### 10.2 Faster, more reliable barge-in
- Switch the in-session detector to **on-device recognition** (`requiresOnDeviceRecognition` when
  supported): lower latency, no network, privacy.
- **Keyword-spotting fast path:** a lightweight check on each partial for an Ivy-variant token *immediately
  after* a hey-variant — already in matcher; add a "lone Ivy while Ivy is speaking + user energy spike"
  heuristic behind a setting, measured for false positives before enabling.
- **Double-talk tuning:** measure whether disabling voice-processing AGC or using
  `voiceProcessingOtherAudioDuckingConfiguration` improves near-end level; A/B with recorded fixtures.
- Target: barge-in (end of "Ivy") → playback stopped ≤ 300 ms p50.

### 10.3 Wake word reliability & pre-roll
- Ring buffer (3 s, 16 kHz) in the idle listener. On wake, forward audio **after** the wake phrase to the new
  Live session once connected, so "Hey Ivy, what time is it?" works in one breath.
- Connection warm-up: open the Live socket in parallel with the chime.
- False-trigger telemetry (local only): count wakes that timed out with no request; surface in diagnostics.
- Energy gate: feed the on-device recognizer only when input energy exceeds the noise floor (CPU/battery).

### 10.4 Voice activity indicators & animations
- `AudioLevelMeter` publishes input and output RMS at 30 Hz (throttled on the main actor).
- UI: listening waveform/orb that reacts to the user's voice; speaking orb that reacts to Ivy's output;
  distinct thinking and tool states; Reduce Motion → static indicators. (Visual design owned by Phase 17.)

### 10.5 Voice settings
- ElevenLabs: speed (0.7–1.2), stability, style — sent as `voice_settings`; preview button.
- Live (Kore locked): "response length" (brief / normal / detailed) and "speaking pace" hints added to the
  Live system instruction; no voice change.
- Voice input device picker (CoreAudio device list, "System default" default); output follows system.

### 10.6 Audio-device switching (extends Phase 8.3)
- Mid-session switch keeps the session: rebuild tap + converter, reset voice processing, continue.
- Bluetooth HFP quirk: when AirPods switch to HFP (mic in use), output quality drops — document; prefer the
  built-in mic when "Use AirPods mic" is off.

### 10.7 Background session recovery
- `NSWorkspace.willSleepNotification` → end Live cleanly (deny pending confirmation), stop wake listener.
- `didWakeNotification` → restart the wake listener if enabled; do not auto-restart a Live session.
- Screen lock → pause wake listening (setting, default on).
- Network changes handled by Phase 8.1 reconnect.

### 10.8 Local voice commands
Recognised on-device before anything reaches Gemini, only in the relevant states:

| Phrase | State | Action |
|---|---|---|
| "Hey Ivy, stop" / "stop" (while speaking, after barge-in) | SPEAKING | stop playback, stay listening |
| "Hey Ivy, cancel" | THINKING/TOOL_* | cancel the turn; pending confirmation **denied** |
| "Hey Ivy, end" / "goodbye" | any Live | end session |
| "Hey Ivy, mute" / "unmute" | LISTENING | pause/resume mic streaming |
| "Hey Ivy, repeat that" | LISTENING | replay last model audio (kept in memory for the session only) |

Voice commands can never approve, and "yes/confirm/do it" is never a command.

## Work breakdown
| Slice | Deliverable | Acceptance |
|---|---|---|
| 10.1 | Activity-detection config + client VAD | Fewer premature cut-offs on 20 recorded utterances with pauses; PTT boundaries exact |
| 10.2 | On-device barge-in + tuning | ≤ 300 ms p50 barge-in on fixtures; false-positive rate measured and documented |
| 10.3 | Pre-roll + warm-up + energy gate | One-breath "Hey Ivy, <request>" answered; idle CPU with wake word < 3 % |
| 10.4 | AudioLevelMeter + indicators | Levels update at ≥ 20 Hz without main-thread hitches |
| 10.5 | Voice settings | TTS speed/stability persisted and applied; Kore unchanged (test) |
| 10.6 | Device picker + mid-session switching | Switching input device mid-session keeps the session |
| 10.7 | Sleep/wake/lock handling | Sleep during Live: clean end; wake: listener restarts |
| 10.8 | Local voice commands | Each command works in its state; none can approve a tool (tests) |

## Safety & privacy
- Pre-roll buffer is memory-only, overwritten continuously, cleared on stop.
- "Repeat that" audio is memory-only for the current session.
- Local commands are an allow-list; SafetyGate untouched.

## Testing
- Recorded PCM fixtures (with consent: generated with `say` + mixed noise/echo) replayed through the capture
  pipeline via a fake audio source; deterministic matcher + VAD tests.
- Fake recognizer emitting scripted partials with timestamps for latency tests.
- Clock-injected timers (Phase 8.10).

## Risks
| Risk | Mitigation |
|---|---|
| On-device recognition less accurate | Keep server fallback in-session only if on-device unavailable (setting); measure |
| Lone-"Ivy" heuristic false triggers | Off by default; only enabled if fixture false-positive rate < 1 % |
| Voice-processing behaviour varies by Mac | Per-device fallback: disable echo cancellation and suggest headphones |

## Exit criteria
Latency targets met on fixtures and on-device; all slices accepted; manual checklist passed.

## Manual checklist
- [ ] From another app, hold Command–Shift–Space, speak and release Space first; repeat releasing a
  modifier first. PTT capture closes, the companion changes from Listening to Thinking/Speaking, and
  Ivy finishes its reply. Repeat with silence, during an early reply and while approval is pending.
- [ ] Stop a held PTT session, then release and press again; no stuck Listening or blocked next request.
- [ ] Pause mid-sentence for ~1 s — Ivy waits; finish — Ivy answers.
- [ ] "Hey Ivy" mid-answer on speakers and on headphones — stops within a beat.
- [ ] "Hey Ivy, what's the weather like?" in one breath from idle — answered.
- [ ] Change TTS speed; Kore still the Live voice.
- [ ] Switch AirPods ↔ built-in mid-session.
- [ ] Close the lid during Live; reopen — clean state, wake word listening again.
- [ ] "Hey Ivy, cancel" during a confirmation — denied, nothing runs.

## Implementation status (2026-09-30)
| Slice | Status | Notes |
|---|---|---|
| 10.1 Turn-taking | Partly done | `VoiceActivityDetector` (RMS per 20 ms, adaptive floor) replaces the amplitude gate and drives "Hearing you…" and the wake-session timeout. "Wait through pauses" setting → `realtimeInputConfig.automaticActivityDetection.silenceDurationMs` (short 300 ms, normal = server default, long 1500 ms); the live server accepts the field. **Not done:** explicit `activityStart/End` for push-to-talk; the 20-utterance cut-off comparison. |
| 10.2 Barge-in | Partly done | In-session recogniser uses on-device recognition when the Mac supports it (server fallback otherwise). Lone-"Ivy" heuristic exists behind `loneIvyBargeIn` (off, no UI). **Not done:** double-talk / AGC A/B, the ≤ 300 ms p50 measurement, false-positive rate. |
| 10.3 Wake reliability | Partly done | Idle listener keeps a 1.5 s pre-roll and hands it to the wake session; the mic now opens before the socket and up to 3 s spoken while connecting is sent first. Unanswered wakes are counted and shown in diagnostics. **Not done:** energy gate for the recogniser, idle-CPU measurement. |
| 10.4 Levels | Done (logic) | `AudioLevelMeter` (≤ 30 Hz on the main actor); halo around the Live icon follows the user while listening and Ivy while speaking; Reduce Motion hides it. Ivy's level is scheduled against playback time from the PCM, not tapped from the output device. |
| 10.5 Voice settings | Partly done | ElevenLabs speed / stability / style (sent only when changed) with a preview button; Live answer length and pace as instruction hints; Kore untouched. **Not done:** input-device picker. |
| 10.6 Device switching | Not started here | Mid-session route changes were already handled in Phase 8.3. No picker, no AirPods preference. |
| 10.7 Sleep / wake / lock | Done (logic) | `IvyAppEnvironment.handle(_:)` + `observeSystemEvents()`. |
| 10.8 Voice commands | Done, with a deviation | stop, cancel, end/goodbye, mute/unmute, repeat that. See below. |

Tests: `Tests/IvyTests/Phase10VoiceTests.swift` (28 tests). Everything above is verified with fakes only.

PTT recovery follow-up verification (2026-10-04): 81 targeted hotkey/release/socket tests passed; the
full rerun passed 1,188 core plus 24 native interface tests (about 35 seconds combined). The first full
run exposed a key-repeat regression and an unsynchronized new fixture; both were corrected before the
passing rerun. Changed executable-line coverage for the current working tree was 119/134 (88.81%);
the PTT-only changed lines were 72/86 (83.72%). This does not replace the real-keyboard checklist.

### Deviations
- **Commands are read from the Live input transcript, not recognised on-device first.** The in-session
  recogniser fires on "Hey Ivy" and stops, so the word after it only exists in the audio already streamed to
  Gemini. A command is acted on when the reply to it starts; that reply is dropped. If the server ever sends
  the reply before the transcript, the command is missed and Ivy simply answers it.
- "Hey Ivy" now also works while Ivy is thinking or running a tool: the turn is abandoned, its speech is
  dropped and any further tool call in it is answered "Cancelled by the user." without running. A tool that
  was already executing is not undone.
- Bare "goodbye" / "bye" ends the session without "Hey Ivy". Every other command needs the wake phrase.
- The pre-roll can include up to ~1 s of what was said just before "Hey Ivy", and the wake chime.
- Session start order changed for every session: microphone first, then socket.

### Needs a hands-on pass (nothing here was run against a real microphone)
- The whole manual checklist above.
- New session start order with echo cancellation on.
- Idle wake listener with the pre-roll converter installed (only runs when "Hey Ivy" is enabled).
- On-device in-session recognition: barge-in speed and accuracy versus before.
- Settings panel layout (now scrolls) and the level halo.
