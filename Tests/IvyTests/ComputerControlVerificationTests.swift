import Testing
import Foundation
import CoreGraphics
import os
@testable import IvyCore

@Suite("Phase 19.6 - Result Verification and Bounded Recovery Tests")
struct ComputerControlVerificationTests {

    // MARK: - 1. API Success is Not Task Success Tests

    @Test("Verified text insertion: target element value contains typed text")
    func textInsertionVerified() {
        let preElement = UIElementSnapshot(id: "doc_body", role: "AXTextArea", value: "Hello ", frame: CGRect(x: 10, y: 10, width: 200, height: 100), isFocused: true)
        let postElement = UIElementSnapshot(id: "doc_body", role: "AXTextArea", value: "Hello World", frame: CGRect(x: 10, y: 10, width: 200, height: 100), isFocused: true)

        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)
        let preObs = DesktopObservation(sessionID: UUID(), token: ObservationToken(sessionID: UUID(), revision: 1), scope: scope, elements: [preElement])
        let postObs = DesktopObservation(sessionID: UUID(), token: ObservationToken(sessionID: UUID(), revision: 2), scope: scope, elements: [postElement])

        let action = ComputerControlAction(kind: .type, target: .elementID("doc_body"), text: "World")
        let outcome = ComputerActionVerifier.verifyActionOutcome(
            action: action,
            targetElement: preElement,
            preObservation: preObs,
            postObservation: postObs
        )

