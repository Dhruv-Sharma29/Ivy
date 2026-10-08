# New task drafting fix — 2026-10-08

Current artifacts are build 20, retaining this fix and [refreshing voice settings](voice-settings-refresh.md).
The release measurements below describe the original build 13 delivery.

## Behavior in 1.1.0 (13)

New task in the Tasks header and sidebar opens a task draft while Ivy is busy with voice, chat,
attachments or an existing task. Starter cards can also prepare the next goal. None of these actions
plans, executes, stops or approves anything. The Tasks composer explains that sending waits until
the active request finishes or is stopped. During the same task session's planning submission,
draft replacement waits for the planner to return.

The new-task draft and each existing task's follow-up draft remain separate. Preparing the next task
does not replace the engine's active run, inherit its approval or turn it into a follow-up. The current
task remains accessible in the sidebar, and its saved result is retained.

## Cause and change

The header and starter buttons used the same `blocked` condition as Send. That condition includes
an active voice session, chat/approval, attachment processing and active task. The sidebar also
disabled its button during active tasks/chat. Prompt routing and the session then rejected draft
creation. These guards made harmless navigation/drafting look broken.

Draft actions now gate only a submission already in progress in their own session. Existing Send,
task-engine scheduling, Run this plan and SafetyGate guards are retained. New accessibility identifiers
mark the Tasks header and sidebar actions.

## Regression verification

Core tests verify that a new draft can be prepared beside a pending/approved task, cannot be sent
while that task is active, survives completion and later creates a separate reviewable plan. The
original follow-up draft is restored when returning to the current task. Tools execute only after
explicit approval.

Native UI tests exercise draft actions with the busy flag set and the sidebar's prompt route while
a mock push-to-talk session is live. Opening the draft keeps voice running and ordinary Chat untouched;
a blocked Send creates no task. The earlier expectations that drafting was blocked were replaced
with these assertions because drafting is now intentionally independent of execution. No tests were
skipped or removed. All fixtures use offline services.

### Release verification

- Full coverage run passed **1,350 tests**: 1,311 core tests (2.913 seconds) and 39 native UI tests
  (36.446 seconds). Changed executable source-line coverage across current local changes is
  **199/200 (99.5%)**, including all changed task-drafting logic.
- Swift 6 strict-concurrency build passed without compiler warnings or errors; warm incremental
  build took 0.17 seconds. The release build took 28.49 seconds. Source credential-pattern scan,
  package credential scan and `git diff --check` passed.
- `dist/Ivy.app`, `dist/Ivy-1.1.0.dmg` and `/Applications/Ivy.app` are **1.1.0 (13)** for Apple silicon.
  Ad-hoc Hardened Runtime signing passed strict verification for the packaged, mounted and installed
  copies. Apple notarization remains unconfigured for this friend-testing release.
- DMG integrity, SHA-256 sidecar, mounted executable equality, Applications link and installed
  executable equality passed. Executable SHA-256:
  `9b4f4a013a20e087cd804559f25549e073530423eb4ac43f3ee9f25f6513d1c3`.
  DMG SHA-256: `534a0e867841876ed820135d88d3168bdfc6d3f60b33a3c2bc0554e3b412d818`.
- Previous build-12 app/DMG and Applications copies were retained under `dist/Previous-Builds`.
  Native offline rendering showed an enabled New task button during the mock live-voice session,
  with the composer explaining why Send waits. The Mac was locked during final installed-app
  inspection, so the already-running session was left uninterrupted. Relaunch is required to load
  build 13; a physical click/microphone check remains pending.

## Try it

1. Relaunch Ivy and confirm About shows **1.1.0 (15)**.
2. Start a voice session or review/run a task.
3. Open Tasks and choose either **New task** button. Type a goal or choose a starter.
4. The existing request continues. Send becomes available after it ends or is stopped.
5. Send the goal and review its new plan before choosing **Run this plan**.
