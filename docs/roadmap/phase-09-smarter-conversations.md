# Phase 9 — Smarter Conversations

## Goal
Ivy keeps many conversations, finds any of them instantly, and stays sharp in long ones: context is
budgeted, older turns are summarised instead of dropped, tool results are remembered in a safe condensed
form, and voice sessions become part of the written conversation.

## Baseline
- `IvyBrain` holds one active conversation (`messages`, `conversationID`); every REST call sends the full
  non-error history (`messages.filter { !$0.isError }`), capped only by the 5-turn tool loop.
- `FileConversationStore`: one JSON file per conversation (`Application Support/Ivy/Conversations`, 0600),
  `list()` decodes every file (O(n) full reads), only the latest is restored at launch, no UI to browse.
- Persisted: user/model text only (tool calls, results, signatures dropped; `SecretRedactor` applied).
- Live voice sessions are **not** written into any conversation.
- Clear (trash) deletes the conversation.

## Scope
**In:** conversation library (list, open, new, rename, pin, archive, delete, search, export), context
budgeting and compaction (rolling summaries), condensed tool-result memory, per-conversation system
context, voice transcripts in conversations, storage index + schema migration.
**Out:** the full chat window UI (Phase 17a consumes this), cross-device sync, embeddings/semantic search
(possible later; no new dependencies now).

## Design

### Data model (schema v2)
```swift
struct Conversation {           // file: <id>.json
  let id: UUID; var title: String; var titleSource: .auto | .user
  var createdAt, updatedAt: Date
  var isPinned: Bool; var archivedAt: Date?
  var systemContext: String?    // per-conversation instructions (Phase 13 layers on top)
  var summary: ConversationSummaryBlock?   // rolling summary of compacted turns
  var messages: [StoredMessage] // kind: .user | .model | .toolNote | .voiceUser | .voiceModel | .error
  var schemaVersion: Int = 2
}
struct ConversationIndexEntry { id, title, updatedAt, isPinned, isArchived, messageCount, preview }
// file: index.json — rebuilt from files if missing/corrupt
```
- `StoredMessage.kind` adds `toolNote` (condensed tool result) and voice kinds; v1 files migrate
  (`role` → `kind`), migration tested with fixtures.
- **Index file** makes the library O(1) to list; updated atomically on every save/rename/pin/delete;
  rebuilt by scanning if absent or corrupt (Phase 8 quarantine applies).

### Library operations (`ConversationLibrary`, @MainActor, observable)
`list(filter: .active|.pinned|.archived)`, `open(id)`, `newConversation()`, `rename(id, title)`,
`setPinned`, `archive/unarchive`, `delete` (confirm in UI; hard delete of the file), `search(query)`,
`export(id, format: .markdown | .json)`.
- Brain switches conversations via `load(conversation:)`; an in-flight turn blocks switching (or is
  cancelled, with a pending SafetyGate confirmation denied).

### Titles
- Auto-title after the first model reply: one cheap Gemini call ("≤ 6 words, no quotes") on the first
  user+model pair; fallback = first user message truncated. Never re-titles a user-renamed conversation.
- Title generation counts against quota → skipped when quota is low (Phase 8 `QuotaStatus`).

### Search
- In-process inverted index over titles + message text (lowercased tokens, prefix match), built lazily from
  files, updated incrementally on save. Results: conversation + matching snippet + message id to scroll to.
- Budget: 1,000 conversations × 200 messages searched in < 100 ms. If exceeded, persist the index.

### Context-window management
```text
build request history:
  [system prompt + personalization (P13) + conversation.systemContext]
  [summary block, if any]            ← "Earlier in this conversation: …"
  [toolNotes still relevant]
  [last N turns that fit the budget]
```
- `ContextBudget`: model limit (constant per model) × 0.6 target; token estimate = chars / 4 (conservative),
  replaced by the API's `countTokens` result when available (cached per message).
- **Compaction**: when history exceeds the target, the oldest turns (never the last 6) are summarised via a
  Gemini call into `summary` (cumulative: old summary + new turns → new summary, ≤ 300 words, facts and open
  tasks, no secrets). Compacted messages stay on disk and in the UI; only the request is shortened.
- Compaction runs after a turn completes, never blocking the user's next message; failure = keep full history
  and retry later.
- Function-call turns inside one request loop are never split by compaction (thought_signature integrity).

### Tool-result context
- After each tool execution the brain stores a `toolNote`: tool name, args summary (redacted, paths kept),
  outcome (success/failure + ≤ 200 chars of result, redacted). Raw results are never persisted.
- Tool notes are included in later requests so "open the file you just read" works across restarts.

### Voice in conversations
- Enable Gemini Live `inputAudioTranscription` / `outputAudioTranscription` in setup; the coordinator
  appends final transcripts as `voiceUser` / `voiceModel` messages to the **active conversation** via the
  brain. Interrupted model turns are marked `(interrupted)`. No audio is stored.
- Setting: "Save voice transcripts" (default on, follows "Save conversation history").

