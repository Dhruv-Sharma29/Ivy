# Ivy keyboard map

## Anywhere (global; switches in Settings › General / Screen)

Push-to-talk registration changes immediately when its General setting is toggled. It is voice-only:
release submits speech and closes PTT capture. The removed Pointer feature has no selection shortcuts
or screen-question menu action. Screen Help remains a separate explicit capture action.
| Keys | Does |
|---|---|
| ⌘⇧Space (hold, default) | Push-to-talk: talk while held, Ivy answers when you let go |
| ⌃⌥⌘S | "What am I looking at?" — captures the front window, opens Ivy with it attached (during a voice session, shows it to Ivy Live) |
| ⌃⌥⌘K | Command bar |

In build 3, **General → Voice shortcut** also offers **⌃⌥⌘Space**. Choosing it replaces the default;
Ivy listens for one PTT shortcut at a time. The picker applies immediately. General shows registration
failures, including an already-used shortcut. Quit the conflicting app or choose the other key;
toggling Push to talk off/on retries. The selected PTT shortcut requests exclusive registration.

Global shortcuts avoid ⌘⇧S and ⌘K on purpose: as global hotkeys they would stop working in every other app.

## Menu bar shortcut
| Keys | Does |
|---|---|
| ⌘O | Open Ivy's main window |
| ⌘, | Open the native Settings window |
| ⌘Q | Quit Ivy |

## Main window
| Keys | Does |
|---|---|
| Return / ⇧Return | Send / new line (`/agent <goal>` plans a task; `/shortcut` expands yours) |
| ⌘N | New conversation |
| ⌘O | Open or bring forward the main window |
| ⌘F | Search conversations |
| Sidebar toolbar button | Show / hide conversations for a compact chat layout |
| ⌘. | Stop the running task |
| ⌘V / drop | Attach images or PDFs |
| ⌘, | Settings window |

## Approval cards
| Keys | Does |
|---|---|
| ⌘Return | Approve ("Do it") — never plain Return, so a stray keypress can't approve |
| Esc | Cancel |

## Command bar
| Keys | Does |
|---|---|
| Return | Ask (the reply appears in the bar) |
| ⌘Return | Continue in the window |
| Esc | Close |

## Floating Command Bar

Open with **⌃⌥⌘K**. While the bar is focused, **⌘⇧S** (or its screen button) attaches the front
non-Ivy window to the preview tray. It stays unsent until Return submits the message; remove it or
continue in Ivy's main window to review it there. This is a local shortcut, so other apps keep Save As.
