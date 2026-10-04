# Changelog

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
