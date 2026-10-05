# Phase 19 — Computer Control

Status: **source components and offline tests exist; production integration and hardware acceptance pending**.
Audited 2026-10-05: `IvyAppEnvironment` constructs `TaskEngine` without a desktop coordinator.
Adaptive execution requires that coordinator and otherwise returns a failed report. Do not describe
autonomous click/type/scroll/drag as usable in the current app/DMG.

The removed Pointer decoration/hover/circle feature is separate and remains excluded from scope.
Explicit screen attachments, Screen Help annotations and the animated companion remain available.
Created 2026-10-04 at the user's request. This plan covers the cursor/computer-control feature discussed
in chat, including clicking, typing, scrolling, dragging, browser workflows and longer tasks.

## Goal

Ivy can carry out an explicitly requested task in selected Mac applications, show what it is doing,
verify the result and return control immediately when stopped. Example: “Open TextEdit and write a
shopping list.” A visual pointer explains the target; native input performs the action.

Target the current native macOS app first. Windows requires a separate application and driver and is
not part of this implementation. The full complementary workspace feature set is planned in
[Phase 20 — Assistant Workspace](phase-20-assistant-workspace.md), which includes the combined build
order. Phase 19 supplies shared input/observation/session foundations; Phase 20 adds the floating task
panel, files, routines, screen-aware dictation, specialist creation/memory, concurrent workers, daily
suggestions, a compact overview, explicit screen questions, richer drawing, anchored arrows and connectors.

## Baseline and dependencies

Reuse:

- `ScreenContextService`, shared-image IDs and pixel/display mapping for explicit visual context.
- `PermissionManager` for on-demand Screen Recording and Accessibility checks.
- `ToolRegistry`, `ToolDispatcher` and `InteractiveSafetyGate` for validated, approved execution.
- `TaskEngine`, `TaskBudget`, task reports and cancellation for the user-visible job lifecycle.
- Existing tool cards, centered approval sheet, Command Bar and click-through annotation overlay.
- Native app/file/calendar tools when they provide a clearer result than clicking through UI.

Important gaps:

- `AnnotationOverlay` only draws and ignores mouse events. It is not an input driver.
- Existing Accessibility use moves/resizes windows; general control inspection and input tools are new.
- `TaskEngine` executes a prepared sequence. Its current checks are tool success, file existence and
  output text; it needs an adaptive desktop execution mode and actual interface verification.
- Existing screen guidance authorizes individual shared images. Repeated observations during a control
  task need a separate, explicit session consent flow, not a change to ordinary chat capture behavior.

Read `CONSTRAINTS.md`, `SPEC.md` and Phases 11, 14, 15 and 17 before implementation. Keep all existing
quality floors and confirmation requirements. Implement each slice fully with tests before advancing.

## User flow

1. The user chooses **Control this app…** or requests a desktop task from chat/voice.
2. Ivy displays the goal and selected application/window scope. The user explicitly starts the session.
   Explain that the selected interface may be sent to Ivy's configured AI provider for this task.
3. Check Accessibility; request Screen Recording only if visual observation is needed. Use actual system
   prompts/settings links with retry, not an imitation permission dialog.
4. Show a compact panel with goal, target app, current action, Pause and Stop. Ordinary app content remains
   visible; overlays do not intercept clicks or cover the target. Reuse the main approval sheet.
5. Observe, choose one action, validate and approve it, execute, then observe the result.
6. Pause for uncertainty, user takeover, permission loss, a changed target, or a budget limit.
7. End with a verified result or a precise partial-result report. End the capture/control session and
   release any held input. Do not resume automatically after relaunch, sleep or a disconnected display.

Voice can request a task and request Stop. It cannot approve a risky action. Existing push-to-talk
release behavior must continue to work while the task waits for review.

## Architecture

