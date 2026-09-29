# Phase 17 — Ivy UI/UX 2.0: a real Ivy app

## Goal
Turn Ivy from a 380×520 menu-bar popover into a real Mac app people *want* to open: a proper chat window
with a conversation sidebar, a playful on-screen companion that listens, talks and points at things (in the
spirit of [heyclicky](https://www.heyclicky.com)), a quick command bar, and an onboarding people remember —
all unmistakably **Ivy**: sharp, a little sarcastic, green, and alive.

## What we take from heyclicky — and what we make our own

| heyclicky does | Ivy's version |
|---|---|
| "an ai buddy that lives on your mac" | Ivy is a *plant* that lives on your Mac: a small vine/leaf companion that grows little leaves as you use it |
| Hotkey → it sees your screen, you talk out loud | ⌘⇧S "What am I looking at?" (Phase 14) + ⌘⇧Space push-to-talk + "Hey Ivy" |
| Draws on your screen to point the way | `point_at` annotations drawn as vine-green highlights with a hand-drawn arrow + label |
| Voice-spawned agents | "Hey Ivy, agent: …" → Phase 15 task card in the window + companion progress ring |
| Playful faces (^ ω ^), lowercase, personality everywhere | Ivy's leaf-face expressions per state, dry one-liners in empty/error states; tone set by Phase 13 sass slider |
| "HELLO my name is" onboarding | A name-tag onboarding where Ivy introduces itself — and asks what to call you |
| Only sees the screen on hotkey; screenshots never stored | Same promise, shown in the UI and enforced by tests (Phase 14) |
| Chat is secondary; the buddy is the interface | Both: the companion for in-the-moment help, the app window for real conversations and history |

## Baseline
- Single `MenuBarExtra(.window)` scene (`IvyPopoverView`, 519 lines) holding header, settings, banners,
  messages, live bar, confirmation card, input bar. `LSUIElement = true` (no Dock icon).
- Views: `ChatBubbleView`, `ConfirmationCardView`, `MessageInputBar`, `SettingsPanel`.
- One conversation visible; history browsing arrives with Phase 9's `ConversationLibrary`.
- State objects: `IvyBrain`, `VoicePlaybackManager`, `GeminiLiveVoiceCoordinator`, `SettingsModel`,
  `WakeWordController` — all `ObservableObject`, created by `IvyAppEnvironment`.

## Surfaces

### 1. Main window — "Ivy"
```text
┌───────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●                         Ivy                           [🎙] [⌘K] [⚙︎]      │
├───────────────┬───────────────────────────────────────────────┬──────────────┤
│ 🔍 Search  ⌘F │  Fixing the flaky test          🌿 sass 2 ▾   │ Context      │
│               │ ───────────────────────────────────────────── │ ▸ Summary    │
│ 📌 Pinned     │  you  why is WakeWordControllerTests failing?  │ ▸ Screenshot │
│   Ivy roadmap │                                               │   (not saved)│
│   Groceries   │  🌿 Ivy  Because you assert before the        │ ▸ Tool notes │
│ Today         │  controller finishes. Classic. Here's the fix:│ ▸ Workspace  │
│ ● Flaky test  │  ┌ diff ───────────────────────────────┐     │   ~/Coding/  │
│   Standup     │  │- await until { listener.isListening }│     │   Ivy (main) │
│ Earlier       │  │+ await until { … && status == … }    │     │              │
│   Trip plan   │  └──────────────────── [Copy] [Apply…] ┘     │ Per-chat     │
│ ───────────── │  ┌ 🛠 run_shell · risky ────────────────┐     │ settings     │
│ ⚙︎ Tasks (2)   │  │ swift test --filter WakeWord         │     │              │
│ 📁 Workspaces │  │ [Cancel]                  [Do it]    │     │              │
│ 🗄 Archived    │  └──────────────────────────────────────┘     │              │
│               │ ───────────────────────────────────────────── │              │
│ [+ New chat]  │ [📎][🖥][🎙]  Ask Ivy anything…          [↑]  │              │
└───────────────┴───────────────────────────────────────────────┴──────────────┘
```
- `NavigationSplitView`: sidebar (search, pinned, date groups, archived, tasks, workspaces), chat detail,
  optional inspector (⌥⌘I): conversation summary, attachments (placeholders), tool notes, workspace, per-chat
  overrides (Phase 13).
- Message blocks: text (Markdown via `AttributedString(markdown:)`), code blocks (monospace, copy, language
  label), diffs (+/- colouring, Copy/Apply → `file_op` confirmation), images/screenshot placeholders, tool
  cards (running/succeeded/failed, collapsible redacted output), confirmation cards (inline, keyboard
  accessible), task cards (Phase 15 progress), voice transcript turns (🎙 label, "interrupted" tag), error
  cards with retry.
- Composer: multi-line (Return sends, ⇧Return newline), attachments (drag/drop, paste, 🖥 capture menu),
  🎙 starts Live in this conversation, `/` shortcuts (Phase 13), @workspace mention (Phase 16).
- Activation: window open → `NSApp.setActivationPolicy(.regular)` (Dock icon, ⌘-Tab); last window closed →
  back to `.accessory` (setting "Always show in Dock").

### 2. Menu-bar popover — quick Ivy
Slimmed to: last conversation (compact), composer, voice button, "Open Ivy ⌘O". Confirmation cards still appear
here if the popover is the active surface. Everything else lives in the window.

### 3. The companion — Ivy on your screen
```text
                    ╭──────────────────────────────╮
                    │ Open the Export menu, then… │   ← speech bubble with live captions
                    ╰──────────────╮───────────────╯
                                   🌿  ← leaf-face orb (state face + audio-reactive ring)
```
- A small borderless, non-activating `NSPanel` (floating level, joins all Spaces, ignores mouse except on
  the orb) that appears **only when active**: wake word heard, PTT held, Live session, task running, or
  "What am I looking at?". Otherwise hidden (setting: "Show Ivy while idle" off by default).
- Position: follows a screen corner (drag to any corner/edge, remembered per display) — optionally trails the
  cursor like heyclicky (setting).
- States (leaf-face + ring):
  | State | Face | Ring |
  |---|---|---|
  | Listening | `( •ᴗ• )🌿` open eyes | reacts to mic level (Phase 10 meter) |
  | Thinking | `(¬_¬)` side-eye | slow shimmer |
  | Speaking | `( ˘▽˘ )` | reacts to output level; captions in bubble |
  | Working (task/tool) | `ᕙ( •̀ ᗜ •́ )ᕗ` | progress arc |
  | Needs approval | `( ⊙_⊙ )` | amber pulse; click opens the confirmation |
  | Error | `¯\_(ツ)_/¯` | red flash, bubble explains |
  Faces are drawn as vector glyphs (not text) so they scale and animate; kaomoji above are the reference.
- **Annotations** (Phase 14 `point_at`): full-screen click-through overlay window draws vine-green rounded
  highlights, a hand-drawn arrow from the companion to the target, and a label; fade after 6 s or on click.
- Click the orb → opens the conversation in the main window. Right-click → mute, end session, hide.

### 4. Command bar — ⌘K anywhere (global hotkey, configurable)
Spotlight-style centred panel: type a request, ↑/↓ recent conversations and shortcuts, ⌘⇧S to attach the
current window, Return → answer streams into an expandable card; ⌘Return → continue in the main window.

### 5. Settings window (Settings scene) — redesigned
Tabs: General (launch at login, Dock, hotkeys) · Voice (Live, TTS voice settings, devices) · Hey Ivy (wake,
barge-in, echo cancellation) · Personalization (Phase 13) · Tools & Permissions (per-tool status, permission
rows with deep links) · Proactive (Phase 12) · Privacy & Data (history, transcripts, screenshots policy,
export/delete all, diagnostics) · Keys (Keychain rows) · About.

### 6. Onboarding — "HELLO my name is Ivy"
```text
 1. Name tag: "HELLO, my name is Ivy."  Ivy: "And you are…?" (optional name → Phase 13 profile)
 2. Personality: pick the sass level with live sample lines
 3. Keys: paste Gemini (and optional ElevenLabs) key → Keychain (never shown again)
 4. Try your voice: hold ⌘⇧Space and say hi (mic permission explained *before* the system prompt)
 5. Optional superpowers: "Hey Ivy" wake word, screen help (⌘⇧S), proactive nudges — each opt-in with one line
    on what it does and what it never does
 6. Done: the companion waves; tips card in the empty chat
```
Skippable at every step; re-runnable from Settings › General. Nothing is enabled without the user's choice.

## Design system (`Sources/Ivy/DesignSystem/`)
- **Colour tokens** (light/dark, contrast-checked ≥ 4.5:1 for text):
  `ivy.leaf` (primary green), `ivy.moss` (deep green), `ivy.sprout` (light accent), `ivy.soil` (warm neutral
  text), `ivy.paper` (warm off-white / charcoal background), semantic `risk.amber`, `danger.red`,
  `success.green`, `info.blue`. The system accent is not used for Ivy's identity.
- **Type:** SF Pro for UI, SF Pro Rounded for Ivy's own voice (companion bubble, onboarding, empty states),
  SF Mono for code; Dynamic Type scale.
- **Shape & material:** 12 pt radius cards, 20 pt bubbles, vibrancy sidebar, subtle leaf texture in empty
  states only.
- **Motion:** spring presets (`snappy`, `gentle`, `leafSway`); every animation has a Reduce Motion variant.
- **Iconography:** SF Symbols + a custom leaf/vine symbol set (SF Symbols template export) for Ivy states.
- **Components:** `MessageBlockView` (per block type), `ToolCard`, `ConfirmationCard`, `TaskCard`,
  `VoiceOrb`, `LeafFace`, `AttachmentChip`, `EmptyState`, `ErrorCard`, `PermissionCard`, `KeyField`,
  `SidebarRow`, `CommandBarField`.
- **Voice & copy:** Ivy's dry wit in empty states and small talk; errors and confirmations are always plain
  and precise first, witty second (never at the expense of clarity).

## Architecture
- Scenes: `WindowGroup(id: "main")`, `MenuBarExtra`, `Settings`, plus AppKit-hosted panels (companion,
  annotation overlay, command bar) managed by a `PanelController` (`NSPanel` + `NSHostingView`).
- `AppRouter` (@MainActor, observable): selected conversation, open surfaces, deep links
  (`ivy://conversation/<id>`, `ivy://task/<id>`), used by notifications (Phase 12) and the companion.
- View models wrap existing core objects (`ChatViewModel` over `IvyBrain` + `ConversationLibrary`), so
  IvyCore stays UI-free and testable.
- Only one confirmation surface is active at a time: the card is shown where the user is (window, popover or
  companion bubble → click to expand); SafetyGate state remains single-sourced in core.
- Performance: `LazyVStack` with stable ids, message block height caching, images decoded off-main,
  60 fps scroll with 1,000 messages (Phase 8 budget).

## Work breakdown

### 17a — App shell (right after Phase 9)
| Slice | Deliverable | Acceptance |
|---|---|---|
| 17a.1 | Design tokens + base components | Snapshot tests (ImageRenderer) light/dark for each component |
| 17a.2 | Main window + NavigationSplitView + router | Opens from menu bar/⌘O; Dock policy switching works |
| 17a.3 | Sidebar on Phase 9 library (search, pin, groups, archive) | All library ops reachable by mouse and keyboard |
| 17a.4 | Chat pane: message blocks (text, code, diff, tool, confirmation, errors) | Markdown/code render; confirmation fully keyboard-operable |
| 17a.5 | Composer (multi-line, attachments stub, voice button) | Send/newline/shortcuts; voice starts Live bound to this conversation |
| 17a.6 | Slim popover | Quick chat + open window; no feature regressions (Phase 1–7 tests) |

### 17b — Companion & overlays (after Phase 14)
| Slice | Deliverable | Acceptance |
|---|---|---|
| 17b.1 | PanelController + companion panel | Non-activating, all Spaces, corner snapping per display |
| 17b.2 | LeafFace + VoiceOrb states, audio-reactive | Each state rendered; Reduce Motion static variants |
| 17b.3 | Captions bubble | Live captions from Phase 9 transcripts; auto-hide |
| 17b.4 | Annotation overlay (point_at) | Correct placement on 2 displays, Retina/non-Retina; click-through |
| 17b.5 | Command bar | Global hotkey, recents, attach window, continue in window |
| 17b.6 | Task progress on companion | Progress arc + approval pulse → opens card |

### 17c — Onboarding, settings, polish (last, before Phase 18)
| Slice | Deliverable | Acceptance |
|---|---|---|
| 17c.1 | Onboarding flow | Every step skippable; nothing enabled without consent; re-runnable |
| 17c.2 | Settings window redesign | All existing settings reachable; permission deep links |
| 17c.3 | Empty/error/loading states with personality | Copy review; every error has an action |
| 17c.4 | Animations & micro-interactions | Reduce Motion honoured everywhere |
| 17c.5 | Keyboard map + accessibility audit | VoiceOver end-to-end; full keyboard use; contrast checks pass |
| 17c.6 | Compact/expanded modes | Window compact mode ≤ 420 pt wide; popover unchanged |

### Keyboard map
⌘N new chat · ⌘F search · ⌘K command bar · ⌘1…⌘9 pinned chats · ⌘⇧Space push-to-talk (global) ·
⌘⇧S screen help (global) · ⌘. / Esc stop Ivy (cancel turn, deny pending confirmation) · ⌘Return approve
focused confirmation (only when the card has focus) · ⌥⌘I inspector · ⌘, settings.

## Safety & privacy in the UI
- Confirmation cards never auto-focus "Do it"; risky badge colour + exact action text; ⌘Return approval only
  when the card itself is focused.
- The companion shows when the mic or screen capture is in use (plus macOS indicators).
- Onboarding explains each permission before the system prompt; declining keeps Ivy fully usable for chat.

## Testing
- Snapshot tests with `ImageRenderer` (no dependencies) for components and key screens, light/dark, two sizes.
- View-model unit tests (router, chat VM, companion state mapping from coordinator states).
- UI smoke tests via accessibility identifiers (manual/AGY driven) for window, popover, command bar.
- Performance test: 1,000-message conversation render + scroll.

## Risks
| Risk | Mitigation |
|---|---|
| Companion feels intrusive | Hidden when idle by default; easy mute/hide; per-app "don't show over" list |
| Multi-display/Spaces edge cases for panels | Dedicated tests for coordinate mapping; manual matrix |
| Scope creep in polish | 17a/17b/17c gated; each has fixed acceptance tables |
| Dock/activation policy flicker | Single policy owner in `AppRouter`, tested transitions |

## Exit criteria
17a–17c acceptance met; snapshot suite stable; accessibility audit passed; Phase 1–16 regression green;
manual checklist passed.

## Manual checklist
- [ ] First launch: onboarding name tag → keys → voice → optional superpowers → done.
- [ ] Main window: create, search, pin, archive, rename chats; Dock icon appears/disappears correctly.
- [ ] Approve a risky tool from the window, from the popover, and via the companion pulse.
- [ ] Say "Hey Ivy" → companion appears, listens, speaks with captions, hides after.
- [ ] ⌘⇧S on an app → Ivy points at the right control with the vine highlight (two displays).
- [ ] ⌘K → quick question → continue in window.
- [ ] VoiceOver and keyboard-only: complete a chat with a confirmation.
- [ ] Reduce Motion on: no animated faces/rings, everything still understandable.
