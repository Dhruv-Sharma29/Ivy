# Phase 20 — Assistant Workspace

Status: **partial source implementation; all fifteen complete workstreams remain open**.
Expanded 2026-10-04 at the user's request. The optional floating-pointer visual/preferences slice of
20.14 is implemented and included in the latest local app/DMG rebuild; anchored arrows and the broader
workspace remain pending. See the [UI report](../../tasks/ui-refresh.md) for verification and limitations.
The initial 20.12 screen-question slice is implemented and packaged locally: bounded hover/freehand/rectangle crops,
typed review, and a shared voice shortcut with image-before-speech submission. This does not complete
20.12's richer selection, target-freshness and device acceptance requirements.
This extends [Phase 19 — Computer Control](phase-19-computer-control.md) with the full personal-assistant
workspace plan. Existing voice, memory, screen pointers and companion approvals are foundations;
they do not mean these expanded capabilities are complete.
It does not implement features, connect accounts or authorize runtime actions.

## Goal and scope

Make Ivy useful from anywhere on the Mac: follow tasks in a small panel, inspect produced files, schedule
repeat work, choose specialist assistants, dictate into other apps, open a compact overview, follow screen
walkthroughs and connect external tools/accounts. Interview the user to create assistants around their
goals, offer useful daily suggestions, run independent jobs concurrently and retain follow-up context.
Support selected-region questions, richer screen drawing and companion arrows tied to real targets.

Keep Ivy's native visual language, existing chat/library/tasks and single approval surface. Reuse current
voice, memory, tool cards, screen annotations and task engine. These are additions to existing foundations,
with existing behavior preserved. The user authorizes a complete UI restructuring where needed for the
notch/Home experience and these capabilities; preserve data, task/voice behavior and approval safeguards
through migration rather than limiting the design to cosmetic edits. Windows and server-side unattended
agents remain outside scope.

Read `CONSTRAINTS.md`, `SPEC.md` and relevant Phases 9–17 before implementing. Update the master spec for
each implemented milestone. Do not relax existing safety, privacy, dependency or strict-concurrency rules.

## Ivy's own interface — design requirement

Updated 2026-10-04: references inform capabilities and interaction behavior; Ivy must have its own
recognizable interface. This applies even when a milestone requires a complete UI restructuring.

- **Identity:** retain Ivy's paired-leaf branding, graphite/white adaptive surfaces and muted indigo
  accent. Use original leaf-derived guidance marks, consistent system typography and Ivy-owned artwork.
  The pixel companion remains Ivy's character; specialist identity uses distinct leaf/role symbols
  and readable names instead of borrowing another product's avatars, illustrations or sound cues.
- **Workspace:** organize Home around the user's work: Continue, active task and recent results. Keep
  conversation history, Library and Tasks recognizable. Specialists become a context selector with
  explicit memory scope; they do not require a matching avatar sidebar or identical starter-card grid.
- **Compact overview:** the notch is an Ivy status strip with a leaf, actual state and task count.
  Peek expands into a focused current-task/result summary; opening Home is an explicit action. Use
  the same information hierarchy in the menu-bar fallback. Design dimensions and transitions for
  Ivy's content and accessibility, without tracing reference screenshots or copying their row order.
- **Floating surfaces:** the companion keeps compact reason + Cancel / Do it approvals; the task panel
  shows actual goal, step and Stop. File previews, follow-ups and task status share Ivy's surfaces and
  spacing. Each surface has a defined purpose rather than recreating an entire reference window.
- **Voice and pointer:** preserve conversational hold/release semantics and Ivy's keyboard conventions.
  Use an original folded-leaf pointer with optional color choices, clear mode/state and click-through
  behavior. Settings follow Ivy's native grouped cards, labels and search rather than reference layouts.
- **Copy and assets:** write original Ivy labels, prompts, empty states and onboarding. No borrowed
  marketing language, product names, commercial/account screens or reference assets in the interface
  or user documentation. Required third-party license attribution remains intact if code is reused.

**Design acceptance for every milestone:** review the feature beside existing Ivy Home, Settings,
companion and chat in both appearances. It must share Ivy's typography, spacing, controls and leaf
identity, while meeting the behavior requirement independently of the reference composition. Use
native Mac conventions where appropriate; familiar controls are welcome, copied branded layouts are
not. Record a preview and the reason for major layout choices before treating a UI slice as complete.

