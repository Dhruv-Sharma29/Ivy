# Local app and DMG refresh — 2026-10-05

Historical build-2 packaging record. Superseded by [build-3 shortcut recovery](ptt-shortcut-recovery.md).

Refreshed `dist/Ivy.app` and `dist/Ivy-1.1.0.dmg` after the documentation/roadmap reconciliation.
Version remains **1.1.0 (build 2)**, Apple silicon (`arm64`), ad-hoc signed with Hardened Runtime.
Pointer decoration, its Settings page and hover/circle selection remain removed. Push-to-talk remains
voice-only, with dispatcher-based global shortcuts and immediate General-setting updates.
Explicit capture attachments, Screen Help arrows and the animated companion remain available.

Only documentation changed since the preceding package; the refreshed executable has the same hash.
This packaging run does not implement any additional roadmap feature or establish hardware acceptance.

## Verification

- The preceding docs-update checks passed: strict debug build 2.06 s; 1,286 core tests in 2.943 s and
  29 native UI tests in 31.102 s (1,315 total).
- Release strict-concurrency build passed in 22.08 s without compiler warnings/errors.
- Package credential scan and deep/strict app signature checks passed.
- DMG integrity and SHA-256 sidecar passed. A read-only mount confirmed the app signature,
  exact executable match, version/build metadata and `/Applications` shortcut; the volume was ejected.
- DMG SHA-256: `9dcba61ea40034e1f1c716d230a12c49778126dfeeaf194b8c38d94af310e1a5`.
- Executable SHA-256: `f7cb73c09e344ea16aa3803a0fadf5aaa5331bd372bd1e18b121926ab0289502`.
- Previous app/DMG/checksum preserved under `dist/Previous-Builds/Refresh-2026-10-05-QtQ75M/`.

No `/Applications/Ivy.app` was present to replace. Install from the refreshed DMG to update that location.
No GitHub release, notarization, version tag, microphone capture or permission changes were performed.
Physical push-to-talk testing in other apps, screen guidance and second-Mac installation checks remain
in [remaining work](remaining.md). See [Pointer removal](pointer-removal.md) for the feature-specific tests.