        guard case .verified(let explanation) = outcome else {
            Issue.record("Expected .verified, got \(outcome)")
            return
        }
        #expect(explanation.contains("Target field 'doc_body' contains expected text"))
    }

    @Test("Unchanged text insertion: field value remains identical despite API return")
    func textInsertionUnchangedDetected() {
        let preElement = UIElementSnapshot(id: "doc_body", role: "AXTextArea", value: "Frozen text", frame: CGRect(x: 10, y: 10, width: 200, height: 100), isFocused: true)
        let postElement = UIElementSnapshot(id: "doc_body", role: "AXTextArea", value: "Frozen text", frame: CGRect(x: 10, y: 10, width: 200, height: 100), isFocused: true)

        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)
        let preObs = DesktopObservation(sessionID: UUID(), token: ObservationToken(sessionID: UUID(), revision: 1), scope: scope, elements: [preElement])
        let postObs = DesktopObservation(sessionID: UUID(), token: ObservationToken(sessionID: UUID(), revision: 2), scope: scope, elements: [postElement])

        let action = ComputerControlAction(kind: .type, target: .elementID("doc_body"), text: "New text")
        let outcome = ComputerActionVerifier.verifyActionOutcome(
            action: action,
            targetElement: preElement,
            preObservation: preObs,
            postObservation: postObs
        )

        guard case .unchanged(let explanation) = outcome else {
            Issue.record("Expected .unchanged, got \(outcome)")
            return
        }
        #expect(explanation.contains("value did not change"))
    }

    @Test("Uncertain outcome: element hierarchy unchanged and text unconfirmed")
    func clickWithoutObservedChangeIsUncertain() {
        let preElement = UIElementSnapshot(id: "btn_save", role: "AXButton", title: "Save", frame: CGRect(x: 50, y: 50, width: 60, height: 25))
        let postElement = UIElementSnapshot(id: "btn_save", role: "AXButton", title: "Save", frame: CGRect(x: 50, y: 50, width: 60, height: 25))

        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)
        let preObs = DesktopObservation(sessionID: UUID(), token: ObservationToken(sessionID: UUID(), revision: 1), scope: scope, elements: [preElement])
        let postObs = DesktopObservation(sessionID: UUID(), token: ObservationToken(sessionID: UUID(), revision: 2), scope: scope, elements: [postElement])

        let action = ComputerControlAction(kind: .click, target: .elementID("btn_save"))
        let outcome = ComputerActionVerifier.verifyActionOutcome(
            action: action,
            targetElement: preElement,
            preObservation: preObs,
            postObservation: postObs
        )

        guard case .uncertain(let explanation) = outcome else {
            Issue.record("Expected .uncertain, got \(outcome)")
            return
        }
        #expect(explanation.contains("accessibility hierarchy reflects no visible state transition"))
    }

    // MARK: - 2. Changed Targets Invalidate Requests Tests

    @Test("Materially displaced target element invalidates action request")
    func materiallyDisplacedTargetInvalidated() {
        let originalElement = UIElementSnapshot(id: "btn_submit", role: "AXButton", title: "Submit", frame: CGRect(x: 100, y: 100, width: 80, height: 30))
        // Moved by 25 points horizontally
        let movedElement = UIElementSnapshot(id: "btn_submit", role: "AXButton", title: "Submit", frame: CGRect(x: 125, y: 100, width: 80, height: 30))

        let scope = ComputerControlScope(bundleIdentifier: "com.apple.calculator", isAuthorized: true)
        let preObs = DesktopObservation(sessionID: UUID(), token: ObservationToken(sessionID: UUID(), revision: 1), scope: scope, elements: [originalElement])
        let freshObs = DesktopObservation(sessionID: UUID(), token: ObservationToken(sessionID: UUID(), revision: 2), scope: scope, elements: [movedElement])

        let result = ComputerActionVerifier.verifyTargetFreshness(
            elementID: "btn_submit",
            original: preObs,
            fresh: freshObs
        )

        guard case .failure(let failure) = result, case .targetInvalidated(let reason) = failure else {
            Issue.record("Expected .targetInvalidated due to displacement, got \(result)")
            return
        }
        #expect(reason.contains("moved materially"))
    }

    @Test("Missing or deleted target element invalidates request")
    func missingTargetInvalidatesRequest() {
        let originalElement = UIElementSnapshot(id: "modal_dialog_btn", role: "AXButton", title: "OK", frame: CGRect(x: 50, y: 50, width: 50, height: 25))

        let scope = ComputerControlScope(bundleIdentifier: "com.apple.calculator", isAuthorized: true)
        let preObs = DesktopObservation(sessionID: UUID(), token: ObservationToken(sessionID: UUID(), revision: 1), scope: scope, elements: [originalElement])
        // Fresh observation where dialog was dismissed
        let freshObs = DesktopObservation(sessionID: UUID(), token: ObservationToken(sessionID: UUID(), revision: 2), scope: scope, elements: [])

        let result = ComputerActionVerifier.verifyTargetFreshness(
            elementID: "modal_dialog_btn",
            original: preObs,
            fresh: freshObs
        )

        guard case .failure(let failure) = result, case .targetInvalidated(let reason) = failure else {
            Issue.record("Expected .targetInvalidated due to disappearance, got \(result)")
            return
        }
        #expect(reason.contains("no longer exists"))
    }

    @Test("Target application change invalidates request")
    func targetAppChangeInvalidatesRequest() {
        let el = UIElementSnapshot(id: "btn_1", role: "AXButton", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        let scope1 = ComputerControlScope(bundleIdentifier: "com.apple.calculator", isAuthorized: true)
        let scope2 = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)

        let preObs = DesktopObservation(sessionID: UUID(), token: ObservationToken(sessionID: UUID(), revision: 1), scope: scope1, elements: [el])
        let freshObs = DesktopObservation(sessionID: UUID(), token: ObservationToken(sessionID: UUID(), revision: 2), scope: scope2, elements: [el])

        let result = ComputerActionVerifier.verifyTargetFreshness(
            elementID: "btn_1",
            original: preObs,
            fresh: freshObs
        )

        guard case .failure(let failure) = result, case .targetInvalidated(let reason) = failure else {
            Issue.record("Expected .targetInvalidated due to app change, got \(result)")
            return
        }
        #expect(reason.contains("Active application changed"))
    }

    // MARK: - 3. Irreversible Action Classification Tests

    @Test("Submit buttons and key chords identified as irreversible")
    func irreversibleActionIdentification() {
        let submitBtn = UIElementSnapshot(id: "submit_btn", role: "AXButton", title: "Submit Order", frame: CGRect(x: 10, y: 10, width: 80, height: 30))
        let ordinaryBtn = UIElementSnapshot(id: "view_mode", role: "AXButton", title: "View Mode", frame: CGRect(x: 10, y: 10, width: 80, height: 30))

        let clickSubmit = ComputerControlAction(kind: .click, target: .elementID("submit_btn"))
        let clickOrdinary = ComputerControlAction(kind: .click, target: .elementID("view_mode"))
        let keyReturn = ComputerControlAction(kind: .key, text: "Return")
        let keyChar = ComputerControlAction(kind: .key, text: "A")
        let scroll = ComputerControlAction(kind: .scroll, deltaX: 0, deltaY: 100)

        #expect(IrreversibleActionClassifier.isIrreversible(action: clickSubmit, targetElement: submitBtn) == true)
        #expect(IrreversibleActionClassifier.isIrreversible(action: clickOrdinary, targetElement: ordinaryBtn) == false)
        #expect(IrreversibleActionClassifier.isIrreversible(action: keyReturn, targetElement: nil) == true)
        #expect(IrreversibleActionClassifier.isIrreversible(action: keyChar, targetElement: nil) == false)
        #expect(IrreversibleActionClassifier.isIrreversible(action: scroll, targetElement: nil) == false)
    }

    // MARK: - 4. Stop Works While Model or Observation Waits Tests

    private final class DelayingDecisionProvider: ComputerDecisionProviding, Sendable {
        func decideNextAction(
            goal: String,
            scope: ComputerControlScope,
            observation: DesktopObservation,
            history: [ComputerActionHistoryItem],
            availableTools: [FunctionDeclaration]
        ) async throws -> ComputerDecision {
            try await Task.sleep(nanoseconds: 500_000_000)
            return .finish(summary: "Done")
        }
    }

    @Test("Stop cancels in-flight coordinator loop cleanly")
    @MainActor
    func stopCancelsInFlightCoordinatorWait() async throws {
        let session = ComputerControlSession()
        let mockDriver = MockComputerInputDriver()
        let observationProvider = MockDesktopObservationProvider(defaultElements: [])
        let decisionProvider = DelayingDecisionProvider()
        let feedbackManager = MockComputerControlFeedbackManager()

        let tools = ComputerControlTools.all(session: session, driver: mockDriver, observationProvider: observationProvider)
        let registry = ToolRegistry(tools: tools)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: PassThroughSafetyGate(), permissions: MockPermissionManager())

        let coordinator = ComputerControlCoordinator(
            session: session,
            decisionProvider: decisionProvider,
            dispatcher: dispatcher,
            observationProvider: observationProvider,
            feedbackController: feedbackManager
        )

        let scope = ComputerControlScope(bundleIdentifier: "com.apple.calculator", isAuthorized: true)
        _ = session.start(goal: "Test Stop", scope: scope)

        // Launch runLoop in background task
        let loopTask = Task { @MainActor in
            await coordinator.runLoop(
                runID: UUID(),
                goal: "Test Stop",
                scope: scope,
                budget: TaskBudget(),
                onStepCreated: { _ in },
                onStepUpdated: { _ in },
                onToolCallDispatched: { },
                isTaskCancelled: { false }
            )
        }

        // Allow loop to start observation
        try await Task.sleep(nanoseconds: 10_000_000)

        // Cancel coordinator while loop is active
        coordinator.cancel()

        let result = await loopTask.value
        #expect(result == .cancelled)
        #expect(session.state.isActive == false)
        #expect(coordinator.isCancelled == true)
    }
}
