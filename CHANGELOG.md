# Changelog

## Unreleased

- Local v1.1.0 build 24 lets the visible companion reach the usable screen's top edge.
  AppKit no longer reserves the transparent panel margin above Ivy; existing visible-content
  placement keeps captions and approvals onscreen. Adds native regression tests and the phased
  reliability/model-readiness delivery plan.

- Local v1.1.0 build 23 displays a specific purpose on companion script/command approvals instead
  of generic execution titles. Model tool declarations require a short reason; older calls remain
  compatible with neutral fallback text. The app retains the technical title and complete payload.
  Purpose text is normalized/redacted and never approves execution. Bubble layout is unchanged.

- Local v1.1.0 build 22 restores push-to-talk recognition by disabling server automatic VAD for
  fresh PTT connections and sending explicit activity-start/end markers around the audio.
  Duplicate/silent release cannot create extra turns; reconnects retain the selected input mode.
  Existing hands-free input, tool approvals, interruption and retry deadlines remain.

- Local v1.1.0 build 21 switches Live conversation and push-to-talk to Google’s commercial Tavi
  voice (`en-us-tavi`). Gemini 3.8 Live is required: the old 3.1 model rejects this voice. Initial
  connections and reconnects retain the voice; Live tools explicitly use blocking behavior to
  preserve approval and result ordering. REST tools and optional ElevenLabs Read Aloud are unchanged.

- Local v1.1.0 build 18 replaces the Personalization personality and answer-length segments with
  explanatory option cards, selected checkmarks and adaptive stacking. Existing profile values,
  persistence, keyboard selection and prompt behavior are preserved. Companion UI is unchanged.

- Local v1.1.0 build 17 recovers stalled voice turns: 8 seconds without confirmation of a PTT request,
  or 15 seconds without model reply progress, closes the stale voice session with a retry notice.
  Reply content renews the deadline. Pending approvals, running tools and completed generation
  playback are excluded; stale deadlines are cancelled on interruption, reconnect and shutdown.
  Executed actions are never automatically replayed.

- Local v1.1.0 build 16 separates detailed workspace approvals from the compact companion card.
  The app shows the original explanation and selectable action details in a scrollable review area,
  with pinned Cancel / Do it controls. Long requests fit the minimum window; explicit approval,
  cancellation and request identity guards remain intact. Companion UI is unchanged.

- Local v1.1.0 build 15 refines companion text: compact 228×88-point approval bubbles, equal-width
  28-point decision controls, readable inactive-window text, larger left-aligned speech captions and
  clearer status type. Adaptive opaque surfaces prevent wallpaper colour washout; approval identity,
  shortcuts and drag routing are unchanged.

- Local v1.1.0 build 14 refreshes Live conversation preferences with explanatory option cards,
  subtle selection tint, checkmarks, hover/press feedback, narrow-window stacking and arrow-key
  navigation. Existing saved voice values and restart guidance are retained.

- Local v1.1.0 build 13 fixes disabled New task buttons and starter cards while voice/chat or another
  task is active. Preparing a draft preserves ongoing work and per-task follow-up drafts; sending
  waits for the current request to finish. Plan and tool approvals remain explicit.

- Local v1.1.0 build 12 adds Work in Background in the sidebar, File menu and menu bar. It hides
  the workspace while app-owned voice/chat/approved tasks continue, keeps the companion visible,
  and hands pending approval to the same companion card without answering it. Closing the workspace
  also enters background mode; suggestions do not reopen it. Open Ivy restores it; Quit still shuts down.

- Local v1.1.0 build 11 lets a new push-to-talk hold interrupt a pending or spoken reply and record
  a replacement question. It stops the old playback, retains interrupted transcripts, cancels pending
  approval, and isolates old socket/tool events. Release closes input and submits once; repeat,
  quick-release, explicit Stop and physical-release recovery retain their safety behavior.

- Local v1.1.0 build 10 adds a gentle blushing/clasped-hands idle animation with four original
  matching transparent sprites and a soft blink. It joins phone/laptop moments, lasts eight seconds,
  and yields to real activity, dragging, hiding and Reduce Motion. Dance frames remain unavailable.

- Local v1.1.0 build 9 removes companion dancing at the user's request. Idle selection now chooses
  only phone or laptop, and the retired dance frames are not cached or available to the sprite view.
  Quiet intervals, ordinary idle motion, real activity priority and Reduce Motion remain.

