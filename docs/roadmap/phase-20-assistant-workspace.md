# Phase 20 — Assistant Workspace

Status: **planned; all eight features pending**. Added 2026-10-04 at the user's request.
This extends [Phase 19 — Computer Control](phase-19-computer-control.md) with eight selected Ivy features.
It does not implement features, connect accounts or authorize runtime actions.

## Goal and scope

Make Ivy useful from anywhere on the Mac: follow tasks in a small panel, inspect produced files, schedule
repeat work, choose specialist assistants, dictate into other apps, open a compact overview, follow screen
walkthroughs and connect external tools/accounts.

Keep Ivy's native visual language, existing chat/library/tasks and single approval surface. Reuse current
voice, memory, tool cards, screen annotations and task engine. These are additions to existing foundations,
not a rewrite. Windows and server-side unattended agents remain outside scope.

Read `CONSTRAINTS.md`, `SPEC.md` and relevant Phases 9–17 before implementing. Update the master spec for
each implemented milestone. Do not relax existing safety, privacy, dependency or strict-concurrency rules.

## Combined build order

| Milestone | Work | Result |
| --- | --- | --- |
| A — control foundation | 19.1–19.4 with 20.1 | Reviewed Calculator/TextEdit control and one shared floating task panel. |
| B — useful results | 20.2, then 20.3 | File gallery/previews, followed by repeatable read-only tasks and routine controls. |
| C — adaptive work and dictation | 19.5–19.6, then 20.4 | Verified computer-use loop plus a separate dictation mode using the same input driver. |
| D — organized assistants | 20.5, then 20.6 | Specialist contexts and an optional compact overview of real tasks/results. |
| E — guidance and advanced control | 20.7 alongside 19.7–19.9 | Guided manual walkthroughs, browser control, dragging and consistent chat/voice entry points. |
| F — connected tools | 20.8 | Custom connectors, named accounts and explicit permissions. |
| Release checkpoints | 19.10 and the validation gates below | Tested milestone builds; later optional features do not block packaging a finished milestone. |

The panel is implemented once, not separately for Phases 19 and 20. The priority within workspace work
remains floating task panel → generated-file gallery → recurring task controls. Connectors come last
because they add authentication, account routing and external service failure cases.

## 20.1 — Floating task panel

**Foundation:** existing task state, tool cards, Command Bar and the planned Phase 19 control panel.

- Present a compact, non-activating panel with goal, current step/status, task age, Open in Ivy and Stop.
  Add Pause/Resume only where the execution state supports them; do not fake a paused operation.
- Reuse the existing confirmation sheet. The panel can show “Needs approval” and open the request;
  it cannot independently approve it or create a second confirmation queue.
- Follow-up text/voice is bound to the displayed run. Completed runs accept a continuation as a new
  reviewed task. A running task queues follow-ups for a safe checkpoint; never silently changes an
  in-flight action or starts another control session.
- Keep the panel reachable across displays/Spaces. Support keyboard access, VoiceOver, Reduce Motion,
  increased contrast and opaque fallback surfaces. Optional speech is quiet during configured quiet hours.

**Acceptance:** the same run/status appears in chat, Tasks and the panel; Stop cancels it everywhere;
stale run IDs cannot answer approvals or alter a newer task; follow-ups never leak to another chat.

## 20.2 — Generated-file gallery and adjacent preview

**Foundation:** Library currently contains conversations and task reports, not a produced-file catalog.

- Add a schema-versioned artifact index: ID, originating conversation/run/specialist, display name,
  validated file reference, media type, creation/update date and availability state.
- Register files from confirmed tool results, not a path invented in model prose. Distinguish input
  attachments from generated output. Keep screenshots and temporary captures memory-only.
- Start with text/Markdown, images and PDFs; provide native Open for unsupported types. Previews treat
  files as untrusted data and never execute embedded scripts, macros, shell content or remote resources.
- Add a Files category, search, sort, grid/list display and an optional preview beside chat. Support Open,
  Reveal in Finder, drag-out and removal from the index. Deleting the actual file is a separate confirmed
  operation; removing its card never deletes it implicitly.
