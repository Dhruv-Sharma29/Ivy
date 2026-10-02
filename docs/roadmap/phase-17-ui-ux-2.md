> **Desktop shell revision — 2026-10-02:** The user's request supersedes the original menu-bar-first activation design below. Ivy now uses a native SwiftUI main Window, opens at launch and stays in the Dock after closing it. The menu bar is a shortcut menu. Settings uses searchable sidebar navigation. Legacy implementation status below is retained as history; the current UI contract is in SPEC.md §5. Native render checks and composer regressions live in `Tests/IvyUITests`.

# Phase 17 — Ivy UI/UX 2.0: a real Ivy app

## Goal
Current implementation (2026-10-02): native desktop navigation has Home, Chat, Tasks and Settings. Home offers six everyday assistant shortcuts; developer command/code shortcuts and redundant Files, Code, Browser, Clipboard and Tools destinations have been removed. File attachments, explicit paste and research remain available in Chat; shortcuts only draft prompts and open Chat. Native Liquid Glass now spans cards, controls, message bubbles, attachments, the command bar and companion labels on macOS 26+, grouped where appropriate. Main and Settings panes use behind-window vibrancy. Reduce Transparency/increased contrast select opaque surfaces and bordered controls; older systems use regular material. Long replies, code and text editors keep readable text treatments.

The main window uses a hidden title bar and hidden toolbar to remove the large top strip. Native traffic-light controls remain; New Conversation is in the sidebar header and File menu, Settings in the sidebar, and Chat Instructions in the Conversation menu. The professional app icon is shared across in-app surfaces and the Dock, with a matching two-leaf template in the menu bar.

The pixel companion is freely draggable through a native mouse surface on its visible content. Four points of movement distinguishes a drag from a click; only a click opens Ivy. Free placement is persisted relative to the display's usable area, replacing corner snapping. Clamping uses the measured character, status and caption bounds rather than transparent panel margins, so Ivy can reach every edge; caption size changes preserve relative placement. Idle sways and blinks; dragging adds a modest bob and tilt, retaining real activity poses. Reduce Motion keeps all poses still while allowing normal user-controlled dragging.

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

## Implementation status — 17a (2026-10-01)
| Slice | Status | Where |
|---|---|---|
| 17a.1 Design tokens + base components | Partly done | `Sources/Ivy/DesignSystem/IvyTheme.swift` (leaf / moss / sprout light+dark, radii, fonts). **Not done:** `ImageRenderer` snapshot tests — the test target only links `IvyCore`, so view tests need a new target |
| 17a.2 Main window + router | Done | `MainWindowController` (AppKit window, opens only on request: popover ⌘O / window button, or a proactive notification with a suggestion). `AppRouter` (IvyCore) is the single owner of the Dock decision: Dock icon while the window is open, or always with Settings › "Always show Ivy in the Dock". `ivy://conversation/<id>` and `ivy://new` are parsed but no URL scheme is registered yet |
| 17a.3 Sidebar | Done | `SidebarView`: search, Pinned / Today / Yesterday / Previous 7 Days / Earlier (`ConversationGroup`), archived toggle, rename, pin, archive, export, delete (confirmed), ⌘N |
| 17a.4 Chat pane + message blocks | Done | `MessageBlock` parser (IvyCore): prose as inline Markdown, fenced code with language label and Copy, diffs coloured per line. Confirmation cards as in the popover (⌘Return approves, Esc cancels). **Not done:** tool cards, collapsible tool output, "Apply…" on diffs |
| 17a.5 Composer | Done (no attachments) | Reuses `MessageInputBar`; the mic starts Live in the active conversation; suggestions from notifications pre-fill it |
| 17a.6 Slim popover | Not done on purpose | The popover keeps all its features and gains "Open Ivy window"; slimming it waits until the window has had a hands-on pass |

Tests: `Tests/IvyTests/Phase17aAppShellTests.swift` (router/Dock presence, deep links, setting, message blocks, diff
lines, sidebar grouping).

Needs a hands-on pass: open/close the window (Dock icon appears/disappears), "Always show in Dock", sidebar
operations, Markdown/code/diff rendering, approving from the window, window frame restored after relaunch.

