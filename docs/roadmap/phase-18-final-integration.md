# Phase 18 — v1.1 Final Integration & Release

## Goal
Ship Ivy v1.1.0: every phase integrated, regressions caught, security/performance audited, a signed and
notarized build, a changelog, a tag and a release artifact — with a rollback path.

## Baseline
- Release tooling from Phase 7: `scripts/package-release.sh` (release build, `.app` assembly, hardened runtime
  + entitlements, Developer ID or ad-hoc signing, DMG, notarization via `notarytool`, stapling),
  `docs/RELEASE.md`, `IvyVersion` (1.0.0 build 1), `Phase7ReleaseTests`.
- Test suite (861 at the time of writing) plus per-phase manual checklists.

## Workflow
```text
Claude → integration fixes + release prep
AGY    → test-driven-development (fill coverage gaps against every phase's acceptance tables)
You    → complete manual test (all phase checklists + the release checklist below)
AGY    → code-review-and-quality (full-diff review v1.0.0…v1.1.0)
Claude → address findings → release candidate → release
```

## Work breakdown

### 18.1 Integration pass
- Merge order verified; feature flags removed or defaulted; dead code from superseded paths deleted
  (e.g. popover-only views replaced by Phase 17 components).
- Cross-phase flows tested end to end:
  - Wake word → Live → tool with confirmation → transcript in conversation (8, 9, 10, 11, 17).
  - ⌘⇧S → vision answer → `point_at` annotation → follow-up task (14, 15, 17).
  - Proactive follow-up → notification → deep link → conversation (12, 9, 17).
  - Developer template "fix failing tests" → task card → commit draft (15, 16).
  - Personalization applied in REST, Live, summaries and task planner prompts (13).
- Data migration: v1.0 settings + conversations → v1.1 schemas (fixtures from a real v1.0 install).

### 18.2 Full regression
- `swift test` 5 consecutive green runs; suite < 60 s (CONSTRAINTS.md); coverage ≥ 80 % on changed lines.
- `swift build -Xswiftc -strict-concurrency=complete`: zero warnings, zero errors.
- `git diff --check` clean.
- Every phase's manual checklist re-run on the release candidate (not on dev builds).
- Upgrade test: install v1.0.0, create data, install v1.1 RC over it, verify migration + Keychain access.

### 18.3 Security audit
| Area | Check |
|---|---|
| SafetyGate | Every tool (old + Phase 11/16) has classification + "natural language/plan/macro/voice cannot approve" tests; scoped allow-rules (15.9) reviewed |
| Secrets | Source scan (existing audit test), log audit, UserDefaults/profile/task-history/export scans for key patterns |
| Privacy | Screenshots/audio never on disk (scan Application Support after a scripted session); on-device-only wake; proactive features off by default |
| Permissions | Entitlements minimal and documented; usage strings accurate; nothing requested at launch |
| Network | Only Gemini, ElevenLabs, GitHub (optional) endpoints; TLS only; no auth headers logged |
| Dependencies | Still zero third-party SPM packages (or each approved and listed) |
| Prompt injection | Phase 13 suite + tool-output injection tests (file contents saying "ignore rules") |

### 18.4 Performance audit
Phase 8 budgets re-measured on the RC: idle CPU (wake off/on), memory after 1 h, popover and window open
times, 1,000-message scroll, Live first-audio latency, barge-in latency, cold launch < 1 s to menu bar.
Instruments Leaks run: 30 Live sessions, 20 tasks, 50 captures — no leaks.

### 18.5 Release build, signing, notarization
- Bump `IvyVersion` to `1.1.0` (build N), `Info.plist` versions via the packaging script.
- `scripts/package-release.sh` with Developer ID; verify: `codesign --verify --deep --strict`,
  `spctl -a -vvv`, notarization accepted, ticket stapled, DMG signed.
- Clean-machine test (fresh macOS user account): download DMG → Gatekeeper → onboarding → permissions flow.

### 18.6 Changelog, tag, artifact
- `CHANGELOG.md` (new): v1.1.0 grouped by phase — Added / Changed / Fixed / Security / Privacy — written for
  users, with a "What Ivy never does" section (never sends mail on its own, never stores screenshots, …).
- Annotated tag `v1.1.0` on the release commit; GitHub release with DMG + SHA-256 checksum + changelog.
- `docs/RELEASE.md` updated for anything that changed in the process.

### 18.7 Rollback & support
- Keep v1.0.0 DMG available; v1.1 migrations write a one-time backup of v1.0 data
  (`Application Support/Ivy/Backups/1.0/`) so downgrading is possible.
- Diagnostics export (Phase 8.9) documented for bug reports.

## Exit criteria (release gate)
- [ ] All phase exit criteria met; open issues triaged (none blocking).
- [ ] 5× green test runs, zero warnings, coverage target met.
- [ ] Security and performance audit tables signed off.
- [ ] Upgrade + clean-install tests passed.
- [ ] Notarized, stapled, verified DMG; checksum published.
- [ ] Changelog, tag, GitHub release published.

## Release-day manual checklist
- [ ] Clean install on a second Mac/user: onboarding end to end.
- [ ] Upgrade from v1.0.0: history, settings and keys intact.
- [ ] Chat, Live, "Hey Ivy" (idle + barge-in), ⌘⇧Space, ⌘⇧S, ⌘K.
- [ ] One risky tool per category approved and cancelled.
- [ ] One agent task, one developer task, one proactive reminder.
- [ ] Quit during Live with PTT held → relaunch clean.