## Coverage of the requested capabilities

The two requested lists overlap. This matrix combines them without dropping a capability.

| Capability | Planned slices | Existing foundation; remaining work |
| --- | --- | --- |
| Real cursor control: click, type, scroll, drag and work inside apps | 19.1–19.9 | Native tools and screen capture exist; general input, adaptive control and verified browser workflows are new. |
| Screen-aware dictation into the focused app | 20.4 | Conversational PTT exists; separate transcription/insertion and optional focused-screen context are new. |
| Interactive walkthroughs with step tracking | 20.7 | Pointing exists; expected-state verification, progression and recovery are new. |
| Generated-file gallery, previews, Open/Reveal and drag-out | 20.2 | Library has conversations/reports; a real output-file index is new. |
| Floating task panel with live progress | 20.1 | Task progress and companion approval exist; a shared run panel is new. |
| Follow-up conversations with finished agents | 20.1, 20.5, 20.11 | Chats persist; completed-run continuations with explicit assistant ownership are new. |
| Routines that execute recurring work | 20.3 | Notifications/briefings exist; scheduled task execution, controls and recovery are new. |
| Connectors and account selection | 20.8 | Local tools exist; authenticated external transports and account isolation are new. |
| Specialist coding, research, writing and studying assistants | 20.5 | Instructions/profile/memory exist; separate assistant ownership and routing are new. |
| Personal agent creation through an interview | 20.9 | New goal interview, profile proposals and reviewed multi-assistant creation. |
| Daily suggestions from goals, integrations and memory | 20.10 | New opt-in suggestion generation, review, dismissal and deduplication. |
| Concurrent work with separate results | 20.11 | Existing execution is serial; bounded independent research/draft workers are new. |
| Spatial context: hold a shortcut, circle a region and ask | 20.12 | Region capture exists; a lasso gesture bound to a question and fresh image is new. |
| Screen drawing: polygons, arrows and curved lines | 20.13 | Rectangular highlights/arrows exist; validated geometry and drawing lifecycle are new. |
| Floating Home/notch and compact menu-bar overview | 20.6 | Existing menu and companion remain; task/assistant/suggestion/file overview is new. |
| Memory and personalization | 20.5, 20.9, 20.10 | Existing preferences/memory remain; goal records, specialist scope and inspectable sharing are new. |
| Companion arrows anchored to cursor and highlighted region | 20.14 | Current arrows start at a screen edge; fresh cursor/companion anchors are new. |
| Native Mac polish | 20.15, every milestone | Existing native styling, shortcuts, animation and compact approvals remain; new surfaces receive matching behavior. |

## Combined build order

| Milestone | Work | Result |
| --- | --- | --- |
| A — control foundation | 19.1–19.4 with 20.1 | Reviewed Calculator/TextEdit control and one shared floating task panel. |
| B — useful results | 20.2, then 20.3 | File gallery/previews, followed by repeatable read-only tasks and routine controls. |
| C — adaptive work and dictation | 19.5–19.6, then 20.4 | Verified computer-use loop plus a separate dictation mode using the same input driver. |
| D — personal assistants | 20.5, then 20.9 | Separate role memory, goals, a user interview and reviewed creation of several assistants. |
| E — spatial guidance and advanced control | 20.12–20.14, 20.7 alongside 19.7–19.9 | Region questions, drawing, anchored arrows, tracked walkthroughs, browser control and dragging. |
| F — connected tools | 20.8 | Custom connectors, email/calendar/browser-service adapters, named accounts and explicit permissions. |
| G — proactive and concurrent work | 20.11, then 20.10 | Independent bounded workers, resumable follow-ups and personalized suggestions from authorized sources. |
| H — compact Home and polish | 20.6 with 20.15 | Overview of real assistants, suggestions, tasks and files; native interaction/accessibility review. |
| Release checkpoints | 19.10 and the validation gates below | Tested milestone builds; later optional features do not block packaging a finished milestone. |

