# Phase 15 — Agentic Workflows

## Goal
From "Open VS Code" to "Set up the environment for this project and run the tests": Ivy plans multi-step
work, shows the plan, executes it tool by tool with approval checkpoints, verifies each step, recovers from
failures, and can be cancelled at any moment — with SafetyGate still authoritative for every single action.

## Baseline
- `IvyBrain.send` runs a model ↔ tool loop capped at 5 turns; each tool call is dispatched individually via
  `ToolDispatcher` → `InteractiveSafetyGate` (one confirmation card at a time).
- No plan representation, no progress UI, no task history, no cancellation of an in-flight loop beyond
  denying a confirmation.

## Scope
**In:** planner, task graph, executor with verification/retry/recovery, approval checkpoints, budgets,
cancellation, progress UI, task history, voice-spawned tasks ("Hey Ivy, agent: …").
**Out:** unattended/background autonomy (Phase 12 can only *notify*), running while Ivy is quit, remote
agents, parallel execution of risky steps.

## Design

### Architecture
```text
User request ──► Planner (Gemini, structured output) ──► TaskPlan (DAG of steps)
                                                            │
                          user reviews plan (Approve / Edit / Cancel)
                                                            ▼
                                   Executor (@MainActor state machine, one step at a time)
      for each ready step:  validate args → classify → SafetyGate (risky ⇒ confirmation card)
                            → execute tool → verify (check or model judgement) → record
      on failure:           retry policy → re-plan remaining steps (bounded) → ask user
                                                            ▼
                                          Final report (+ Phase 12 completion notification)
```

### Plan model
```swift
struct TaskPlan: Codable { let id: UUID; var goal: String; var steps: [TaskStep]; var budget: TaskBudget }
struct TaskStep: Codable, Identifiable {
  let id: String; var title: String            // human-readable, shown in UI
  var tool: String; var arguments: [String: AnyCodable]
  var dependsOn: [String]
  var verification: Verification?              // .fileExists(path) | .exitCode(0) | .outputContains(s) | .modelCheck(prompt)
  var onFailure: .retry(max: Int) | .replan | .ask | .abort
  var status: .pending | .awaitingApproval | .running | .verifying | .succeeded | .failed(String) | .skipped | .cancelled
}
struct TaskBudget { maxSteps = 20, maxToolCalls = 40, maxDuration = 15 min, maxReplans = 2 }
```
- The planner prompt uses JSON-schema structured output; plans are **validated** before display: only
  registered tools, arguments pass each tool's `validate`, DAG acyclic, within budget. Invalid → re-ask once →
  fall back to the normal chat loop.

### Approval model (SafetyGate stays authoritative)
1. **Plan approval** shows every step with its risk badge. Approving the plan approves the *order*, not the
   actions.
2. **Every risky step still gets its own SafetyGate confirmation** at execution time with the exact
   arguments (they may differ from the plan after re-planning).
3. Optional, explicit, scoped convenience: "Allow `run_shell` for commands starting with `swift test` in
   `~/project` for this task" — a per-task allow-rule created only from a confirmation card, shown in the
   task header, expires when the task ends, and never applies to delete/`sudo`/network-changing commands.
   (Ship behind a setting; default off.)
4. Natural language, plan text or model output can never create an allow-rule.

### Execution & recovery
- Steps run sequentially (a DAG allows showing parallelism, but risky steps never run in parallel; safe
  read-only steps may run 2-wide).
- Verification after each step; failures follow `onFailure`. Re-planning sends the goal, completed steps,
  failure output (redacted, truncated) and asks for a revised remainder — bounded by `maxReplans`.
- Budgets enforced by the executor; hitting one pauses the task with "Continue / Stop".
- **Cancellation:** Stop button, Esc, "Hey Ivy, stop/cancel": cancels the running tool (shell processes get
  SIGINT then SIGTERM), denies any pending confirmation, marks remaining steps cancelled. No rollback of
  completed steps (reported clearly); optional compensating steps may be *proposed*, never auto-run.

### Progress UI (lives in the Phase 17 app window; compact version in the popover)
- Task card: goal, step list with live status icons, current step output tail (redacted), elapsed time,
  Stop button, allow-rules chip.
- Voice: short spoken updates at milestones only ("Tests are running", "Done — 3 failures").

### Task history
- `Application Support/Ivy/Tasks/<id>.json`: plan, step statuses, timestamps, redacted outputs (≤ 4 KB per
  step), final report. Linked from the conversation; re-run = new plan from the same goal (re-approved).

### Voice-spawned agents
- "Hey Ivy, agent: tidy my Downloads folder" → planner runs → plan card appears in the app window (and a
  notification) → approval by click only.

## Work breakdown
| Slice | Deliverable | Acceptance |
|---|---|---|
| 15.1 | Plan model + validator | Invalid tools/args/cycles rejected; fixtures |
| 15.2 | Planner (structured output) + fallback | 30 eval goals produce valid plans ≥ 80 % |
| 15.3 | Executor state machine (sequential) | Deterministic runs with fake tools; statuses correct |
| 15.4 | Per-step SafetyGate + plan approval UI | Every risky step confirmed individually (test) |
| 15.5 | Verification + retry + re-plan | Injected failures recover or ask; budgets respected |
| 15.6 | Cancellation | Stop mid-shell kills the process; pending confirmation denied |
| 15.7 | Progress UI + voice milestones | Live status updates; output tail redacted |
| 15.8 | Task history + re-run | Persisted, redacted, re-run requires re-approval |
| 15.9 | Scoped allow-rules (behind setting) | Only from confirmation cards; expire; never for destructive patterns |
| 15.10 | Voice-spawned tasks | "Hey Ivy, agent: …" opens a plan for approval |

