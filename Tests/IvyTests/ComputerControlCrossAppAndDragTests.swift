import Testing
import Foundation
import CoreGraphics
import os
@testable import IvyCore

@Suite("Phase 19.8 - Dragging, Selections and Cross-App Tasks Tests")
struct ComputerControlCrossAppAndDragTests {

    private final class TestMockSafetyGate: SafetyGateProtocol, Sendable {
        let autoApprove: Bool
        init(autoApprove: Bool = true) { self.autoApprove = autoApprove }
        func evaluate(tool: any IvyTool, call: FunctionCall) async -> SafetyDecision {
            autoApprove ? .approve : .reject(reason: "Declined")
        }
    }

    @Test("Drag interpolates across bounded path points and releases mouse button")
    func dragInterpolatesBoundedPath() async throws {
        let driver = MockComputerInputDriver(isAuthorized: true)
        let start = CGPoint(x: 100, y: 100)
        let end = CGPoint(x: 500, y: 100) // 400pt distance -> 16 steps

        try await driver.drag(from: start, to: end, button: .left)

        // Mouse button must be released after completion
        #expect(driver.isMouseDown == false)
        #expect(driver.currentCursorPosition == end)
        #expect(driver.recordedEvents.contains(.move(point: start)))
        #expect(driver.recordedEvents.contains(.drag(start: start, end: end, button: .left)))
    }

    @Test("Cancellation mid-drag releases mouse button immediately")
    func cancellationMidDragReleasesMouse() async throws {
        let driver = MockComputerInputDriver(isAuthorized: true)
        let start = CGPoint(x: 50, y: 50)
        let end = CGPoint(x: 800, y: 800)

        // Create a task that cancels itself during execution
        let dragTask = Task {
            try await driver.drag(from: start, to: end, button: .left)
        }
        dragTask.cancel()

        _ = await dragTask.result

        // Regardless of cancellation, defer block ensures mouse button is not left held down
        #expect(driver.isMouseDown == false)
    }

    @Test("Coordinator cancellation calls driver.releaseAllHeldInputs")
    @MainActor
    func coordinatorCancelReleasesHeldInputs() async throws {
        let session = ComputerControlSession()
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)
        _ = session.start(goal: "Test cancel cleanup", scope: scope)