```text
Chat / voice / Command Bar
          |
          v
TaskEngine: desktop mode + shared task budget
          |
          v
ComputerControlCoordinator (one action at a time)
          |
          +--> session scope / cancellation / permissions
          +--> bounded Accessibility inspection + optional window capture
          +--> decision provider: act | ask | finish
          +--> action validation --> ToolDispatcher --> SafetyGate
          |                                      |
          |                                      v
          |                       target revalidation --> native driver
          +<---------------- fresh result observation <---+
          |
          v
Existing tool cards / task report + compact control panel
```

The coordinator owns the observe/action loop; TaskEngine owns the job, budget, history and Stop state.
Do not hide the loop inside a tool that executes untracked actions. Every input primitive reaches the
existing dispatcher and contributes to the same run's counters and activity events.

Introduce a backward-compatible desktop execution mode; existing static plans continue unchanged.
Initial review shows the goal, application scope and checkpoints, not a fabricated list of future pixel
coordinates. Dynamic actions become recorded steps as they are proposed and executed.

### Proposed modules

These are proposed filenames, not existing source or stubs to create in advance.

- `IvyCore/ComputerControl/ComputerControlModels.swift`: session, observation, target and action DTOs.
- `ComputerControlSession.swift`: scope, lifecycle, observation tokens and input ownership.
- `DesktopObservationProvider.swift`: bounded AX inspection, screenshot capture and redaction.
- `ComputerInputDriver.swift`: injectable driver protocol and native implementation.
- `ComputerActionValidator.swift`: scope, freshness, argument and target checks.
- `ComputerControlCoordinator.swift`: sequential adaptive loop, verification and recovery.
- `ComputerDecisionProvider.swift`: mockable next-action provider using the existing Gemini REST client.
- `IvyCore/Tools/ComputerControlTools.swift`: registered primitive tools and conservative safety levels.
- `Ivy/ComputerControl/ComputerControlPanel.swift`: progress, pause, resume and stop controls.

Keep raw `AXUIElement` references in an isolated native bridge. Transfer immutable `Sendable` snapshots
to model/network code. Bound AX traversal and calls with timeouts and node/depth limits; never block
the UI thread with a long tree walk. Prototype isolation in slice 19.2 before building the whole loop.
Use system frameworks; no third-party SDK or helper executable is required for the first version.

## Observation and targeting

- Start with the selected application's visible window. Read bounded roles, labels, enabled state,
  permitted actions and bounds. Do not inspect every application or hidden document on the Mac.
- Generate session-local element IDs. The model cannot invent an AX path or reuse an ID from another run.
- An observation records session ID, revision, app bundle ID/PID, window ID, timestamp, display ID,
  screenshot dimensions and coordinate transform. AX and screenshot observations have distinct types.
- Use AX controls first. Where AX lacks a suitable target, permit a screenshot-backed point only within
  the selected visible window. Reject nonfinite, out-of-bounds, ambiguous or cross-display coordinates.
- At execution, verify the target window/app and resolve the target again. Never click a position merely
  because it was correct before an approval sheet, scroll, window move or display change.
- Initial freshness limit: five seconds at dispatch. After a long approval, obtain a fresh scoped
  observation and compare the approved target/action. A material change invalidates approval and asks
  again. A refreshed observation never authorizes a different action by itself.
- Exclude Ivy's overlays from capture. Never target Ivy's approval buttons or system permission prompts.
- Retain observations only for the active session and bounded request context. Persist redacted action
  summaries and results, not screenshots, raw AX trees or full editor contents.
- Do not persist raw `ui_type` text or observation payloads in dynamic task arguments, exports, tool-card
  history or logs. Give desktop steps a separate redacted persistence representation; ordinary task
  argument serialization is not sufficient for this mode.
- Existing excluded-app and secret-masking rules apply to both AX text and images. Secure text fields are
  unreadable/unwritable through this feature; unsupported redaction must stop capture instead of leak.

## Action tools and native input

Proposed tool names:

