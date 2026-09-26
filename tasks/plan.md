# Implementation Plan: Ivy macOS Assistant

## Overview
Ivy is a native macOS menu bar assistant built with Swift and SwiftUI that connects directly to the Gemini 2.0 Flash REST API. Ivy possesses a distinct sarcastic persona, handles conversational back-and-forth, and eventually orchestrates system tools under strict safety gates.

This plan focuses on delivering **Phase 1: Core Text-Only Menu Bar Chat**, establishing the project skeleton, data models, REST client, brain state machine, and SwiftUI menu bar popover UI, while outlining the downstream roadmap for Phases 2–7.

---

## Architecture Decisions

1. **SPM Package Structure with Core Library**:
   - `IvyCore`: Pure Swift domain library containing models, REST client, turn management, and Ivy persona. This enables headless CLI unit testing (`swift test`) without spinning up the macOS UI harness.
   - `Ivy`: Native macOS executable target containing `IvyApp` (`MenuBarExtra`), popovers, views, and assets.
2. **Swift 6 Strict Concurrency**:
   - Compiling with `-strict-concurrency=complete`. All models conform to `Sendable`. `IvyBrain` is `@MainActor` isolated. Networking is decoupled in asynchronous tasks.
3. **No Third-Party SDKs for Gemini**:
   - Standard Foundation `URLSession` and custom `Codable` structs matching Google Generative Language REST v1beta directly.
4. **Direct API Key Configuration (Phase 1)**:
   - For Phase 1 testing and execution, the API key can be supplied via a settings input in the popover or read from the `GEMINI_API_KEY` process environment, preparing for the Keychain helper in Phase 5.

---

## Phase-by-Phase Roadmap

| Phase | Milestone | Focus |
|---|---|---|
| **Phase 1** | **Core Loop (Current Scope)** | Text-only menu bar app, Gemini REST client, Ivy sarcastic persona, turn history |
| **Phase 2** | **Tool Layer** | Function calling declarations, execution of AppleScript, shell, apps, calendar, files |
| **Phase 3** | **Confirmation Gate** | Safe vs Risky tool classification, in-character confirmation modal before execution |
| **Phase 4** | **Voice In & Out** | Push-to-talk hotkey + `SFSpeechRecognizer`, `AVSpeechSynthesizer` & ElevenLabs REST |
| **Phase 5** | **Persistence & Settings** | macOS Keychain for API keys, JSON session history persistence across restarts |
| **Phase 6** | **Permissions & Sandboxing** | Entitlements, Info.plist privacy descriptions, runtime permission recovery |
| **Phase 7** | **Portfolio Polish** | Dynamic status menu bar icons, notarization scripts, architecture diagram, demo GIF |

---

## Phase 1 Task List

### Phase 1.1: Foundation & Project Setup
- [ ] Task 1.1: Initialize Swift Package with `IvyCore`, `Ivy` executable, and `IvyTests` targets
- [ ] Task 1.2: Define core domain models (`ChatMessage`, `MessageRole`) and Ivy Persona system instruction

### Checkpoint: Foundation
- [ ] `swift build` and `swift test` succeed with zero errors and zero warnings under Swift 6 strict concurrency.

### Phase 1.2: Gemini REST Client
- [ ] Task 1.3: Implement Gemini REST request/response DTOs (`GeminiRequest`, `GeminiResponse`, `Content`, `Part`)
- [ ] Task 1.4: Implement `GeminiClient` with `URLSession` and error handling
- [ ] Task 1.5: Unit tests for Gemini DTO serialization, mock HTTP responses, and error handling

### Checkpoint: REST Client
- [ ] All unit tests pass with `swift test`. DTO payload matches Google Generative Language REST v1beta spec.

### Phase 1.3: State Machine & Brain
- [ ] Task 1.6: Implement `IvyBrain` (`@MainActor ObservableObject`) managing conversation turns, loading state, and error alerts
- [ ] Task 1.7: Unit tests for `IvyBrain` turn logic and persona integration

### Checkpoint: Brain Logic
- [ ] Turn handling verified: user text added -> client called -> model reply appended -> loading state reset.

### Phase 1.4: Native Menu Bar UI
- [ ] Task 1.8: Build `IvyPopoverView`, message bubbles, scrollview, and input bar with keyboard shortcuts
- [ ] Task 1.9: Configure `IvyApp` with `MenuBarExtra(.window)` and accessory mode (`LSUIElement`)
- [ ] Task 1.10: End-to-end verification of menu bar chat with live Gemini API key

### Checkpoint: Phase 1 Complete
- [ ] Ivy runs in macOS menu bar.
- [ ] User can send prompts and receive sharp, sarcastic Ivy responses.
- [ ] Code passes all constraints in `CONSTRAINTS.md`.

---

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Swift 6 concurrency warnings with `URLSession` / `@MainActor` | High | Decouple network client with clean `Sendable` types and isolated async methods. |
| Popover closing unexpectedly on user input | Med | Use `.menuBarExtraStyle(.window)` rather than classic `.menu` to keep window interactive. |
| Missing API key leads to crash or confusing UI | Med | Graceful error state in `IvyBrain` prompting the user to provide an API key in-character. |
| In-character persona compromised during error states | Low | Persona instructions and error alerts maintain dry wit and sarcastic personality. |

---

## Open Questions & Future Decisions
- **Settings Sheet in Phase 1**: Should a minimal API key text field be integrated directly into the popover header/footer in Phase 1, or solely use `GEMINI_API_KEY` environment variable? (Recommendation: support both).