- Local v1.1.0 build 8 links tool/script cards to their triggering typed or voice request. Late voice
  transcripts no longer put a card above its question; fragments of the same request merge without
  changing its identity or initial timestamp. Missing/unsaved transcripts and legacy unlinked cards
  retain chronological placement. Card details remain session-only and redacted.

- Local v1.1.0 build 7 adds matching phone, laptop and dance idle sprites with randomly timed,
  brief activities and quiet pauses. Real activity, dragging, hiding and Reduce Motion take
  priority; returning to idle restarts the quiet interval. Idle props do not access any device or tool.

- Local v1.1.0 build 6: `open_app` resolves VS Code/vscode aliases to Visual Studio Code and handles
  `.app` suffixes case-insensitively. Insiders resolves separately; exact installed names take
  priority. Missing-app feedback explains extracted app placement without claiming a download
  or installation status that the lookup cannot determine.

- Local v1.1.0 build 5: Tasks now has its own goal composer and conversation. New task, starters and
  main-window `/agent` requests stay here. Plans and saved reports show connected execution flows
  with numbered steps, textual live status, dependencies and expandable redacted arguments/output.
  Follow-ups propose a new plan using bounded earlier goal/result/output context; saved parent links
  restore recent threads. Tasks-origin reports no longer append to an unrelated Chat conversation.
  Old task JSON remains compatible. Plan approval and per-action safety gates remain explicit.

- Local v1.1.0 build 4 fixes premature PTT release inference: unobserved keyboard state stays unknown
  until a key/modifier hold is verified. Carbon release remains authoritative, physical release recovery
  unlocks the next press, and later press notifications remain deliverable after Stop. Native notification
  and deterministic voice tests cover the race; physical cross-app key/audio acceptance remains pending.

- Local v1.1.0 build 3: push-to-talk offers ⌘⇧Space or ⌃⌥⌘Space, applies changes immediately and shows
  registration failures in General settings. Exclusive PTT registration detects shortcut ownership
  conflicts that non-exclusive registration can silently accept. An isolated two-process registration
  probe reproduced that failure and verified conflict detection/recovery without sending keyboard events.
  Changing a held shortcut closes the old capture. Cross-app physical key/audio acceptance remains pending.

- Removed the whole Pointer feature at the user's request: Settings page, floating cursor decoration,
  hover/circle/rectangle selection, selection shortcuts and image-before-voice callbacks. Existing
  saved preferences remain compatible; obsolete keys disappear on the next settings save.
- Global keyed shortcuts now receive Carbon events before application-level handlers can consume them.
  A native regression test reproduced the old routing failure and passes with the dispatcher fix.
  The push-to-talk setting updates registration immediately, including disabling a held press and retrying
  a failed registration. Live keyboard verification in another app remains a manual check.

- The workspace plan now requires Ivy's own task-first layouts, leaf/status notch overview, grouped
  settings, original icons/copy/assets and design review against existing Ivy surfaces at every milestone.

- Push-to-talk checks the physical shortcut while held, recovering a missed key-up without leaving
  Listening or the microphone active. Release preserves the pending reply/tool approval, and Stop
  resets the held state so another press works. Connection failures keep only the hold check until
  release to prevent repeat-driven reconnections; release and explicit Stop cancel it completely.

Local friend-testing package: **1.1.0 (build 2)**. The local `v1.1.0` tag remains the original build 1;
these follow-up changes have not been published to GitHub.

- Companion approval card: pending chat/task and Live tool requests show a small action title
  with **Cancel / Do it** in a 240×96-point bubble below the character, replacing the Needs approval
  status pill. The main-window confirmation is 280×100 points. Both show only the action reason and
  two buttons; hovering reveals the original request. These controls answer the same request as the
  main-window sheet; stale or repeated responses are ignored. The character remains draggable without
  intercepting review controls, and the panel grows and shrinks around its visible content.

- UI follow-up: compact branded Home and Command Bar headers, shared 20-point card corners,
  icon wells, roomier navigation and clearer group spacing across Home, Library, Tasks and Settings.
  Command Bar suggestions fill a draft; its new Send/Open/Close controls retain the existing safety checks.
  This initial UI refresh has passed layout checks; native glass still needs an in-app visual check.

- The local build-2 app/DMG was rebuilt on 2026-10-04 with these UI and PTT fixes using ad-hoc Hardened
  Runtime signing. The previous package is retained under `dist/Previous-Builds/`; no GitHub publication
  or notarization was performed. Real-keyboard verification remains a manual check.

- Screen guidance now instructs Ivy to inspect shared images and use `point_at` for visible UI targets,
  with fresh-capture guidance when no usable screen image is available.
