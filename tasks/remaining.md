# Remaining work

Updated 2026-10-03 for the v1.1.0 friend-testing build. Original phase checklists are acceptance criteria,
not proof that every proposed feature has shipped. See [CHANGELOG](../CHANGELOG.md) for implemented scope.

## Implemented in this release

- Chat tool cards, diff-to-composer drafts, Command Bar front-window attachment and screen-edge pointer.
- One-time pre-load rollback backup, v1.1.0 build 1 metadata, changelog and packaging that keeps old DMGs.
- Push-to-talk capture release during replies/approval, with output-only reply playback.

## Before broader distribution

- Reproduce and resolve the reported launch failure on the second Apple silicon Mac; obtain its macOS version
  and failure details. The arm64 build targets macOS 14+, but those systems have not all been exercised.
- Test a real v1.0 → v1.1 upgrade and rollback in a separate user account, including Keychain access.
- Run every phase's manual checklist: real mic/speakers/AirPods, key release while replying/approving,
  screen-capture permissions/excluded apps, multiple displays, task approvals and notification navigation.
- Complete the Phase 8/18 Instruments and performance audit (idle CPU, hour-long memory, launch/scroll,
  voice latency and repeated-session/capture leak checks).
- Reconcile all module-roadmap acceptance criteria against implemented behavior. In particular, the
  interactive region selector still uses a protected temporary capture file that is deleted after reading;
  a fully in-process selector remains future work.
- Optional public-release path: Developer ID signing, notarization/stapling and clean-download Gatekeeper
  checks. Deferred for the user's free GitHub/friend-testing distribution.
- Publish a GitHub release only when requested; local artifacts/tags do not publish it automatically.
