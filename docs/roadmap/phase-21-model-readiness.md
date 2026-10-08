# Phase 21 — Reliability and model readiness

Requested 2026-10-08. This is a delivery plan while Ivy's own LLM is developed. Existing
Gemini chat and Tavi Live voice remain usable throughout. It prioritizes parts of Phases
8–20; it does not mark those larger workstreams complete or restore the removed Pointer feature.

## First milestone

Reliable voice, a replaceable text/planning model boundary, repeatable task evaluations and
a floating task panel. Start with the reported companion upper drag-limit defect and voice
acceptance, then deliver the model/evaluation foundation before expanding the panel.

Each slice is delivered with its code, tests and verification report. Native visual work keeps
Ivy's own companion, leaf identity and design language. No phase has a fixed completion date.

## Build phases and acceptance

| Slice | Implementation | Required evidence |
| --- | --- | --- |
| 21.1 Reliability | Fix companion screen-edge placement; exercise PTT press/release, silence, unclear speech, interruption, approval, cross-app use, device changes and connection loss. Keep visible recovery and bounded response waits. | Native placement regression; automated voice lifecycle checks; physical keyboard/mic/AirPods checklist. Never label fixture passes as hardware acceptance. |
| 21.2 Model boundary | Introduce a provider-independent text/tool request and result interface for chat and planning. Wrap the current Gemini implementation; add a custom model adapter when its actual endpoint/contract is known. Keep recognition and speech output independent. | Existing Gemini behavior preserved; injected alternate provider completes a chat turn and task plan; cancellation/error/tool-call tests; unsupported image/tool capabilities rejected visibly. |
| 21.3 Task evaluations | Version synthetic requests and expected actions/results for app opening, folder lookup, document drafting, cancellation and failures. Run the same inputs against providers through the production validation/approval path. | Reproducible report of completion, wrong actions, safety refusals and latency, with provider/model/fixture versions. Offline and real-app evidence remain separate. No auto-approval in production. |
| 21.4 Floating task panel | Reuse the existing task engine and one shared Phase 19/20 panel. Show goal, actual step/progress, elapsed time, Stop, Open in Ivy and follow-up draft. | Live/saved/error/stopped states; companion-only background use; stale-task routing protection; keyboard/VoiceOver, light/dark and small-display reviews. Pause only if the engine supports it. |
| 21.5 Computer control | Wire existing coordinator and input tools into the production environment with scoped permissions, reviewed tasks, cancellation and user takeover. Start with Calculator/TextEdit, then browser/Finder, scrolling and dragging. | Real-app results verified from fresh observations; scope denial, revocation, stale target and stop tests. No autonomous production claim until integrated hardware acceptance passes. |
| 21.6 Generated files | Index actual task outputs with previews, task ownership, Open/Reveal and drag-out. Handle moved/missing files and permission loss. | Real file creation and ownership; safe previews; missing-file recovery; drag-out tested. Attachments are not misrepresented as persisted generated files. |
| 21.7 Memory controls | Audit existing memory controls first. Extend inspect/edit/delete, provenance, goal records and per-assistant sharing where missing. | Changes affect subsequent requests; deletion and isolation tests; explicit consent before sharing context. No secrets/audio/screenshots stored in memory. |
| 21.8 Usage dashboard | Audit existing usage collection first. Display reported tokens, model, tool durations, voice response latency and failures. Add cost estimates only with dated model-specific prices and available usage. | Known usage fixtures reconcile totals; unavailable data is labeled; estimates distinguished from billing; local retention/clear controls and accessible charts. |
| 21.9 Reviewed examples | Define a versioned request → intended action → arguments → expected result export. Start with synthetic examples; optionally export explicitly selected sessions after preview/redaction. | Export schema validation, deduplication/provenance, redaction and explicit selection. No automatic training-data collection or raw private-session export. |

## Dependencies and delivery order

21.1 → 21.2 + initial 21.3 → 21.4 → 21.5 → 21.6. Memory and usage audits can
follow the model boundary; reviewed examples depend on the evaluation schema and export review.
Begin with fixture-based measurements; provider comparisons and physical Mac acceptance are
separate opt-in runs. Do not send personal audio or screen captures as part of automated tests.

The custom LLM's API and capabilities are not yet specified. Isolate that uncertainty in its
adapter; do not promise voice, image understanding or tool calling that the model does not provide.
Provider selection must not transfer private history to a different endpoint without review.

## Quality and release gates

- Read `CONSTRAINTS.md`, `SPEC.md` and the relevant module plan before each implementation.
- Swift 6 strict build: zero warnings/errors; warm incremental build under five seconds.
- Full offline tests under 60 seconds; changed executable-line coverage at least 80%.
- Every tool still passes argument validation, classification and SafetyGate; risky actions require
  explicit approval. A model replacement, task proposal, voice command or schedule cannot approve.
- Stop/cancellation cannot replay tools or undo already-completed side effects by pretending they did not happen.
- Commit by coherent slice: implementation + tests, then shared release/docs updates. Push normal commits
  after verification; never force-push. A DMG update is distinct from publishing a GitHub release.
- Ship verified milestones incrementally; keep incomplete work listed in `tasks/remaining.md`.

## Current status

- [x] 21.1a Companion upper drag limit: native regression, fix and build-24 delivery.
- [ ] 21.1b Voice/device/hardware reliability acceptance.
- [ ] 21.2 Model boundary.
- [ ] 21.3 Provider/task evaluation harness.
- [ ] 21.4 Floating task panel.
- [ ] 21.5 Production computer control and hardware acceptance.
- [ ] 21.6 Generated-file gallery.
- [ ] 21.7 Memory controls audit and additions.
- [ ] 21.8 Usage/performance dashboard audit and additions.
- [ ] 21.9 Reviewed example export.

Related plans: [voice](phase-10-advanced-voice.md), [hardening](phase-08-production-hardening.md),
[computer control](phase-19-computer-control.md), [assistant workspace](phase-20-assistant-workspace.md).