- Chat and Live frames carry attachment IDs and actual image dimensions. Multiple shared captures retain
  separate desktop mappings; unknown IDs are rejected and non-screen images clear stale mappings.
- Screen Recording denial shows a readable explanation, Open Settings and an explicit Retry Capture action.
  Retrying attaches a fresh capture for review without sending it automatically.
- Annotation arrows animate from the display edge toward the target. Reduce Motion shows a stationary,
  complete arrow and disables the highlight pulse.

## 1.1.0 — 2026-10-03 (friend-testing build)

This release packages the implemented work from Phases 8–17. It is not a notarized public release;
phase acceptance checklists, second-Mac installation and hardware/performance checks remain open.

### Added

- **Phase 8 — Resilience:** request retry and quota handling, bounded context, content-free voice latency
  metrics, clean shutdown and diagnostic/crash support.
- **Phase 9 — Conversations:** local history, search, pins, archives, exports, per-chat instructions,
  optional titles and context summaries, with corrupt/future data recovery.
- **Phase 10 — Voice:** opt-in on-device wake listening, Live interruption, reconnect handling and
  configurable voice pacing/patience. Push-to-talk captures until release and stays connected for the reply.
- **Phase 11 — Mac tools:** grouped tools for everyday Mac services, permissions checked after action approval,
  and bounded tool responses. Available tools remain subject to their individual scopes and macOS access.
- **Phase 12 — Proactive assistance:** opt-in reminders, follow-ups, notifications and briefings.
- **Phase 13 — Personalization:** profile, tone, remembered preferences and prompt shortcuts.
- **Phase 14 — Screen help:** reviewed image/PDF/screen attachments, text extraction, credential masking,
  text-only mode and app exclusions. Captures stay out of conversation history.
- **Phase 15 — Tasks:** plan review, explicit approval, step progress, cancellation and saved task reports.
- **Phase 16 — Workspaces:** active project context, scoped writes and developer task/tools integration.
- **Phase 17 — Native interface:** desktop window and Dock presence, Home/Library/Tasks navigation,
  searchable Settings, a freely draggable animated companion, a floating Command Bar and onboarding.
- Collapsible tool cards in the chat timeline with running/succeeded/failed states, redacted arguments
  and expandable output. Detailed cards are session-only; history retains existing condensed tool notes.
- **Apply…** on chat diff blocks opens a target-file sheet and drafts a `file_op` change in the composer.
  Existing draft text is preserved. Patches are never used directly as replacement file contents.
- **⌘⇧S** and a screen button inside the floating Command Bar attach the front non-Ivy window to the shared
  tray for review. The global Command Bar shortcut remains **⌃⌥⌘K**; global screen help is **⌃⌥⌘S**.
- Screen-edge arrows alongside temporary `point_at` highlights, using display-local coordinates.
- One-time v1.0 rollback backup before production stores load, at
  `~/Library/Application Support/Ivy/Backups/1.0/`, including the exact settings blob and durable stores.

### Changed

- Compact multiline composer, clearer sidebar/archive navigation, native approval sheets and click feedback
  for message actions. Liquid Glass controls respect Reduce Transparency and increased contrast.
- Release metadata is **1.1.0 (build 1)**. Packaging stages and verifies new artifacts before replacing
  the local app and preserves older DMGs. SHA-256 sidecars are generated for testing downloads.

### Fixed

- Releasing push-to-talk stops capture during an early reply or pending approval. Output-only playback
  avoids reopening the microphone for that reply; repeated teardown stops a restarted capture engine.
- Startup backup failures leave existing stores unopened and show a temporary-session warning.
  Resolve the error and reopen Ivy to retry; temporary history/settings are discarded on exit.

### Safety and privacy

- Diff buttons only draft requests. Writes/deletes and other risky tools retain explicit SafetyGate approval.
- Tool cards cap display payloads and mask nested credential fields. They do not become model context or
  raw persisted history. Screen attachments are sent only on explicit submission.
- Rollback copies exclude caches, screen/audio captures, diagnostics and Keychain items. Private backup
  folders/files use permissions 0700/0600, and symbolic links are rejected.

### What Ivy never does automatically

- Sends a message, performs a risky file change or treats spoken/chat text as action approval.
- Stores attached screenshots or raw audio in saved conversations.
- Turns on idle wake listening or proactive assistance without the user's setting.
- Copies API keys from the Keychain into a rollback backup.

## 1.0.0

Initial local testing release: Gemini chat/Live voice, explicit tool approvals, macOS tools and release packaging.
