# Changelog

## Unreleased

- Included in the latest local app/DMG: hover, freehand and rectangle screen questions with a shared push-to-talk key
  (⌘⇧Space), optional R/A selection shortcuts and a menu action. Typed crops are reviewed in Quick chat;
  voice crops are sent before bounded, memory-only speech after microphone release. Silent presses,
  Esc, stale windows/displays, capture denial, sleep and session lock cancel the turn. Protected apps
  are excluded and crops use the existing local redaction pipeline. This is the initial 20.12 slice;
  richer drawing and typed-submission freshness remain pending.

- Included in the latest local app/DMG rebuild: optional folded-leaf floating pointer, native Pointer settings,
  persisted Blue/Green/Amber/Red choices and bounded following beside the system cursor. Default off;
  click-through and non-activating, with no computer input or extra permissions. Disable/Reduce Motion,
  sleep/inactive session, unavailable displays and shutdown stop sampling. Existing arrows/approvals remain separate.
- The workspace plan now requires Ivy's own task-first layouts, leaf/status notch overview, grouped
  settings, original icons/copy/assets and design review against existing Ivy surfaces at every milestone.
- The 2026-10-04 floating-pointer package refresh retains version 1.1.0 (build 2), preserves the
  preceding app/DMG under `dist/Previous-Builds/Floating-Pointer-2026-10-04-lA9sSo/`, and passes release
  compilation, app signature, mounted-binary comparison, DMG integrity and SHA-256 checks.

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
