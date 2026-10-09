# Phase 21 — Model and evaluation foundation

Implemented 2026-10-09, after build 24. This is a source milestone; the installed app and DMG
remain build 24. No live-provider comparison or hardware acceptance was performed.

## Delivered

- One `ModelProvider` boundary for chat, planning, titles, summaries and briefings. Requests have
  an explicit purpose and contain no credential field. The default Gemini adapter privately resolves
  the existing credential, preserves transport retries/quota errors and signed tool parts, and keeps
  the legacy planner API working. Model metadata excludes endpoint query parameters.
- The production environment injects the same provider into chat and planning. An alternate provider
  is exercised without a Gemini key. Voice recognition and speech output stay independently configured.
- Capabilities default to text only unless explicitly declared. Image pixels unsupported by a provider
  produce a visible error; OCR text still works. Unexpected tool calls in text-only requests fail before
  dispatch. Empty answers and provider failures recover visibly. Cancellation is checked before/after
  generation and before each tool, including a late transport reply after interruption.
- Eight versioned offline fixtures: open VS Code, locate the selected Finder folder, draft a document,
  decline a write, cancel before generation, missing app, invalid arguments and unknown tool.
  They use production tools, argument validation, dispatcher activity and `InteractiveSafetyGate`.
  Only OS drivers and the model are synthetic. No app is launched or real user file changed by the suite.
- Regression checks deliberately request the wrong app, write incorrect contents and claim completion
  without acting. The evaluator detects each case from observed tool/driver results.

## Run the evaluations

```bash
./scripts/run-task-evaluations.sh /tmp/ivy-task-evaluations.json
```

The JSON report identifies schema/fixture version, provider/model and `offline-scripted` mode.
Each fixture records whether expectations passed, whether an action completed, wrong-action attempts,
unexpected effects, refusals, tool failures, model-call count and elapsed milliseconds. Correctly
handled failures/cancellations pass their fixture without being counted as completed actions.
The baseline is 8/8 passed, three completed actions, one refusal and four expected tool failures,
with zero wrong-action attempts or unexpected effects. Timing measures the offline pipeline;
it is not a live model's latency or a Mac task-completion benchmark.

Normal tests do not write reports. The script explicitly enables a synthetic-only report; its schema
exports identifiers, counts and timing, with no conversation text, credentials, audio or image data.
The suite never contacts a network endpoint or changes a production approval policy.

## Verification

- Full offline suite: 1,342 core tests and 45 native interface tests (1,387 total).
  Combined execution: 42.203 seconds, within the 60-second limit.
- Changed executable source lines: 107/107 covered (100%). This is changed-line coverage,
  not total project coverage. Coverage was measured before committing both slices.
- Swift 6 strict-concurrency build passed with no warnings/errors; unchanged warm build: 0.18 seconds.
  Switching out of coverage instrumentation required a 6.97-second rebuild; that is not the warm measurement.
- Evaluation command: two tests pass; all eight baseline cases pass and deliberate regressions are detected.
- Shell syntax, credential-pattern scan and `git diff --check` passed.
- No installed-app, DMG, live-model, mic/AirPods or physical desktop-control verification is claimed here.

## Next work

- The custom LLM HTTP adapter and reviewed provider selector need its real endpoint, authentication
  and request/response contract. This milestone supplies the interface, not a fabricated adapter.
- Compare live providers on explicitly selected inputs; extend these fixtures to full task-engine
  planning/execution and real-app acceptance. The current harness evaluates chat/tool dispatch.
- Build the floating task panel, then complete production computer control and hardware acceptance.
- Physical voice/device checks, files gallery, memory/usage audits and reviewed example export remain
  listed in [the roadmap](../docs/roadmap/phase-21-model-readiness.md).