## Safety & privacy
- SafetyGate + tool validation unchanged and authoritative; the executor is just another caller.
- Destructive-pattern deny-list for allow-rules (`rm -rf`, `sudo`, `git push --force`, disk utilities…).
- Outputs stored redacted and truncated; no secrets in task history.

## Testing
- Fake tool registry with scripted outcomes (success, flaky, fail, slow, hang) for executor tests.
- Virtual clock for budgets/timeouts.
- Security tests: plan text containing "approved" or allow-rule syntax changes nothing.

## Risks
| Risk | Mitigation |
|---|---|
| Runaway loops / cost | Budgets, max re-plans, pause-and-ask |
| Approval fatigue → users click through | Clear diff-style confirmation cards; scoped allow-rules for repetitive safe patterns |
| Partial completion leaves messy state | Clear report of what ran; proposed (not automatic) compensations |

## Exit criteria
Eval goals meet targets; executor tests cover every status transition; manual checklist passed.

## Manual checklist
- [ ] "Create a folder `demo` on the Desktop with a README and open it in Finder" → plan → approve → confirmations → done.
- [ ] "Run the tests in ~/project and summarise failures" → progress card, final report.
- [ ] Force a failing step → retry → re-plan → asks you.
- [ ] Stop mid-task → shell process terminated, remaining steps cancelled.
- [ ] Task history shows the run; re-run asks for approval again.

## Implementation status (2026-10-01)
| Slice | Status | Where |
|---|---|---|
| 15.1 Plan model + validator | Done | `Agent/TaskPlan.swift`: steps must name a registered tool and pass that tool's own `validate`; ids unique, dependencies known and acyclic, ≤ 20 steps; `fileExists` checks must be paths `file_op` could use. Tasks may not call `enable_tools`, `remember_preference` or `schedule_followup` |
| 15.2 Planner + fallback | Done | `GeminiTaskPlanner` (one REST call, JSON in the reply; fences/prose tolerated). An invalid plan is re-asked once with the reason; then the task ends with a message. **Not done:** the 30-goal eval (needs real model calls) |
| 15.3 Executor | Done | `TaskEngine` (@MainActor), sequential, one step at a time |
| 15.4 Per-step SafetyGate + plan approval | Done | Steps go through the brain's own `ToolDispatcher`, so every risky step shows its normal card with its exact arguments; approving the plan approves the order only. Declining a card pauses the task (never retried by itself) |
| 15.5 Verification / retry / re-plan | Done | Checks: tool success, `fileExists`, `outputContains`. `retry` (once), `ask` (skip / retry / stop), `replan` (≤ 2, remainder shown for approval again; the failed step is marked replaced), `abort` |
| 15.6 Cancellation | Done | Stop (⌘.) cancels the running tool — `run_shell` now kills the command's process tree on cancellation — denies a waiting card, marks the rest cancelled; completed steps aren't undone (the report says so) |
| 15.7 Progress UI | Done (window) | `TaskCardView` above the composer: plan, live step status, output tail, pause choices. **Not done:** spoken milestones; a compact popover card |
| 15.8 History + re-run | Done | `FileTaskStore` (`Application Support/Ivy/Tasks/<id>.json`, 0600); outputs redacted and ≤ 4 KB per step; "Run again" plans afresh and needs approval again |
| 15.9 Scoped allow-rules | Not built (on purpose) | They relax confirmation; left for an explicit decision |
| 15.10 Voice-spawned tasks | Not done | Tasks start from chat with `/agent <goal>` |

Budgets: 20 steps, 40 tool calls, 15 minutes of running time, 2 re-plans; a budget pause offers Continue (one more
budget's worth) or Stop. While a task is active, chat sends wait (one approval surface at a time).
Finished tasks add their report to the conversation and, if Proactive Ivy is on, send a "Task update" notification.

Tests: `Tests/IvyTests/Phase15AgentTests.swift` — validation, ordering, parsing, clipping, approval-first, re-ask,
in-order runs, one card per risky step (titles can't approve), decline/skip/dependents, retry/ask, re-plan,
abort and checks, budget pause/continue, stop during a card and during a tool, re-run, history, wiring, and a real
cancelled `sleep 30`.

## Task workspace update (2026-10-07)

Tasks now has an in-panel goal composer. New task and starters draft here; sending proposes a plan.
Each live or saved plan uses a connected vertical execution flow with status text/icons, dependency
labels and expandable redacted arguments/output. Arrows show sequential execution order.
Follow-ups start a new plan with bounded/redacted previous goal, report and step results, requiring
fresh approval. Optional parent/origin metadata restores recent task threads and isolates their results
from ordinary Chat; old task JSON remains compatible. This implements the main-window conversation
and flow presentation, not the proposed floating panel, recurring autonomy or parallel agent execution.
See [verification](../../tasks/task-panel-flow.md).
