# Phase 16 — Developer Mode

## Goal
A project-aware pair programmer: Ivy knows which project you're in, reads git state, runs builds and tests,
diagnoses errors from logs, searches the codebase, prepares commits and PRs — using Phase 11's tool pipeline
and Phase 15's task engine, with SafetyGate on every write.

## Baseline
- `run_shell` (always risky; env sanitised; 30 s default timeout) and `file_op` (path validation, deny-lists,
  1 MB read cap) already make dev work *possible* but clumsy: every `git status` needs a confirmation, there's
  no notion of a project, output is raw.
- Phase 14 lets Ivy read errors off the screen; Phase 15 gives multi-step tasks.

## Scope
**In:** workspaces (projects), read-only git tools, write git tools, build/test runners, log analysis,
codebase search, commit/PR preparation, GitHub integration, dev task templates.
**Out:** a built-in code editor, LSP/indexing engines, running untrusted project scripts without confirmation.

## Design

### Workspaces
```swift
struct Workspace: Codable, Identifiable {
  let id: UUID; var name: String
  var root: URL                    // chosen via NSOpenPanel; bookmark stored
  var kind: [ProjectKind]          // detected: swiftpm, xcode, node, python, rust, go, …
  var commands: [String: String]   // "build": "swift build", "test": "swift test" (detected, editable)
}
```
- Active workspace: selected in UI, or inferred from the frontmost Terminal/VS Code/Xcode window title
  (Phase 14 UI context) with confirmation ("Work in ~/Coding/Ivy?").
- `file_op` gains workspace scoping: when a workspace is active, reads default to its root; writes outside it
  are refused unless the user switches workspace. Phase 3 deny-lists and traversal checks still apply.

### Tools
| Tool | Actions | Classification |
|---|---|---|
| `git_read` | status, diff (staged/unstaged, path filter), log (n), branch list, show commit, blame (lines) | **safe** (read-only; runs a fixed argv, no shell) |
| `git_write` | stage/unstage paths, commit (message), create/switch branch, stash | risky (confirmation shows exact argv and diff stat) |
| `git_remote` | fetch, pull (ff-only), push (never `--force`) | risky; push shows remote + branch + commit count |
| `project_run` | build, test, lint, run (from workspace commands) | risky first time per command per workspace; can be allow-ruled per task (Phase 15.9) |
| `code_search` | literal/regex search, file find by name | safe; scoped to workspace; respects `.gitignore`; ≤ 200 matches |
| `log_analyze` | read a log file/tail or last command output → structured errors | safe (read-only; file access via workspace scope) |
| `github` | list PRs/issues, view PR, create draft PR, comment | read safe; write risky |

- Git tools use `Process` with explicit argv (no shell string), `GIT_TERMINAL_PROMPT=0`, sanitised env,
  timeouts; destructive subcommands (`reset --hard`, `clean -fd`, `push --force`, `branch -D`) are simply not
  offered.
- GitHub: via the user's `gh` CLI if installed (inherits its auth, no token handled by Ivy) — otherwise a
  fine-grained token stored in the Keychain (`CredentialKey.githubToken`), REST calls with minimal scopes.

### Build/test runner & diagnosis
- Stream output into a task card (Phase 15), keep a redacted tail (≤ 200 lines).
- Parsers for common formats (Swift/Xcode `file:line:col: error:`, Swift Testing/XCTest failures, TypeScript/
  ESLint, pytest, cargo) → `Diagnostic { file, line, message, severity }`; clicking opens the file in the user's
  editor (`open -a` / `vscode://file/…`).
- "Why did this fail?" → diagnostics + relevant file snippets (±20 lines) to Gemini → explanation and a
  proposed patch shown as a diff; applying the patch is a `file_op` write → confirmation.

### Commit & PR preparation
- "Prepare a commit": `git diff --staged` (or unstaged with a prompt to stage) → Gemini drafts a conventional
  commit message → user edits → `git_write commit` confirmation.
- "Open a PR": branch diff vs base → drafted title/body (with test plan) → `github` create **draft** PR →
  confirmation; link returned.

### Dev task templates (Phase 15 plans)
"Set up this project" (detect toolchain, install deps with confirmation, build, test), "Fix failing tests"
(run → diagnose → propose patches → re-run), "Review my changes" (diff → review notes, no writes).

### Project-aware context
- Per-workspace context block in the system prompt: name, kinds, commands, current branch, dirty file count
  (refreshed per request, cheap git calls, no file contents unless asked).

## Work breakdown
| Slice | Deliverable | Acceptance |
|---|---|---|
| 16.1 | Workspace model + detection + scoping | Detects SwiftPM/Node/Python fixtures; file_op scoped; bookmarks survive relaunch |
| 16.2 | `git_read` | Status/diff/log parsed; no confirmation; argv-only execution (test) |
| 16.3 | `git_write` + `git_remote` | Confirmation shows argv + stat; forbidden subcommands impossible (test) |
| 16.4 | `code_search` | Respects .gitignore; ≤ 200 matches; < 1 s on a 10k-file fixture |
| 16.5 | `project_run` + streaming task card | Build/test output streamed, redacted, cancellable |
| 16.6 | Diagnostic parsers + open-in-editor | Parser fixtures for 5 toolchains |
| 16.7 | Fix-failure flow (explain + diff patch) | Patch applied only via confirmed file_op |
| 16.8 | Commit message drafting | Draft from staged diff; edit before confirm |
| 16.9 | GitHub (gh CLI or Keychain token) | Draft PR created with confirmation; token never logged |
| 16.10 | Dev templates on Phase 15 | "Set up this project" runs end-to-end on a fixture repo |

## Safety & privacy
- No shell strings for git; allow-listed subcommands; destructive ones absent.
- Workspace scoping narrows `file_op`; never widens Phase 3 restrictions.
- Code snippets sent to Gemini only from the active workspace, only as needed, redacted for secrets
  (`.env` files excluded from reads by default).

## Testing
- Temporary git repos created in tests (real `git` binary if available; skip-with-reason otherwise) +
  fake executor for unit tests.
- Parser fixture corpus; search perf fixture.

## Risks
| Risk | Mitigation |
|---|---|
| Repo scripts run arbitrary code | `project_run` always confirmed first time; commands shown verbatim |
| Leaking secrets from `.env`/config | Default exclusions + SecretRedactor on every outbound snippet |
| gh/token auth confusion | Prefer `gh`; clear status in settings |

## Exit criteria
All slices accepted; fixture repos pass the templates; manual checklist passed.

## Manual checklist
- [ ] Add ~/Desktop/Coding/Ivy as a workspace; "what changed?" → git status/diff summary without prompts.
- [ ] "Run the tests" → confirmation once → streamed output → summary.
- [ ] Break a test → "fix it" → proposed diff → confirm → re-run green.
- [ ] "Prepare a commit" → drafted message → edit → confirm.
- [ ] "Open a draft PR" (on a test repo) → confirmation → link.
- [ ] Ask Ivy to force-push → refuses (not available).
