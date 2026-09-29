# Phase 12 — Proactive Ivy

## Goal
Let Ivy speak first — reminders, follow-ups, briefings, "tell me when…" — while keeping the user in control:
every proactive feature is opt-in, visible, explainable, quiet when asked, and can only **notify or suggest**.
Proactive Ivy never executes a risky action on its own.

## Baseline
- Purely reactive: Ivy acts only on a message, PTT, wake word or click.
- Reusable pieces: `calendar_event` + EventKit, Phase 11 `reminders`/`notify`, Phase 15 task engine
  (approval checkpoints), Phase 9 conversations, `SettingsStore`, `PermissionManager`.
- Ivy runs only while the app is open (menu bar, `LSUIElement`); no login item.

## Scope
**In:** scheduler, triggers (time, calendar, app/task events, simple conditions), local notifications with
actions, follow-ups, daily briefing / morning summary, quiet hours, activity log, launch-at-login.
**Out:** background execution when Ivy is quit (no daemons/LaunchAgents beyond the login item), remote push,
server-side schedules, email/web polling of third-party accounts.

## Design

### Architecture
```text
ProactiveEngine (@MainActor)
 ├─ TriggerStore      (JSON, Application Support/Ivy/Proactive, 0600, schema-versioned)
 ├─ Scheduler         (Clock-injected; next-fire computation; wakes on sleep/wake + timezone change)
 ├─ Evaluators        time | calendar | appEvent | taskCompletion | condition
 ├─ Gatekeeper        opt-in per kind, quiet hours, focus/DND, rate limits, dedupe
 └─ Deliverer         UNUserNotificationCenter (+ optional spoken summary via ElevenLabs when user present)
                        └─ actions: Open in Ivy | Snooze | Done | Stop these
```

### Trigger model
```swift
struct ProactiveTrigger: Codable, Identifiable {
  let id: UUID; var kind: Kind          // .reminder, .followUp, .calendarHeadsUp, .briefing, .watch
  var schedule: Schedule                 // .at(Date), .daily(time, weekdays), .relative(to: eventID, offset)
  var condition: Condition?              // .appLaunched(bundleID), .taskFinished(taskID), .processExited(pid) …
  var message: String                    // what to tell the user (redacted, ≤ 500 chars)
  var suggestedPrompt: String?           // opens a conversation pre-filled, never auto-sent
  var createdBy: .user | .ivyWithConfirmation
  var createdAt: Date; var lastFiredAt: Date?; var isEnabled: Bool
}
```
- Created by the user in UI, or by Ivy through a new **`schedule_followup` tool** (classification: risky →
  SafetyGate confirmation shows exactly when and what). "Remind me if…" → trigger with a condition.

### Features
1. **Scheduled reminders** — Ivy-native (not the Reminders app) for quick "in 20 minutes" nudges; Phase 11
   `reminders` remains for Apple Reminders.
2. **Calendar-aware heads-up** — N minutes before events (opt-in, per-calendar allow-list); summary of the
   event only; never reads notes/attendees unless the user enables "include details".
3. **Follow-ups** — at the end of a conversation Ivy may *offer* "Want me to check back tomorrow?"; accepting
   creates a trigger (via confirmation).
4. **"Remind me if…"** conditions limited to observable, local, cheap signals: app launched/quit, a Phase 15
   task finished/failed, a file appeared in a folder (FSEvents on a user-chosen folder), battery below X %.
   No screen watching, no network polling.
5. **Task completion notifications** — Phase 15/16 long tasks notify on completion/failure.
6. **Daily briefing / morning summary** (opt-in): at a chosen time or first unlock after it — today's events,
   due reminders, pending follow-ups, unfinished tasks. Generated with one Gemini call from **local data
   only**, delivered as a notification + conversation entry; spoken only if the user taps "Read to me".

### Gatekeeper rules
- Global master switch "Proactive Ivy" (default **off**) + per-kind toggles.
- Quiet hours (default 22:00–08:00), respect macOS Focus (`INFocusStatusCenter`) → defer, don't drop.
- Rate limit: ≤ 6 proactive notifications/hour; identical messages deduped within 1 h.
- No proactive **tool execution**. A notification action may open Ivy with a suggested prompt; anything risky
  still goes through SafetyGate after the user sends it.
- Missed while asleep/closed → one catch-up digest on next launch, not a burst.

### Activity log & transparency
- "Proactive activity" list: every trigger fired, when, why, and what was shown; one-click "stop these".
- Every notification says why it appeared ("You asked me on Tue to…").

### Launch at login
- `SMAppService.mainApp.register()` behind a setting (default off, suggested when enabling Proactive Ivy).

## Work breakdown
| Slice | Deliverable | Acceptance |
|---|---|---|
| 12.1 | TriggerStore + schema + migration + recovery | Corrupt store quarantined (Phase 8.5); triggers survive relaunch |
| 12.2 | Scheduler (clock-injected) | Fires at correct times across sleep/wake, DST and timezone changes (tests) |
| 12.3 | Deliverer + notification actions | Snooze/Done/Open/Stop work; auth requested on first enable only |
| 12.4 | Gatekeeper | Quiet hours, Focus, rate limit, dedupe, catch-up digest |
| 12.5 | `schedule_followup` tool + UI creation | Model can propose; SafetyGate confirmation required |
| 12.6 | Calendar heads-up | Per-calendar allow-list; no details unless enabled |
| 12.7 | Conditions (app, task, folder, battery) | Each evaluator unit-tested with fakes |
| 12.8 | Daily briefing | Built from local data; one Gemini call; skipped when quota exhausted |
| 12.9 | Activity log + launch at login | Every fire logged; login item toggles correctly |

## Safety & privacy
- Local data only; nothing leaves the Mac except the single briefing prompt (redacted, user-enabled).
- Trigger messages pass `SecretRedactor`; condition folders are user-chosen via `NSOpenPanel`.
- Proactive features cannot enable themselves; a follow-up proposal is a suggestion requiring confirmation.

## Testing
- Virtual clock drives weeks of schedule in milliseconds; fake Focus/notification center/EventKit.
- Property test: no configuration produces more than the rate limit.
- Test that no trigger path reaches `ToolDispatcher.dispatch` without a user message.

## Risks
| Risk | Mitigation |
|---|---|
| Notification fatigue | Off by default, rate limits, dedupe, digest, easy "stop these" |
| Creepiness (calendar/app awareness) | Explicit per-source opt-in, "why am I seeing this", activity log |
| Timers drift while asleep | Recompute next fire on wake and on timezone/clock change notifications |

## Exit criteria
All slices accepted; virtual-clock suite covers DST/timezone/sleep; manual checklist passed; privacy review
section added to `docs/PERSISTENCE_AND_SECURITY.md`.

## Manual checklist
- [ ] Enable Proactive Ivy; "remind me in 2 minutes to stretch" → confirmation → notification fires.
- [ ] Snooze it; mark Done; "Stop these".
- [ ] Calendar heads-up 10 min before a test event (allow-listed calendar only).
- [ ] Set quiet hours to now → notification deferred to the digest.
- [ ] "Tell me when the build finishes" (Phase 15/16 task) → completion notification.
- [ ] Morning briefing at a chosen time; "Read to me" speaks it.
- [ ] Activity log lists every fire with its reason.