## Implementation status — 17b (2026-10-01)
| Slice | Status | Where |
|---|---|---|
| 17b.1 Companion panel | Done | `Companion/CompanionController.swift`: borderless, non-activating `NSPanel`, all Spaces, floating; drag the character or status pill to place it freely. A drag does not open the app. Normalized placement is saved per display and clamped to the usable screen area; legacy corner placement is used until the first drag. **Not done:** trailing the cursor |
| 17b.2 Leaf face + orb | Done | `CompanionView`/`LeafFace`: the logo's leaf with eyes and mouth per mood (vector shapes); ring per mood — level-reactive while listening/speaking, progress arc while working, amber pulse for approval, spinner while thinking, red on error. Reduce Motion → static. Mood logic: `CompanionMood.resolve` (IvyCore) — approval always wins |
| 17b.3 Captions | Done | `GeminiLiveVoiceCoordinator.caption` (end of the current reply, memory only) in a bubble while speaking |
| 17b.4 Annotation overlay (`point_at`) | Done | `point_at` tool (core, **safe**: draws only). Captures now carry their screen frame (`CaptureGeometry`), recorded when the image is actually shown to Ivy; `screenRect(forImageRect:)` maps image pixels → AppKit screen points (scale, offset, flipped Y, other displays). `AnnotationOverlay`: click-through panel, vine-green highlight + label, 6 s, VoiceOver announcement. **Not done:** the hand-drawn arrow from the companion; anchoring by OCR text; region captures (no frame) can't be pointed into |
| 17b.5 Command bar | Done (different chord) | **⌃⌥⌘K** (a global ⌘K would take ⌘K from every app): Spotlight-style key panel; Return asks (reply shown in place), ⌘Return continues in the window, Esc closes, five recent conversations; `/agent` hands off to the window. Blocked (with a pointer to the window) while an approval or a task is pending. **Not done:** "⌘⇧S to attach the current window" inside the bar |
| 17b.6 Task progress on companion | Done | Progress arc from step statuses; plan approval and task pauses show the approval face; right-click: Open Ivy, End Voice Session, Stop Task, Hide for Now |

Settings: show the companion (on — it only appears while active), keep it when idle (off), command-bar shortcut.

Tests: `Tests/IvyTests/Phase17bCompanionTests.swift` — mood priorities, corners and snapping (incl. a negative-origin
display), pixel → screen mapping (Retina, other display, clamping), `point_at` (needs a shown screenshot, safe,
bounded), geometry recorded only on send, captions, settings, distinct shortcuts, wiring.

Needs a hands-on pass: the whole 17b manual list — panel behaviour across Spaces/full screen, multi-display pointing,
command-bar focus, Reduce Motion.

## Implementation status — 17c (2026-10-01)
| Slice | Status | Where |
|---|---|---|
| 17c.1 Onboarding | Done | `OnboardingModel` (IvyCore) + `OnboardingView`: name tag → sass with sample lines → keys (straight to the Keychain) → voice (the microphone is explained, then requested only on a button press) → optional superpowers (wake word, screen help, proactive; nothing turned on unless switched on) → done. Every step skippable; closing early counts as done. Shown by itself only on a fresh install (no key, no conversations); existing installs are marked done at launch; re-run from Settings › General |
| 17c.2 Settings window | Done | `SettingsWindowView` (SwiftUI `Settings` scene, ⌘, / "All Settings…"): General, Voice, Personalization, Screen, Proactive, Privacy & Data, Keys, Permissions (all of them, with deep links), About. The popover and the window share one implementation per section (`SettingsPanel.swift`). Privacy & Data adds **Export Diagnostics…** (redacted report via save panel) and Show Ivy's Data Folder |
| 17c.3 Empty / error / loading states | Partly done | "Try again" under a failed reply (`IvyBrain.retryLastFailed`); empty states point to the next action (key missing, `/agent`). **Not done:** a copy review of every error string |
| 17c.4 Animations | Done (as built) | Companion, annotations, Live halo and status symbols all respect Reduce Motion; no new animation work |
| 17c.5 Keyboard map + accessibility | Partly done | `docs/KEYBOARD.md`; ⌃⌘S toggles the sidebar; labels on the new controls (companion orb, annotation announcement, onboarding progress, sidebar toggle). **Not done:** the hands-on VoiceOver walkthrough and contrast measurement |
| 17c.6 Compact / expanded | Done | The window narrows to 420 pt; ⌃⌘S (or the header button) hides/shows the conversation sidebar; the popover is unchanged |

Tests: `Tests/IvyTests/Phase17cOnboardingTests.swift` — who sees onboarding, name/sass/keys steps (sensitive name
refused, Continue needs a key, Skip doesn't), microphone asked only on request, skipping through changes nothing but
"done", early close, environment marking existing installs, Try again.
