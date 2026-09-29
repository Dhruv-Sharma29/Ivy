# Phase 10 — Advanced Voice Experience

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
- [ ] Pause mid-sentence for ~1 s — Ivy waits; finish — Ivy answers.
- [ ] "Hey Ivy" mid-answer on speakers and on headphones — stops within a beat.
- [ ] "Hey Ivy, what's the weather like?" in one breath from idle — answered.
- [ ] Change TTS speed; Kore still the Live voice.
- [ ] Switch AirPods ↔ built-in mid-session.
- [ ] Close the lid during Live; reopen — clean state, wake word listening again.
- [ ] "Hey Ivy, cancel" during a confirmation — denied, nothing runs.