The panel is implemented once, not separately for Phases 19 and 20. The priority within workspace work
remains floating task panel → generated-file gallery → recurring task controls. Specialist profiles precede
interviews and concurrent workers; connectors precede integration-based suggestions. Local-only suggestions
may be delivered earlier using explicitly approved goals and memory. Native polish is checked throughout,
with a final review after all new surfaces exist. Milestones do not imply fixed dates or release versions.

## 20.1 — Floating task panel

**Foundation:** existing task state, tool cards, Command Bar and the planned Phase 19 control panel.

- Present a compact, non-activating panel with goal, current step/status, task age, Open in Ivy and Stop.
  Add Pause/Resume only where the execution state supports them; do not fake a paused operation.
- Reuse the existing confirmation sheet. The panel can show “Needs approval” and open the request;
  it cannot independently approve it or create a second confirmation queue.
- Follow-up text/voice is bound to the displayed run. Completed runs accept a continuation as a new
  reviewed task. A running task queues follow-ups for a safe checkpoint; never silently changes an
  in-flight action or starts another control session.
- Finished-agent conversations retain the original assistant, run summary and artifact references.
  Continue opens that context; follow-ups create linked child runs with their own scope and approvals.
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

## 20.4 — Screen-aware dictation anywhere

**Dependency:** Phase 19's focus-checked keyboard/text driver and existing voice-capture infrastructure.

- Introduce a distinct Dictate mode and configurable shortcut. Hold to speak, release to transcribe,
  preview/confirm the destination on first use, then insert text into the verified focused editor.
- Do not send the utterance to normal chat/task routing or produce an assistant answer in this mode.
- Support verbatim text and optional punctuation cleanup; cleanup must not execute spoken instructions.
- Offer an explicit screen-aware option: read a bounded description of the focused app/editor and user-selected
  text, with a scoped image only when needed and permitted. Use this context for names, terminology and
  formatting, not to invent spoken content. Show which app receives the transcript and whether screen
  context/cloud processing is enabled. No unrelated windows, background polling or retained captures.
- Distinguish plain transcription from contextual cleanup. If context is unavailable, report that and
  offer ordinary dictation; changing the screen cannot change the destination field or authorize a tool.
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
Secure fields exclude both capture and insertion; screen-aware mode only reads the permitted target.
Tests cover unavailable/stale screen context, proper-name correction and unchanged verbatim output.

## 20.5 — Specialist assistants

**Foundation:** conversations, custom instructions, personalization and explicitly approved memory.

- Add an assistant profile with stable ID, name, role/instructions, linked conversations, optional
  scoped workspace, approved memory, reviewed goal IDs and associated routine/artifact IDs.
- Provide Create/Edit/Archive/Delete, with initial templates for coding, research, studying and writing. A
  conversational creation flow drafts the profile for review; it does not create tools or permissions.
- Isolate role memory and conversation context by assistant. Global preferences remain separately
  identified; sharing a file/fact/context with another specialist is explicit and inspectable.
- Track goals, tone, preferences and project context with provenance and Global/Assistant/Project scope.
  Show what is remembered, where it came from and which assistant can use it. Offer edit, forget and
  explicit sharing; forgetting invalidates cached derived context and future suggestion inputs.
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

The [supplied-media review](../../tasks/interface-reference-review.md) adds explicit collapsed,
hover-peek and expanded Home states, an assistant avatar list and an expand action. The peek must use
real owned data; keep hover configurable and the equivalent menu-bar entry on displays without a notch.

**Dependency:** shared task panel, artifact index and specialist summaries; use only real data.

- Add an optional compact overview of active tasks, pinned assistants, recent conversations and latest
  file results, with quick Open/Reveal/Continue actions and unread/status indicators.
- Include a small Home/peek view with pinned assistants, reviewed daily suggestions, live task cards
  and recent output files. Actions select the owning assistant/run/account instead of a generic chat.
- Keep the menu-bar version available on every supported display. Include a notch-attached presentation
  on compatible built-in displays after geometry checks;
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
  Prioritize Gmail, calendars and browser/research services, followed by document services. Inventory each
  adapter's supported read/draft/write operations and accounts before implementation; document required
  provider configuration, actual pricing and unavailable scopes rather than promising universal access.
  Browser-service integration and native browser clicking are separate capabilities.
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

## 20.9 — Goal interview and personal agent creation

