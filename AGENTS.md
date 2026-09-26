# Agent Guidelines for Ivy

Read `CONSTRAINTS.md` before writing code. Do not weaken it to make a change pass.

## Core Rules
1. **Spec-Driven**: Consult `SPEC.md` and module specs (`SPEC-*.md`) before starting any implementation.
2. **Quality Floor**: Zero secrets in source, zero unimplemented stubs, zero swallowed errors, and 100% Swift 6 strict concurrency compliance.
3. **Incremental Implementation**: All changes must be tested via unit tests (`swift test`) and verified cleanly (`swift build`) before advancing.
4. **Safety Always**: Never bypass confirmation for destructive tool calls.