        let driver = MockComputerInputDriver(isAuthorized: true)
        let obsProvider = MockDesktopObservationProvider()
        let decisionProvider = MockComputerDecisionProvider()
        let registry = ToolRegistry()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: TestMockSafetyGate())

        let coordinator = ComputerControlCoordinator(
            session: session,
            decisionProvider: decisionProvider,
            dispatcher: dispatcher,
            observationProvider: obsProvider,
            driver: driver
        )

        coordinator.cancel()

        // Wait a few milliseconds for async release task
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(coordinator.isCancelled)
        #expect(driver.isMouseDown == false)
        #expect(driver.recordedEvents.contains(.releaseAll))
    }

    @Test("UITypeTool without replace types text without select-all chord")
    func typeWithoutReplace() async throws {
        let session = ComputerControlSession()
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)
        _ = session.start(goal: "Type normal text", scope: scope)

        let driver = MockComputerInputDriver(isAuthorized: true)
        let typeTool = UITypeTool(session: session, driver: driver)

        let call = FunctionCall(
            name: "ui_type",
            args: ["text": AnyCodable("Appending text"), "replace": AnyCodable(false)]
        )

        let result = try await typeTool.execute(arguments: call.args)
        #expect(!result.isError)
        #expect(result.output.contains("Typed 14 characters"))

        // Should NOT contain Cmd+A chord
        let hasCmdA = driver.recordedEvents.contains(.key(key: "a", modifiers: ["cmd"]))
        #expect(!hasCmdA)
        #expect(driver.recordedEvents.contains(.type(text: "Appending text")))
    }

    @Test("UITypeTool with replace: true explicitly emits select-all chord before typing")
    func typeWithExplicitReplace() async throws {
        let session = ComputerControlSession()
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)
        _ = session.start(goal: "Replace text in document", scope: scope)

        let driver = MockComputerInputDriver(isAuthorized: true)
        let typeTool = UITypeTool(session: session, driver: driver)

        let call = FunctionCall(
            name: "ui_type",
            args: ["text": AnyCodable("Overwritten text"), "replace": AnyCodable(true)]
        )

        // Confirmation clearly communicates replace mode
        let confirmation = typeTool.confirmation(for: call.args)
        #expect(confirmation?.title == "Replace Text")
        #expect(confirmation?.detail.contains("Replace Existing: true") == true)

        let result = try await typeTool.execute(arguments: call.args)
        #expect(!result.isError)
        #expect(result.output.contains("Replaced existing text with 16 characters"))

        // Must emit Cmd+A chord before typing
        let cmdAIndex = driver.recordedEvents.firstIndex(of: .key(key: "a", modifiers: ["cmd"]))
        let typeIndex = driver.recordedEvents.firstIndex(of: .type(text: "Overwritten text"))
        #expect(cmdAIndex != nil)
        #expect(typeIndex != nil)
        #expect(cmdAIndex! < typeIndex!)
    }

    @Test("Targeting a new application triggers mandatory scope review pause")
    @MainActor
    func targetingNewAppRequiresScopeReview() async throws {
        let session = ComputerControlSession()
        let initialScope = ComputerControlScope(bundleIdentifier: "com.apple.Safari", isAuthorized: true)
        _ = session.start(goal: "Cross app workflow", scope: initialScope)

        let driver = MockComputerInputDriver(isAuthorized: true)
        let obsProvider = MockDesktopObservationProvider()
        let registry = ToolRegistry(tools: ComputerControlTools.all(session: session, driver: driver, observationProvider: obsProvider))
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: TestMockSafetyGate())

        // Decision attempts to target TextEdit while session is scoped to Safari
        let decisionProvider = MockComputerDecisionProvider()
        decisionProvider.enqueue(.action(FunctionCall(
            name: "ui_click",
            args: [
                "bundle_id": AnyCodable("com.apple.TextEdit"),
                "x": AnyCodable(200.0),
                "y": AnyCodable(150.0)
            ],
            id: "call-cross-app"
        )))

        let coordinator = ComputerControlCoordinator(
            session: session,
            decisionProvider: decisionProvider,
            dispatcher: dispatcher,
            observationProvider: obsProvider,
            driver: driver
        )

        var createdSteps: [TaskStep] = []
        var updatedSteps: [TaskStep] = []
        let result = await coordinator.runLoop(
            runID: UUID(),
            goal: "Cross app workflow",
            scope: initialScope,
            budget: TaskBudget(maxSteps: 10, maxToolCalls: 20, maxDuration: 120),
            onStepCreated: { createdSteps.append($0) },
            onStepUpdated: { updatedSteps.append($0) },
            onToolCallDispatched: {},
            isTaskCancelled: { false }
        )

        // Must pause for scope review, not execute click
        guard case .paused(let pause) = result else {
            Issue.record("Expected pause for scope review")
            return
        }
        guard case .stepFailed(_, let reason) = pause else {
            Issue.record("Expected stepFailed with scope review message")
            return
        }
        #expect(reason.contains("scope authorization"))
        #expect(session.state == .paused(goal: "Cross app workflow", scope: initialScope, reason: .scopeReviewRequired))
    }

    @Test("Targeting prohibited credential application in cross-app task is rejected")
    @MainActor
    func targetingProhibitedAppRejected() async throws {
        let session = ComputerControlSession()
        let initialScope = ComputerControlScope(bundleIdentifier: "com.apple.Safari", isAuthorized: true)
        _ = session.start(goal: "Attempt security takeover", scope: initialScope)

        let driver = MockComputerInputDriver(isAuthorized: true)
        let obsProvider = MockDesktopObservationProvider()
        let registry = ToolRegistry(tools: ComputerControlTools.all(session: session, driver: driver, observationProvider: obsProvider))
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: TestMockSafetyGate())

        let decisionProvider = MockComputerDecisionProvider()
        decisionProvider.enqueue(.action(FunctionCall(
            name: "ui_click",
            args: [
                "bundle_id": AnyCodable("com.apple.keychainaccess"),
                "x": AnyCodable(100.0),
                "y": AnyCodable(100.0)
            ],
            id: "call-prohibited"
        )))

        let coordinator = ComputerControlCoordinator(
            session: session,
            decisionProvider: decisionProvider,
            dispatcher: dispatcher,
            observationProvider: obsProvider,
            driver: driver
        )

        var createdSteps: [TaskStep] = []
        var updatedSteps: [TaskStep] = []
        let result = await coordinator.runLoop(
            runID: UUID(),
            goal: "Attempt security takeover",
            scope: initialScope,
            budget: TaskBudget(maxSteps: 10, maxToolCalls: 20, maxDuration: 120),
            onStepCreated: { createdSteps.append($0) },
            onStepUpdated: { updatedSteps.append($0) },
            onToolCallDispatched: {},
            isTaskCancelled: { false }
        )

        guard case .paused(let pause) = result else {
            Issue.record("Expected pause")
            return
        }
        guard case .stepFailed(_, let reason) = pause else {
            Issue.record("Expected stepFailed")
            return
        }
        #expect(reason.contains("prohibited"))
    }

    @Test("Authorized scope transition updates active scope cleanly")
    func authorizedScopeTransition() throws {
        let session = ComputerControlSession()
        let initialScope = ComputerControlScope(bundleIdentifier: "com.apple.Safari", isAuthorized: true)
        guard case .success = session.start(goal: "Copy Safari to TextEdit", scope: initialScope) else {
            Issue.record("Start failed")
            return
        }

        // Pause for scope review
        session.pause(reason: .scopeReviewRequired)

        // User reviews and authorizes new scope
        let textEditScope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)
        let transitionResult = session.transitionScope(to: textEditScope)

        guard case .success(let newToken) = transitionResult else {
            Issue.record("Transition failed")
            return
        }

        #expect(session.currentScope?.bundleIdentifier == "com.apple.TextEdit")
        #expect(session.state.isActive)
        #expect(session.currentToken?.id == newToken.id)
    }

    @Test("Budgets are enforced continuously across multi-app task steps")
    @MainActor
    func budgetsEnforcedAcrossTransitions() async throws {
        let session = ComputerControlSession()
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.Safari", isAuthorized: true)
        _ = session.start(goal: "Long cross-app task", scope: scope)

        let driver = MockComputerInputDriver(isAuthorized: true)
        let obsProvider = MockDesktopObservationProvider()
        let registry = ToolRegistry(tools: ComputerControlTools.all(session: session, driver: driver, observationProvider: obsProvider))
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: TestMockSafetyGate())
        let decisionProvider = MockComputerDecisionProvider()

        let coordinator = ComputerControlCoordinator(
            session: session,
            decisionProvider: decisionProvider,
            dispatcher: dispatcher,
            observationProvider: obsProvider,
            driver: driver
        )

        // Existing steps = 4 with budget max = 5
        let result = await coordinator.runLoop(
            runID: UUID(),
            goal: "Long cross-app task",
            scope: scope,
            budget: TaskBudget(maxSteps: 5, maxToolCalls: 10, maxDuration: 60),
            existingStepCount: 5, // Already reached 5 steps
            existingToolCalls: 8,
            onStepCreated: { _ in },
            onStepUpdated: { _ in },
            onToolCallDispatched: {},
            isTaskCancelled: { false }
        )

        // Must pause due to budget exhaustion without running further decisions
        guard case .paused(let pause) = result else {
            Issue.record("Expected budget pause")
            return
        }
        guard case .budget(let msg) = pause else {
            Issue.record("Expected budget reason")
            return
        }
        #expect(msg.contains("step limit"))
        #expect(session.state == .paused(goal: "Long cross-app task", scope: scope, reason: .budgetExhausted))
    }
}