- Put Ivy-generated durable outputs in a managed artifacts folder. External output references retain
  their explicit path permissions; deny restricted/private paths and handle missing/moved files honestly.
- Scope results by run: a reply producing no file cannot show an older output as its new result.

**Acceptance:** a completed fixture task produces a real previewable file; actions reference that same
file; missing/corrupt/unsupported files show useful states; exports/indexes contain no credentials;
existing conversations, task reports and archived filters still work.

## 20.3 — Recurring tasks

**Foundation:** ProactiveEngine schedules notifications/briefings. ProactiveTrigger never runs tools.

- Add a separate routine store/executor. Preserve the reminder path and its “notify only” contract.
- A routine records goal, schedule/time zone, explicitly allowed read sources, destination context,
  enabled state, next run, last outcome, failure count and bounded execution budget.
- Support daily, selected weekdays and bounded intervals first. Show New routine, upcoming runs,
  history, Pause, Resume, Run now and Delete in Tasks. Creating/changing a routine requires review.
- First scheduled execution can read permitted sources, summarize/research within granted scope and
  prepare a report/draft. Sending, deleting, publishing, changing files outside managed result storage,
  or other risky tool actions enter **Waiting for approval** and never auto-run from a schedule.
- Desktop clicks, typing and screen capture are not unattended routine capabilities. The user must start
  a new live Phase 19 session to continue such work; saved consent is not reusable desktop authorization.
- Run only while Ivy is open. Catch up at most once after sleep/offline periods; recompute dates on time
  zone/DST changes. Keep one execution lane initially; manual tasks take priority and due routines wait.
- Track scheduled occurrence IDs atomically to prevent duplicate starts. A crash with an uncertain result
  pauses that occurrence for review instead of replaying side effects. Pause after three real consecutive
  execution failures with a reason; waiting for approval or connectivity does not count as a failure.
- Archiving/deleting the owning assistant stops its routines. Routine completion is an unread result,
  respecting existing quiet hours and notification limits rather than a burst of spoken announcements.

**Acceptance:** virtual-clock tests cover DST, sleep, offline, deduplication, queueing and failure pauses;
no existing reminder reaches a tool executor; denied approval cannot be retried automatically; Run now
uses the same scope/budget; disabling a routine prevents future starts and offers Stop for its current run.

## 20.4 — Dictation anywhere

**Dependency:** Phase 19's focus-checked keyboard/text driver and existing voice-capture infrastructure.

- Introduce a distinct Dictate mode and configurable shortcut. Hold to speak, release to transcribe,
  preview/confirm the destination on first use, then insert text into the verified focused editor.
- Do not send the utterance to normal chat/task routing or produce an assistant answer in this mode.
- Support verbatim text and optional punctuation cleanup; cleanup must not execute spoken instructions.
- Capture only while held. Release closes the microphone even while transcription is processing;
  cancellation, silence, device change and network failure cannot leave it recording or insert partial text.
- Bind transcript to the original app/window/field. If focus changes, offer a preview to copy or retry;
  do not paste into the new app. Never write a password/secure field, auto-send a message or press Return
  to submit. Replacing a selection requires explicit intent/review.
- Resolve conflicts with PTT/wake shortcuts; support a button alternative. Use native permission recovery
  and indicate any cloud transcription. Never silently enable always-on listening or use the clipboard.

**Acceptance:** fake audio/transcript tests prove exactly one insertion and no insertion after cancel;
manual TextEdit and browser-input checks cover multiline/Unicode text, changed focus, denied permissions,
AirPods/device changes and release while processing. Ordinary conversational PTT still answers normally.

## 20.5 — Specialist assistants

**Foundation:** conversations, custom instructions, personalization and explicitly approved memory.

- Add an assistant profile with stable ID, name, role/instructions, linked conversations, optional
  scoped workspace, approved memory and associated routine/artifact IDs.
- Provide Create/Edit/Archive/Delete, with initial templates for coding, studying and writing. A
  conversational creation flow drafts the profile for review; it does not create tools or permissions.
