# Companion text refresh — 2026-10-08

Current artifacts are build 24, retaining this companion design and adding [detailed app approvals](app-approval-details.md).


## Delivered in 1.1.0 (15)

Companion approvals show the original action reason and Cancel / Do it in a smaller **228×88-point**
rounded bubble. The reason uses restrained 12-point medium type and wraps to two lines. Equal-width
buttons have 28-point targets, a quiet neutral Cancel and Ivy's indigo Do it. Their text stays readable
when the floating panel isn't the active window, with immediate hover/press feedback.

Speaking captions are left-aligned, 13-point text with more line spacing and padding. They retain the
three-line limit and expose the full text on hover. Error bubbles use the same treatment with their
existing two-line limit. Status pills now use 12-point medium type and more breathing room.

Approval, caption and status bubbles use adaptive opaque light/dark surfaces with a subtle outline, keeping
busy desktop colours from washing out the words. Button outlines strengthen with increased contrast.
No extra animation is added. Existing companion movement and Reduce Motion behavior remain intact.

The approval still mirrors the same identity-bound request. Hovering its reason reveals the original
prompt/detail. Escape cancels; Command-Return approves. Showing, hiding, layout, captions and dragging
never approve an action. Buttons remain outside the character's drag surface. Detailed review remains
in the main app, whose confirmation sheet retains its existing layout. The companion panel's transparent
outer dimensions and remembered placement behavior are unchanged.

## Verification

The existing native lifecycle and chat/Live approval tests verify stale/repeated-response isolation,
explicit consent, show/hide/resize and interaction routing. Layout fixtures now include the screenshot's
Create Calendar Event reason and a long action title in both appearances. Their bounds assertions use
the intentionally smaller 228-point bubble and still check full visible content and noninteractive
measurement surfaces. This updates the old 240-point assertion to the new design; no tests were removed.
Caption/state galleries render a longer speaking message, real progress and errors with motion disabled.
All providers/audio services in these fixtures are offline.

- **1,351 tests passed**: 1,311 core tests in 2.908 seconds and 40 native UI tests in 37.677 seconds.
  Changed executable source lines across current local changes: **325/326 covered (99.69%)**,
  including all 46 changed executable companion/confirmation UI lines.
- Strict Swift 6 build passed without compiler diagnostics. Warm incremental build: 0.18 seconds.
  Source credential-pattern scan and `git diff --check` passed.
- Light/dark approval and long-reason previews were visually inspected. Full state galleries verify
  readable status, long speech/error captions and actual progress. Previews are saved in
  `/private/tmp/ivy-companion-text-review`.
- Packaged, mounted and installed apps are **1.1.0 (15)** for Apple silicon. Release build took
  28.61 seconds; package credential scan found zero leaks. Ad-hoc Hardened Runtime signing passed
  strict verification on all copies. Apple notarization remains unconfigured for this testing release.
- DMG integrity, SHA-256 sidecar, executable equality for mounted/installed copies and the Applications
  link passed. Executable SHA-256: `051140cdb67bddcbc40fe2549b6b6f155fe8a92e47773609fe23ff2272146ceb`.
  DMG SHA-256: `237760e00a13a7b6de82eb51e7d8bc3e53e3aad4de9d56edb9f30091850ef6f2`.
- Build-14 packaged and installed copies remain backed up in `dist/Previous-Builds`. The running
  session was left uninterrupted; relaunch is required to load build 15. The last native installed-app
  inspection was blocked by a locked Mac, so physical click/keyboard/microphone checks remain manual.

## Try it

Relaunch Ivy, confirm About shows **1.1.0 (15)** and enable the companion. Ask for an action that already
requires approval. Review the reason beneath Ivy, then choose Cancel or Do it. The app keeps the detailed
request available. A voice reply shows the refreshed caption above Ivy; ordinary status stays below her.