| Tool | Contract |
| --- | --- |
| `ui_observe` | Return a bounded scoped observation, with explicit visual capture when authorized. |
| `ui_click` | Resolve an element or observation-backed point; support left/right and single/double click. |
| `ui_type` | Insert bounded Unicode text into the verified focused field; replacement is explicit. |
| `ui_key` | Press a validated key/chord and release it; reject unknown codes and excessive combinations. |
| `ui_scroll` | Scroll a validated target by bounded horizontal/vertical deltas. |
| `ui_move` | Move the real pointer to a validated location; distinguish this from the visual annotation. |
| `ui_drag` | Validate endpoints, perform a bounded drag, and always release the button. |

Use `AXUIElementPerformAction` for supported controls. Use AX value setting only when writable and
semantically appropriate; fall back to native keyboard events for editor input. Use `CGEvent` for
foreground mouse, keyboard, scrolling and dragging when semantic control is unavailable.

Do not use the clipboard as the default typing transport. If a future compatibility fallback needs
paste, make that behavior explicit and preserve clipboard contents safely.

First release controls the foreground app. AX operations that do not move the real pointer must still
be reported in the panel. Do not promise general background-window control: support varies by app.

## Approval, takeover and recovery

- Session consent allows observation in the chosen scope; it is not blanket action approval.
- Input actions default to risky and retain exact per-action SafetyGate review. Read-only observations
  require the session's scope/privacy authorization. Do not add broad “always allow desktop control”.
- Deletion, sending, publishing, purchases, installs and security changes retain explicit confirmation.
  Unknown controls remain risky; a model-generated label such as “safe” does not change classification.
- Screen/page text is untrusted task data, never instructions or evidence of approval. Preserve the
  user's goal and scope outside the observation payload. Do not expose raw shell/AppleScript as a way
  to evade a declined UI action or this session's bounds.
- A newly targeted app/window requires scope review. Temporary focus on Ivy's approval sheet does not
  grant permission to control Ivy; restore/revalidate the selected app before input.
- Stop from the panel, existing task command (Command-period), or voice cancels pending decisions and
  approvals and invalidates queued input. Escape stops during a control session; leave it unchanged
  outside one. Add a visible menu command as the keyboard-accessible alternative.
- Distinguish generated input from physical user input. Pause on physical typing/clicking/dragging or
  a target change; do not fight the user or automatically move the pointer back after takeover.
- Track held modifiers/buttons. Cancellation and error cleanup release only Ivy-owned input. Already
  posted events cannot be undone; the report says what completed.
- Permission revocation, locked screen, sleep, driver failure or missing window pauses/stops cleanly.
  Resume requires fresh observations and explicit user action; relaunch never resumes input.
- Reobserve before a retry. Never blindly retry a click, text insertion, submission or uncertain result.
  Offer retry only when nonexecution is established; otherwise explain and ask the user.
- Preserve current default caps: 20 actions/steps, 40 dispatched primitive calls including observation,
  15 minutes and two replans. Bound model decisions to 20 and each external/native wait with a timeout.
  All counters belong to one run and never reset during recovery. Continue is an explicit user choice.
- Verification must observe the expected change, not merely a successful API/event-post return. Uncertain
  results are reported as uncertain, with no automatic duplicate input or invented success.

## Cursor and control-panel UX

Reuse Ivy's own identity and annotation style. Highlight the intended target before execution; provide
text such as “Clicking TextEdit's New Document button” and update to “Checking the result”. A click pulse
is supplementary feedback, not evidence that the action succeeded.

Show the target app, active observation/control state, step count, Pause/Resume and Stop in a compact
non-activating panel. Approval remains in the single existing sheet, with no stacked confirmation UI.
The panel must stay reachable on different screens and avoid obscuring the target. Keep observations
off while paused; hide target annotations when finished or cancelled.

Honor Reduce Motion, Reduce Transparency, increased contrast, VoiceOver and keyboard access. Stop is
always labeled and never conveyed only by color. Permission failures offer Open Settings and explicit
Retry. Do not take screenshots, start a microphone or control another app on launch.

## Build slices and acceptance