**Dependency:** 20.5 profiles and approved memory; 20.8 only for connected-source proposals.

- Offer Create my assistants: a short conversational interview about goals, projects, preferred help,
  tone, cadence and available integrations. Support voice/text, skip, edit, save a draft and resume.
- Produce a reviewable proposal for several distinct assistants: name, job, instructions, relevant goals,
  context/memory scope, proposed accounts and optional routine ideas. Explain overlap rather than creating
  duplicate roles. The user can edit, remove or create selected proposals in one reviewed operation.
- Creating a profile does not connect an account, enable a routine, grant computer control or start work.
  Review those separately when used. Interview answers enter durable memory only with explicit review.
- Save draft progress with schema/version and identity; commit profiles atomically or report a recoverable
  partial creation. Retrying cannot create duplicate assistants. Archive/forget removes future use.

**Acceptance:** an offline interview creates distinct coding/research/writing profiles only after review;
cancel creates none, retry creates no duplicates, skipped answers are not fabricated, context stays isolated,
and creation emits zero tool actions/account authorization requests or scheduled jobs.

## 20.10 — Personalized daily suggestions

**Dependency:** 20.5/20.9 goals and memory, 20.3 scheduling, 20.8 for explicitly connected sources.

- Opt-in daily generation proposes useful work from reviewed goals, assistant/project context and the
  accounts/sources the user selected. Show proposal, reason, assistant, inputs, expected result and age.
  Local-only suggestions must work without connectors. Suggestions are proposals, not started tasks.
- Provide Start, Edit, Later and Dismiss. Voice/text can select and accept a suggestion to draft/start
  its reviewed task. Accepting a suggestion never answers a separate risky-action confirmation;
  existing SafetyGate approval still requires its explicit confirmation controls.
- Deduplicate by goal/source/occurrence and honor dismissed topics, quiet hours, user cadence and a
  small daily limit. No invented urgency, claimed account reads without access, or repeated unsolicited
  speech. Expired source context must be refreshed before execution or reported as unavailable.
- Store bounded suggestion metadata/provenance, not raw mailbox dumps or screenshots. Stop generation
  and invalidate affected proposals when sources are disconnected or their memory/goal is forgotten.

**Acceptance:** fake-clock/source fixtures generate relevant proposals with inspectable reasons; accepting
one starts exactly one correctly scoped task; dismiss/snooze/expiry/disconnect work; malicious source
instructions and spoken acceptance cannot approve a risky tool. Disabled suggestions do no background work.

## 20.11 — Concurrent work and task continuation

**Dependency:** 20.1 run UI, 20.2 outputs and 20.5 assistant ownership; 20.8 for connected jobs.

- Add a coordinator for independent read/research/draft workers with a configurable small concurrency
  limit (start at two), per-run budgets and a shared aggregate request/cost limit. Queue excess work,
  honor provider limits and surface per-job progress, failure, waiting and cancellation honestly.
- Bind every worker to assistant, conversation, run, authorized source/account and output destination.
  Workers receive only their scoped context. A combined summary cites each contributing result and
  does not mark failed/cancelled branches complete or silently transfer their private context.
- Desktop input uses one exclusive lane across all workers; serialize focus-changing actions and
  shared-file mutations. A task waiting for input or approval shows that state. Independent authorized
  read-only jobs can continue while another waits; they cannot answer its request or take its screen scope.
- Queue exact, identity-bound confirmations through one approval owner. Never stack dialogs or let a
  worker's response approve another job. Stop one cancels only its work; Stop all releases all owned
  input/resources and prevents late results from being applied to new jobs.
- Finished workers remain conversational: Continue creates a linked follow-up run using the same
  assistant and selected result context. Changed goals/accounts/scope are reviewed before execution.
  Persist summaries/results and queue metadata, never live authorization; relaunch shows interrupted work
  for review rather than automatically resuming input or uncertain side effects.

**Acceptance:** two independent fixtures finish concurrently with separate histories/files; configured
limits and shared budgets hold; shared resource conflicts serialize; one failed/blocked worker does not
falsely fail/succeed another; stale approvals, late results and Stop all cannot emit new actions.

## 20.12 — Spatial questions from a circled region