- Isolate role memory and conversation context by assistant. Global preferences remain separately
  identified; sharing a file/fact/context with another specialist is explicit and inspectable.
- Route chat/voice requests by explicit assistant identity or the selected assistant. Ambiguous requests
  ask which one; no silent cross-context routing. Display which assistant owns each task/result.
- Profiles cannot modify safety policy, approve actions, grant account access or expand file/app scope.
  Start with the existing single execution lane; multiple profiles do not imply simultaneous Mac control.
- Migrate existing conversations to a default Ivy profile without deleting history. Deletion separately
  explains whether associated chats/files will be kept; it cannot silently delete durable output.

**Acceptance:** profile/context/memory isolation tests, backward-compatible decoding, ambiguous-routing
tests and archive/routine shutdown tests pass. A coding assistant cannot retrieve a writing assistant's
private context merely because model output requests it.

## 20.6 — Compact notch/menu-bar overview

**Dependency:** shared task panel, artifact index and specialist summaries; use only real data.

- Add an optional compact overview of active tasks, pinned assistants, recent conversations and latest
  file results, with quick Open/Reveal/Continue actions and unread/status indicators.
- Keep the menu-bar version available on every supported display. A notch-attached variant is optional;
  do not assume all Macs or external displays have a notch or replace the existing app/window entry points.
- Provide click and keyboard activation; hover can reveal the overview but is not its only access method.
  Avoid activating another app, capturing its screen or starting work just because the pointer enters.
- Remember appropriate panel position/size, clamp to usable screen bounds, dismiss predictably and keep
  ongoing task state intact. Apply user-selected visibility, quiet mode and accessibility preferences.

**Acceptance:** no-notch/external-screen, full-screen, small-window and multi-display fixtures pass;
opening/closing does not restart work; card actions reach the correct chat/run/file; CPU remains low
when hidden and state updates do not cause panel growth or steal keyboard focus.

## 20.7 — Step-by-step walkthroughs

**Dependency:** existing annotations plus Phase 19 observation, target freshness and cancellation.

- Keep a separate **Guide me** mode: Ivy explains, highlights a target and waits for the user's action.
  It cannot inject a click/key simply because the displayed instruction says to do so.
- Represent the goal, current step, expected result and user-facing progress. Provide Next, Repeat,
  Back, Finish and Stop; Back revisits guidance and never undoes an action automatically.
- Advance only after a scoped observation verifies the expected state or the user explicitly chooses
  Next. Optional click detection is a hint, not proof of task completion, and is bound to this session.
- The user explicitly starts a window-scoped guidance session that explains repeated observations.
  No continuous desktop polling outside it. Pause captures while waiting for unrelated work; never reuse
  a screenshot across moved windows or steps without revalidation.
- If an app looks different, reobserve and explain the change. Bound replans and stop if uncertain.
  Switching from Guide me to Do it requires a fresh Phase 19 control-session review.

**Acceptance:** fake walkthroughs handle wrong clicks, changed UI, stale images and missing controls;
Guide me emits zero synthetic input; Stop clears all arrows and observations; keyboard/VoiceOver users
can progress without relying on a visual arrow or physical click detection.

## 20.8 — App connectors and multiple accounts

**New foundation:** connector registry, authenticated transports, capability mapping and account scope.

- First support explicitly configured remote MCP servers, then reviewed local-command connections.
  Add direct service adapters only for integrations with supported APIs/authentication and tested scopes.
  Gmail/Google Docs are candidate adapters; copied skill guides do not constitute working integrations.
- Define a transport/version contract against the official protocol at implementation time. Prefer
  native Foundation networking; any proposed SDK/dependency needs the repository's required approval.
- Support browser-based authorization where the server/service provides it and Keychain-backed API
  credentials where supported. Use supported secure OAuth flows, minimal scopes and redacted diagnostics.
  Use each service's supported configuration; never place tokens in settings/history/prompts.
- Each account has its own stable ID, connection, Keychain references, granted scopes and Work/Personal
  label. Show Checking, Connected, Needs sign-in and Disconnected based on actual credential checks.