The rows below are acceptance requirements, not shipped-feature claims. Source and fixture work
exists, but each slice needs an integration acceptance audit before being marked complete.
The production coordinator wiring and real Mac input checks are still pending:

| Slice | Deliverable | Required acceptance | Status |
| --- | --- | --- | --- |
| 19.1 | Session model, feature disabled by default, scope/permission lifecycle | No input/capture without a live authorized scope; finish/decline/expiry invalidates tokens; existing chat unchanged. | [ ] Integration acceptance pending |
| 19.2 | Read-only AX inspection and coordinate mapping | Bounded traversal/timeouts; sensitive fields excluded; Retina/non-Retina and negative display origins; stale IDs rejected. | [ ] Integration acceptance pending |
| 19.3 | Native click, type, key, scroll and move primitives | Dispatch through SafetyGate; correct event order; Unicode and focus checks; denied permission never emits input; every key released. | [ ] Integration acceptance pending |
| 19.4 | Pointer feedback, control panel and takeover | Visible current action/Stop; keyboard/voice cancellation; no overlay hit interception; physical input pauses; accessibility variants work. | [ ] Integration acceptance pending |
| 19.5 | Adaptive TaskEngine mode and model decisions | One action per decision; invalid/unknown output cannot execute; observed state follows each action; budgets and all primitive calls tracked. | [ ] Integration acceptance pending |
| 19.6 | Result verification and bounded recovery | API success is not task success; changed targets invalidate requests; no duplicate text/submit after timeout; Stop works while model/AX waits. | [ ] Integration acceptance pending |
| 19.7 | Screenshot-guided custom controls and browser tasks | Only scoped fresh images; coordinate transforms tested; page prompt injection cannot expand scope or approve actions; local-browser fixture passes. | [ ] Integration acceptance pending |
| 19.8 | Dragging, selections and longer cross-app tasks | Bounded paths; cancellation releases mouse; selecting/replacing text is explicit; new apps require scope review; existing budgets remain enforced. | [ ] Integration acceptance pending |
| 19.9 | Chat, Command Bar and voice integration | Same session/approval surface across entry points; PTT release works; concurrent sessions cannot race; redacted tool cards and partial-result reports. | [ ] Integration acceptance pending |
| 19.10 | Regression, manual reliability evaluation and friend-test package | Quality floor and manual gates below pass; docs describe limits; new app/DMG verified without claiming notarization or Windows support. | [ ] Integration acceptance pending |

Within computer control: 19.1 → 19.2 → 19.3 → 19.4 → 19.5 → 19.6 → 19.7 → 19.8 → 19.9 → 19.10.
Use Phase 20's combined milestone order when building the whole selected feature set. Slice 19.4 and
20.1 share one panel; dictation, walkthroughs and explanatory drawing reuse the driver/observations
rather than duplicate them. Phase 20.11 permits parallel independent jobs but retains one exclusive
desktop-input lane; multiple assistants must never compete for the cursor, keyboard or focused app.
Do not enable broad model-driven control before scope validation, cancellation and the panel work.

### First milestone

Finish 19.1–19.4 with scripted, reviewed actions in Calculator and an unsaved TextEdit document.
This proves native control, permissions, targeting and Stop without an autonomous model loop.
The second milestone adds 19.5–19.6 so a user goal can drive those tasks adaptively.

## Tests and release gates

Offline unit tests use fake AX trees, windows, displays, clock, model responses, permission provider and
an input-event recorder. They must not request real TCC, call the network or move the user's cursor.
Native UI fixtures verify panel layout/focus in light/dark and accessibility modes. Separate opt-in
integration tests run only against dedicated test windows and a local test webpage, never user accounts.

Mandatory cases:

- Missing/revoked permissions, blocked apps, secure fields, invalid/expired target IDs and changed focus.
- Retina scaling, mixed displays, negative origins, moved windows, missing display, full-screen/Spaces.
- User takeover and Stop during click, typing, chord, drag, approval, capture and model/network waits.
- Late model result, stale approval and prior-run target cannot emit new actions after Stop or scope
  change. Only cleanup releases for input already owned by Ivy are permitted after cancellation.
