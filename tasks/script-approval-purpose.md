# Script approval purpose

Requested 2026-10-08 for local v1.1.0 build 23.

The companion displayed the technical request title (“AppleScript Execution”), which did not
explain the requested action. Script and shell declarations now ask the model for a required,
short `reason`, such as “Open YouTube in Safari.” The shared persona asks for the actual goal,
target and material changes, including writes/deletions.

The confirmation request carries this reason through both chat and Live tool approval. The
compact companion displays it above the existing Cancel / Do it controls, retaining the same
228×88-point layout, hover review, shortcuts, drag behavior and identity guards. The app keeps
the technical title, purpose and full script/command in its detailed review sheet.

Whitespace is normalized and credential-shaped values are redacted from reason text. The
purpose is model-supplied descriptive text, not a proof of the script's effects or an approval.
The complete payload remains available for review. Older calls missing a usable reason stay
compatible and display “Run the requested script” / “Run the requested command”; an intention
is never inferred by pretending to understand arbitrary code.

## Try it

Ask Ivy to perform a task that uses a script. Its next approval should describe the requested
action instead of displaying AppleScript Execution on the companion. Inspect the full script
in the workspace or hover review, then choose Cancel or Do it. Expanding, showing or dragging
the approval does not authorize execution.

Tests verify purpose propagation, original payload and request identity, mandatory reason schema,
older/malformed missing-reason calls, redaction and cancellation. Native light/dark companion
previews include the Safari/YouTube purpose while preserving compact bounds and button routing.

## Verification and delivery

- Full `swift test`: 1,333 core tests and 43 UI tests passed (1,376 total), in
  38.806 seconds combined test execution. Tests exercise the real shell argument validator,
  purpose propagation and cancellation; no script is executed by the approval tests.
- Swift 6 strict debug build passed in 6.96 seconds; the warm build passed in 0.20 seconds.
  Debug and release compilation produced no warnings or errors.
- Coverage of changed executable lines across the current working tree: 114/114 (100%).
- Reviewed the native dark companion preview: “Open YouTube in Safari” fits above Cancel /
  Do it with the existing compact layout. Light/dark bounds and button routing tests passed.
- Packaged v1.1.0 build 23 with ad-hoc Hardened Runtime signing. The DMG checksum, mounted
  app signature and binary comparison passed; it contains the arm64 app and Applications link.
- Installed build 23 in `/Applications/Ivy.app`, verified its signature and exact binary
  match to the package, and relaunched it. The accessibility tree shows the companion alone
  with its “Ivy is here” control, preserving companion-first launch.

Previous build 22 artifacts are retained under
`dist/Previous-Builds/Before-Script-Purpose-Build23-2026-10-08-2tse6v41/`.
The previous installed app is retained under
`dist/Previous-Builds/Before-Applications-Install-Build23-2026-10-08-pjUgX3/Ivy.app`.

SHA-256:

```text
98279179edd065a48824b6b250229f6bdeb13bd960a0c8960d5ec353b1e9134a  Ivy executable
9b85beb36ae063a28f6b8307cf08eff7d441d3da1578c75e1e98d56821918f00  Ivy-1.1.0.dmg
```

Purpose rendering and propagation were verified with tests and a native preview. A fresh
model-generated approval during a personal microphone session remains a manual acceptance check.