### Export
- Markdown (`# Title`, timestamps, speaker labels) or JSON (schema v2). Passed through `SecretRedactor`.
  Saved via `NSSavePanel` only (user-chosen location).

## Work breakdown
| Slice | Deliverable | Acceptance |
|---|---|---|
| 9.1 | Schema v2 + migration + index file | v1 fixtures migrate losslessly; index rebuilds after deletion |
| 9.2 | ConversationLibrary (new/open/rename/pin/archive/delete) | Operations persist across relaunch; switching mid-confirmation denies it |
| 9.3 | Auto-titles | Title after first reply; user rename never overwritten; quota-aware |
| 9.4 | Search | Finds text in 1,000 fixture conversations < 100 ms; snippet + scroll target |
| 9.5 | ContextBudget + compaction | 300-turn conversation stays under budget; last 6 turns always verbatim; tool loop never split |
| 9.6 | Tool notes | Follow-up referencing a prior tool result works after relaunch; no raw results on disk |
| 9.7 | Voice transcripts | Live session appears in the active conversation; interrupted turns labelled |
| 9.8 | Export | Markdown/JSON export redacts key patterns (test) |
| 9.9 | Minimal popover UI hooks | Popover "conversations" menu (list/new/search) until 17a's sidebar lands |

## Safety & privacy
- Summaries and tool notes pass `SecretRedactor`; summary prompt instructs "never include credentials".
- Delete is a hard delete of the file and its index entry; archive is reversible.
- Search index is in memory (or 0600 file); never includes audio.

## Testing
- Fixture corpus generator (N conversations, M messages) for search/index/perf tests.
- Fake summariser client for compaction (deterministic output); assert request history shape.
- Migration tests with real v1 JSON captured from Phase 5.

## Risks
| Risk | Mitigation |
|---|---|
| Summaries lose important details | Cumulative summaries include "open tasks/decisions"; last 6 turns verbatim; user can view the summary |
| Extra Gemini calls (titles, summaries) hit quota | Quota-aware scheduling; both are skippable |
| Index/file divergence | Index is derived data; rebuild on mismatch |

## Exit criteria
Library operations, search, compaction, tool notes, voice transcripts, export all meet acceptance; v1 data
migrates; full suite green; manual checklist passed.

## Manual checklist
- [ ] Create 5 conversations, rename, pin, archive, delete; relaunch — all preserved.
- [ ] Search a word from a week-old conversation; jump to the message.
- [ ] Long conversation (100+ turns): Ivy still recalls an early fact (via summary).
- [ ] Read a file with Ivy, relaunch, ask "what was in that file?" — answered from the tool note.
- [ ] Voice session transcript appears in the conversation.
- [ ] Export to Markdown; confirm a pasted fake key is redacted.

## Implementation status (2026-09-30)
| Slice | Status | Where |
|---|---|---|
| 9.1 Schema v2 + migration + index | Done | `ConversationStore.swift` (`StoredMessage.Kind`, `Conversation` v2, `index.json`) |
| 9.2 ConversationLibrary | Done | `ConversationLibrary.swift`; `IvyBrain.load/startNewConversation/updateConversation` |
| 9.3 Auto-titles | Done | `IvyBrain.generateTitleIfNeeded`; setting `autoTitleConversations` |
| 9.4 Search | Done | `ConversationSearchIndex` (in memory, prefix match, AND across words) |
| 9.5 ContextBudget + compaction | Done | `ConversationContext.swift`, `IvyBrain.requestContext/compactIfNeeded` |
| 9.6 Tool notes | Done | `ToolNote`; typed and voice tool calls |
| 9.7 Voice transcripts | Done | `BidiSetup` transcription config, `LiveEvent.inputTranscript/outputTranscript`, `onTranscript`; setting `saveVoiceTranscripts` |
| 9.8 Export | Done | `ConversationExporter` (Markdown / JSON), save panel in the conversations panel |
| 9.9 Popover hooks | Done | `ConversationsPanel.swift` (list, new, search, rename, pin, archive, export, delete) |

Tests: `Tests/IvyTests/Phase9ConversationTests.swift` (35 tests).

Deviations and open items:
- Token counts are estimated (chars / 4); the API's `countTokens` is not called.
- The default budget is the spec's 60% of a 1,048,576-token limit, so compaction only starts on very long
  conversations. Lower `ContextBudget.modelLimit` to compact (and save quota) sooner.
- "Tool notes still relevant" = the 10 most recent.
- A conversation switch during an in-flight request discards that reply (the question stays saved); the
  request itself is not cancelled, so the new conversation shows "thinking" until it returns.
- Search snippets use the first message containing the first query word as a substring.
- Live transcription is always requested (Phase 10 reads spoken commands from it); the setting only
  controls whether transcripts are added to the conversation, and applies immediately.
- Manual checklist: only the panel listing and a saved failed turn were checked in the running app; rename,
  pin, archive, export, search-hit scrolling and a real auto-title still need a hands-on pass.
