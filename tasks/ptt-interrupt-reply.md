# Push-to-talk reply interruption — 2026-10-08

Current artifacts are build 20, retaining this change and [adding background companion work](background-companion.md).

## Behavior in 1.1.0, build 11

A new hold of the configured voice shortcut (default **⌘⇧Space**) interrupts Ivy's Live reply
or pending response and opens a fresh held recording. Release submits the new question once,
closes microphone capture, and lets Ivy finish its replacement reply using output-only playback.
The alternate configured PTT shortcut has the same behavior.

The previous session disconnects and its original playback engine stops before the new one starts.
Partial transcripts remain in chat as interrupted. Pending tool confirmation is denied and withdrawn;
pressing the shortcut cannot approve it. Cancelled tool-task/socket events cannot affect the new session.
Actions already completed are not undone. This is Live voice interruption, not a global rollback or
cancellation of independently running Tasks.

Key repeat does not restart a held recording. The press-bound release watchdog stays active while
old resources are being released. A quick release during cleanup/startup is remembered and a silent
replacement closes without a request. Explicit Stop/shutdown or a monitor failure cancels the restart;
a monitor failure retains its visible error. Ordinary hands-free listening is unchanged until the user
explicitly interrupts an active reply; that replacement uses held PTT behavior.

## Implementation and verification

- `GeminiLiveVoiceCoordinator.beginPushToTalk` no longer rejects a new hold during a released reply.
  A restart identity survives interruption teardown while the physical press and release state remain live.
  Normal Stop/failure teardown clears the identity; startup checks ownership before reconnecting.
- Three existing Phase 4 tests previously asserted that a new press could not interrupt speech or
  approval. Their expectations now reflect the user's explicit interruption request and assert playback
  stop, input release and no execution of a withdrawn approval. Tests were updated, not removed/skipped.
- New offline regression fixtures cover thinking, PTT speech, hands-free speech, approval, held repeat,
  replacement submission, output-only reply playback, quick release/Stop during disconnect, a visible
  monitor failure during disconnect, and the registered shortcut's missing-key-up recovery.
- Build 11 also includes the [blushing/clasped-hands idle animation](companion-blush-animation.md).

## Automated results

- Full coverage run: **1,310 core tests in 183 suites (2.868 s)** and **35 native UI tests
  in 5 suites (34.908 s)**, totaling **1,345 passing tests**. No tests skipped or removed.
- Changed executable source lines across the current working tree: **109/110 (99.09%)**.
  Coordinator changes: **30/30 (100%)**; companion changes: **25/25 (100%)**.
- Strict Swift 6 build passes without compiler warnings/errors: 7.03 s after switching away from
  instrumentation, then 0.18 s for the warm incremental build. Source credential scan and diff whitespace
  checks pass. No real microphone, API account or desktop action is used by these fixtures.

## Package and installation

- Release strict build: 29.06 s. The friend-testing package uses ad-hoc signing with Hardened Runtime
  (`runtime` flag), arm64 architecture, bundle ID `com.ivy.assistant`, version `1.1.0`, build `11`.
  No notarization credentials were used. No compiler warnings/errors; packaging tools reported macOS
  `hdiutil` deprecation notices only.
- `dist/Ivy-1.1.0.dmg` integrity and SHA-256 sidecar check pass. The image was mounted read-only;
  its app signature verifies, metadata is build 11, Applications links to `/Applications`, and its binary
  and blush PNG match the repository/dist copies byte-for-byte. The image was detached afterward.
- Installed `/Applications/Ivy.app`, preserved the prior installed app in
  `dist/Previous-Builds/Before-Applications-Install-Build11-2026-10-08-zM5HsX/`, and relaunched Ivy.
  Installed signature, metadata, binary and blush asset match the verified release.
- Binary SHA-256: `841606a0590ad1a33c50695c2b493c55393c6612b3dd7e13d2d597356a69ef2c`.
- DMG SHA-256: `a3da526ea7e86325903be8c6f32907d94309d3d986f961d36b1a33dff71be4e3`.
- Previous build-10 package and DMG were preserved before packaging build 11. Source changes remain
  uncommitted; this update does not publish a GitHub release.

## Try it on hardware

1. Check About shows **1.1.0 (11)** and the voice shortcut is registered in Settings → General.
2. Over Safari or another app, hold **⌘⇧Space**, say “Explain how rain forms,” then release.
3. While Ivy is answering, hold the same shortcut again. Her previous reply should stop.
4. Say “Actually, what causes a rainbow?” and release. Ivy should answer the new question once.
5. Repeat with a quick silent press, release Space first or a modifier first, and explicit Stop.
   Input should close every time. Repeating key-down during one hold must not reconnect.

These automated tests use mock audio/socket/hotkey services. Physical cross-app keyboard, microphone,
speaker latency and system permission behavior still require this manual check.