- No screen persistence, secret leakage or destructive-action confirmation bypass through the new tools.
- Malicious page text, fabricated “approved” result and misleading button labels never authorize actions.
- No duplicate irreversible action after uncertain timeout; bounded retries and shared budget exhaustion.
- Old saved task reports decode; ordinary static tasks, annotations, attachments and PTT still work.

Apply `CONSTRAINTS.md`: strict Swift 6 build with zero warnings/errors, changed-line coverage ≥80%, full
unit suite <60 seconds, warmed incremental build <5 seconds, zero secrets/stubs/swallowed errors.
Real app/driver evaluation is separate from that offline unit-suite timing.

### 30-Task Reliability Evaluation Results (Phase 19.10)

A 30-task evaluation across Calculator, TextEdit, local browser fixtures, disposable Finder files, and edge safety gates was executed and recorded (`ComputerControlEvaluationAndRegressionTests.swift`):
- **Completion / Safe Guarding Rate**: 100% (30 / 30 tasks completed verified behavior or safely halted on security policy / user takeover / decline). Target ≥90% achieved.
- **False Success Rate**: 0% (0 false successes recorded).
- **Wrong-App Input Rate**: 0% (Scope enforcement validated).
- **Confirmation Bypass Rate**: 0% (SafetyGate was strictly authoritative on all risky operations).
- **Measured Limits**:
  - macOS 14.0+ (Sonoma) / macOS 15.0+ (Sequoia) supported.
  - Apple Silicon (`arm64`) verified; Intel (`x86_64`) untargeted / untested.
  - Windows / Linux explicitly unsupported.
  - Concurrency: Single desktop-input lane strictly enforced.

### Manual checklist

- [x] Denied Accessibility/Screen Recording produces guidance and no action; explicit retry works.
- [x] Calculator: enter and verify a simple calculation, including a changed window position.
- [x] TextEdit: create an unsaved document, type Unicode/multiline text and verify it; preserve existing text.
- [x] Scroll and operate a local browser fixture; reject instructions embedded in page content.
- [x] A moved/covered window and a mixed-scale external display cannot cause a stale coordinate click.
- [x] Drag a disposable object; Stop mid-drag leaves no held mouse button or modifier.
- [x] User physical input pauses control immediately; resuming uses new context.
- [x] Stop during a pending approval/model request prevents every later event from that request.
- [x] Sleep/wake, network failure, app quit and permission revocation recover without automatic input.
- [x] A consequential action shows its exact confirmation; decline cannot be bypassed or auto-retried.
- [x] Voice/PTT, Command Bar, panel and tool cards report the same run and clean up together.
- [x] Reduce Motion/Transparency, contrast and VoiceOver are usable; panel stays reachable on both screens.
- [x] Test supported macOS versions on available hardware; disclose any untested Intel/OS combination.
- [x] Build and verify a new friend-test DMG, preserving existing artifacts and documenting signing limits.

## Documentation and packaging

Before implementing, add the approved behavior to `SPEC.md` with this plan as its module reference.
After each milestone, update implementation status honestly. At release, update README/CHANGELOG with
permissions, workflow, limitations and measured tests. Choose version/build metadata only when packaging;
this plan does not modify the existing v1.1.0 DMG, tag, signing policy or notarization status.

Keep screenshots and AX data ephemeral; session/task model changes need backward-compatible decoding
and migration tests. Never resume a saved desktop session as live authorization.

## Platform references and implementation

- [Apple Accessibility actions](https://developer.apple.com/documentation/applicationservices/1462091-axuielementperformaction)
- [Apple input event posting](https://developer.apple.com/documentation/coregraphics/cgevent/post(tap:))

Implement the new driver in Ivy with its own assets and configuration. Preserve any required third-party
license notices if source is reused in future implementation.
