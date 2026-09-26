# Constraints

Last reviewed: 2026-09-26

## Floor (Always Enforced, No Setup Required)

- **No secrets in source code**: Never commit API keys (Gemini, ElevenLabs). All API keys must be retrieved from environment variables or the macOS Keychain.
- **No unimplemented stubs**: No `fatalError("TODO")`, `fatalError("Not implemented")`, or empty `catch {}` blocks that swallow errors.
- **No skipped or deleted tests**: No removing test assertions or disabling test cases without explicit rationale in commit messages.
- **No suppression comments**: No unapproved compiler warning suppressions or silencing flags without documented architectural justification.
- **This file does not get weakened to make a change pass**: Never lower thresholds or delete rules to get to green.

## Enforced with Numbers

| Dimension | Rule | Checked by | Runs at |
|---|---|---|---|
| Concurrency & Types | Swift 6 strict concurrency mode with zero warnings/errors | `swift build -Xswiftc -strict-concurrency=complete` | Every edit |
| Code Coverage | Changed lines ≥ 80% covered by tests | `swift test --enable-code-coverage` | Task end, CI |
| Secrets | Zero hardcoded keys or credential patterns | Regex / grep pre-commit scan on source tree | Every edit |
| Test Execution Time | Full test suite completes in < 60s | `swift test` | Task end |
| Build Latency | Incremental compile < 5s | `swift build` | Every edit |

## Measured, Not Yet Enforced (Ratchets)

| Metric | Today | Direction |
|---|---|---|
| Project Unit Test Coverage | 0% (Green-field) | Must not fall once established (ratchet to Phase 1 baseline) |
| App Memory Footprint | ~40 MB idle target | Must stay < 100 MB at runtime |
| Menu Bar UI Response Time | < 50ms popover appearance | Must not lag or hitch main thread |

## Exceptions

| ID | Rule | Path | Reason | Owner | Expires |
|---|---|---|---|---|---|
| — | None | — | Green-field project baseline | @dhruvsharma | — |