**Initial packaged slice:** shared ⌘⇧Space voice shortcut, configurable R/A typed selection shortcuts,
menu selection, hover/freehand/rectangle bounding crops, keyboard hover positioning and Esc cancellation.
The dashed crop bounds show included pixels. ScreenCaptureKit selected crops stay in memory and exclude
Ivy/protected apps; existing redaction/limits apply. Voice speech stays buffered until the microphone closes
and the crop is sent first; silence/capture failure sends no speech. Typed crops appear in Quick chat.
Real mixed-scale hardware acceptance, exact polygon masking, arbitrary shortcut assignment and
freshness checks at typed submission remain open; screenshots are snapshots, not control authorization.

**Dependency:** existing region capture and Phase 19 observation/coordinate freshness.

- Provide a configurable hold shortcut plus a visible Select region button. While held, show a temporary
  selection surface; draw a circle/freehand lasso or use a rectangular/keyboard-accessible alternative.
  On release, preview the selected region with a text/voice question; do not auto-send an empty question.
- Bind question, crop, image ID, app/window, display transform and capture time. Send only the selected
  context after the user's submission. Mark the shape as selection, not an instruction to click or draw.
- Cancel/Escape removes the selector and capture; changing app/display/window before submission asks
  for a fresh capture. Screen permission denial and protected windows get existing recovery UI.
- Screenshots and lasso geometry remain session-only. Avoid conflicts with PTT, screen attachment and
  control shortcuts; cancel selection before starting a desktop input session.

**Acceptance:** circle a chart/control on mixed-scale displays and ask about that crop; correct IDs and
coordinates survive submission; cancel/silence/stale targets send nothing; keyboard users can select;
ordinary overlays remain click-through after the explicit selector closes.

## 20.13 — Rich screen drawing

**Dependency:** annotation/capture mapping, 20.12 spatial references and shared run/step identity.
Walkthroughs in 20.7 integrate these shapes once the renderer is ready.

- Extend the annotation model with polygons, straight arrows, curved paths and labels, bound to a fresh
  image/window/display and owning run/step. Validate finite coordinates, bounds, point counts, text sizes
  and duration before rendering. Treat model-provided shapes as data, never executable instructions.
- Use Ivy's style with legible strokes, optional drawing animation and static Reduce Motion alternatives.
  Show the related explanation in accessible text; shape/color alone cannot carry the instruction.
- Keep explanatory drawings click-through; reserve pointer interception for explicit region selection.
  Clear/Repeat controls, expiry, step changes, Stop, hidden/moved targets and session teardown remove
  old shapes. Revalidate mapping before redraw rather than stretching an old capture to a new window.
- Support diagrams or tutorial emphasis without changing app content. Any drawing inside a document
  is a separate confirmed computer-control/file task, not an annotation operation.

**Acceptance:** polygon/arrow/curve fixtures map correctly across displays; invalid/oversized geometry
is rejected; text remains readable; overlays intercept no app input and clear on all teardown paths;
long walkthroughs do not accumulate windows, timers or stale shapes.

## 20.14 — Companion and cursor-anchored arrows

**Implemented slice (2026-10-04; packaged locally):** opt-in 32-point folded-leaf cursor companion,
Blue/Green/Amber/Red preferences in a searchable Pointer settings page, bounded following and
click-through non-activating presentation. Hide/master-disable, Reduce Motion, sleep/inactive session,
missing display geometry and app shutdown stop tracking. Existing installations remain opted out.
Native fixtures cover lifecycle and window policy; real multi-display/Spaces input checks remain manual.
Target-anchored arrows, task bubbles and emphasis events below are still pending.

The [supplied-media review](../../tasks/interface-reference-review.md) also specifies an optional
floating Ivy pointer separate from the OS cursor: bounded smooth following, color/Hide controls,
truthful emphasis rings and optional task-update bubbles. This visual can ship independently of the
computer-input driver; it cannot click, type or approve an action.

**Dependency:** 20.13 geometry plus fresh Phase 19 targets and measured companion placement.

- Support screen-edge, companion and cursor origins for the same target arrow. Use the current measured
  visible companion bounds or a cursor position sampled for this guidance step; never move the user's
  cursor just to create an animation. Clamp paths and keep labels clear of target controls and task UI.