- Require an account ID on tool dispatch. Ask when multiple accounts fit the request; never quietly fall
  back to another account after authorization fails. Disconnect revokes/removes the relevant credentials
  and invalidates pending work without affecting another account.
- Treat server tool metadata, output and embedded instructions as untrusted. Server “read-only” hints
  do not independently determine safety. Local code validates allowed tools/accounts and retains exact
  confirmations for mutations, including send/delete/publish. Start unfamiliar tools conservatively.
- Confirm local executable/arguments before launch; avoid shell interpolation, bound output/timeouts
  and stop owned processes on disconnect. Never allow model text to install or start a connector.
- Expose connected capabilities consistently to chat, approved routine scopes and specialists. No
  background mailbox/document polling until the user explicitly enables a scoped routine using it.

**Acceptance:** fake transport/auth tests cover expired tokens, timeouts, malformed tool schemas, malicious
output, refresh and disconnect. Work/Personal account isolation, exact-action approvals, credential
redaction and process teardown pass before real service tests with explicitly authorized test accounts.

## Shared data, execution and UI rules

- Use schema-versioned stores for artifacts, routines, assistants and connector metadata, with atomic
  writes and corrupt-store recovery. Migrate old conversations/tasks without losing data; keep backups.
- Keep account secrets in Keychain. Never persist screenshots, raw audio/AX trees, passwords or control
  authorization tokens in new stores, exports or task arguments. Preserve existing attachment privacy.
- One task/approval owner controls the execution lane. Queue identity, assistant ID, run ID and account
  ID survive UI navigation; stale UI callbacks cannot act on newer work. Model/network responses after
  cancellation are discarded, except native input cleanup already specified in Phase 19.
- Defaults remain opt-in. Creating this roadmap does not enable routines, connectors, dictation or
  screen sessions. Asking for a feature in development does not grant its eventual runtime permissions.
- Completion sounds and speech are optional and respect quiet hours; explicit Stop/error/approval status
  stays visible. Use original Ivy branding, artwork and sounds.

## Tests, manual checks and release

Each slice has its own meaningful offline unit tests, native UI fixtures and clean strict Swift 6 build.
Use fake clocks, task stores, files, input drivers, voice transcripts and connector transports. No real
network, microphone, Accessibility/TCC changes or user-account side effects in the ordinary unit suite.

Apply `CONSTRAINTS.md`: ≥80% changed-line coverage, full offline suite <60 seconds, warmed incremental
build <5 seconds, zero warnings/errors/secrets/stubs/swallowed errors. Manual service/hardware evaluation
is separate and uses authorized test accounts and disposable files. Do not weaken thresholds to ship.

- [ ] Panel state, Stop and task-bound follow-up work without opening the main window.
- [ ] Generated files preview/open/reveal/drag correctly; missing files and removal are handled honestly.
- [ ] A daily read-only routine produces a real report, survives sleep and pauses after repeated failures.
- [ ] A routine requiring a mutation waits for confirmation; reminder-only behavior stays unchanged.
- [ ] Dictation inserts once into the selected field; focus change/cancellation never inserts elsewhere.
- [ ] Coding/studying/writing profiles preserve separate context and approved memory.
- [ ] Overview works with/without a notch and on external displays without stealing focus.
- [ ] Guide me highlights real controls and performs no input; switching to control asks explicitly.
- [ ] Two accounts on a test connector never mix results or permissions; disconnect stops pending work.
- [ ] Existing PTT, tool cards, archive, file tools, migrations and native accessibility modes still pass.
- [ ] Docs/changelog and measured limitations match the milestone; preserve previous DMGs when packaging.

Update status after each completed slice. Package milestone builds only after their checks pass; choose
version/build numbers then. Do not mark all eight features complete because the UI has placeholder cards.
No GitHub publishing, new release tag, paid service enrollment or notarization happens as part of planning.

## Implementation guidance

The [UI refresh report](../../tasks/ui-refresh.md) records existing Ivy foundations and verification.
Build these capabilities within Ivy with its own assets, configuration and service credentials. Preserve
any required third-party license notices if source is reused in future implementation.