- Recompute while the user explicitly drags the companion or a scoped target window moves; hide if the
  target can no longer be validated. Cursor following is optional, bounded and active only during a
  guidance/control session or explicitly enabled, visible companion-follow mode. Hide/disable and
  teardown stop tracking; idle hidden UI never performs persistent mouse tracking.
- Separate pointing from execution: the arrow explains the next action and cannot click or approve it.
  Provide a stable screen-edge fallback if the companion is hidden or on another display; accessible
  text always identifies the target. Reduce Motion uses a static path and avoids a chasing animation.

**Acceptance:** cursor/companion/edge anchors resolve to the same verified region without moving input;
dragging across displays, hidden companion, changed scale and stale targets produce correct redraw or
fallback; Stop clears the arrow and tracking; idle/hidden states perform no continuous cursor polling.

## 20.15 — Native Mac polish and integration

**Applies at every milestone; final review after the new surfaces exist.**

- Apply the [supplied-media requirements](../../tasks/interface-reference-review.md): collapsible
  assistant rail, clear voice/text entry, provider-backed voice previews, real microphone selection
  with a bounded level test, grouped shortcut controls and recording-visibility preferences with
  accurate limits. Unsupported options are not presented as functioning settings.

- Keep Ivy branding/assets, restrained native typography/materials and the compact action-title,
  Cancel / Do it confirmation with the original request available on hover. Reuse the same pending request across surfaces.
- Give task/overview/preview panels deliberate drag areas, remembered reachable positions and consistent
  close/reopen behavior. Interactive controls must never start panel dragging or steal another app's focus.
- Provide discoverable configurable shortcuts and button/menu alternatives, visible press/hover/status
  feedback and useful waiting/error states. Motion communicates actual work, respects Reduce Motion and
  stops while hidden; never display fabricated progress, files, account status or agent activity.
- Validate VoiceOver, keyboard navigation, contrast, Reduce Transparency, small windows, multiple Spaces,
  no-notch screens and mixed-scale displays. Keep existing composer, archive, PTT and approval behavior.

**Acceptance:** native fixtures and manual checks cover every new surface; all controls remain reachable;
hidden panels stop animation/observation; focus/input ownership and required quality/performance gates pass.

## Shared data, execution and UI rules

- Use schema-versioned stores for artifacts, routines, assistants and connector metadata, with atomic
  writes and corrupt-store recovery. Migrate old conversations/tasks without losing data; keep backups.
- Keep account secrets in Keychain. Never persist screenshots, raw audio/AX trees, passwords or control
  authorization tokens in new stores, exports or task arguments. Preserve existing attachment privacy.
- Until 20.11 is validated, retain one execution lane. Afterward independent scoped workers share a
  coordinator, one exclusive desktop-input lane and one approval owner. Queue identity, assistant ID, run ID and account
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
- [ ] A resumable interview proposes several assistants; creation/memory review is explicit and duplicate-free.
- [ ] Daily suggestions respect sources, dismissals and quiet hours; voice/text task acceptance never approves a risky tool.
- [ ] Concurrent research/draft workers keep histories, budgets and files separate; desktop input remains serialized.
- [ ] A finished assistant accepts a linked follow-up without losing context or reusing live control consent.
- [ ] Circled-region questions attach the exact crop; polygons/curves/arrows stay click-through and clear on Stop.
- [ ] Companion/cursor arrows use fresh targets and stop tracking when guidance ends.
- [ ] Compact Home shows actual suggestions, assistants, tasks and recent files on notch and no-notch displays.
- [ ] Existing PTT, tool cards, archive, file tools, migrations and native accessibility modes still pass.
- [ ] Docs/changelog and measured limitations match the milestone; preserve previous DMGs when packaging.

Update status after each completed slice. Package milestone builds only after their checks pass; choose
version/build numbers then. Do not mark a workstream complete because the UI has placeholder cards.
No GitHub publishing, new release tag, paid service enrollment or notarization happens as part of planning.

## Implementation guidance

The [UI refresh report](../../tasks/ui-refresh.md) records existing Ivy foundations and verification.
Build these capabilities within Ivy with its own assets, configuration and service credentials. Preserve
any required third-party license notices if source is reused in future implementation.
