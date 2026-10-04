import Testing
import Foundation
import CoreGraphics
import os
@testable import IvyCore

@Suite("Phase 19.5 - Computer Control Coordinator & Adaptive Mode Tests")
struct ComputerControlCoordinatorTests {

    @MainActor
    private final class Harness {
        let session: ComputerControlSession
        let mockDriver: MockComputerInputDriver
        let mockTraverser: MockAccessibilityTreeTraverser
        let observationProvider: MockDesktopObservationProvider
        let decisionProvider: MockComputerDecisionProvider
        let feedbackManager: MockComputerControlFeedbackManager
        let dispatcher: ToolDispatcher
        let coordinator: ComputerControlCoordinator
        let engine: TaskEngine
        let scope: ComputerControlScope

        var denyCount = 0

        init(
            elements: [UIElementSnapshot] = [],
            autoApproveConfirmation: Bool = true
        ) {
            self.session = ComputerControlSession()
            self.mockDriver = MockComputerInputDriver()
            self.mockTraverser = MockAccessibilityTreeTraverser(mockElements: elements)
            self.observationProvider = MockDesktopObservationProvider(defaultElements: elements)
            self.decisionProvider = MockComputerDecisionProvider()
            self.feedbackManager = MockComputerControlFeedbackManager()

            let tools = ComputerControlTools.all(
                session: session,
                driver: mockDriver,
                observationProvider: observationProvider
            )
            let registry = ToolRegistry(tools: tools)
            let gate = MockSafetyGate(autoApprove: autoApproveConfirmation)
            self.dispatcher = ToolDispatcher(
                registry: registry,
                safetyGate: gate,
                permissions: MockPermissionManager()
            )

            self.coordinator = ComputerControlCoordinator(
                session: session,
                decisionProvider: decisionProvider,
                dispatcher: dispatcher,
                observationProvider: observationProvider,
                feedbackController: feedbackManager
            )

            self.scope = ComputerControlScope(
                bundleIdentifier: "com.apple.calculator",
                processIdentifier: 1001,
                windowTitle: "Calculator",
                isAuthorized: true
            )

            let planner = ScriptedPlanner([])
            var onDeny: () -> Void = {}
            self.engine = TaskEngine(
                planner: planner,
                dispatcher: dispatcher,
                denyPendingConfirmation: { onDeny() },
                coordinator: coordinator
            )
            onDeny = { [weak self] in
                self?.denyCount += 1
            }
        }
    }

    private final class MockSafetyGate: SafetyGateProtocol, Sendable {
        let autoApprove: Bool

        init(autoApprove: Bool = true) {
            self.autoApprove = autoApprove
        }

        func evaluate(tool: any IvyTool, call: FunctionCall) async -> SafetyDecision {
            if autoApprove || tool.safetyClassification == .safe {
                return .approve
            } else {
                return .reject(reason: "User declined action card.")
            }
        }
    }

    private final class ScriptedPlanner: TaskPlanning, @unchecked Sendable {
        let replies: [String]
        private let callIndex = OSAllocatedUnfairLock(initialState: 0)

        init(_ replies: [String]) {
            self.replies = replies
        }

        func plan(goal: String, context: String, tools: [FunctionDeclaration]) async throws -> String {
            let index = callIndex.withLock { idx -> Int in
                let current = idx
                idx += 1
                return current
            }
            guard index < replies.count else { return "{\"steps\":[]}" }
            return replies[index]
        }
    }

    // MARK: - 1. One Action per Decision Tests

    @Test("Model returning multiple actions in one decision is rejected")
    func multipleActionsDisallowed() async throws {
        let element = UIElementSnapshot(id: "btn_1", role: "AXButton", title: "1", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        let observation = DesktopObservation(
            sessionID: UUID(),
            token: ObservationToken(sessionID: UUID(), revision: 1),
            scope: ComputerControlScope(bundleIdentifier: "com.apple.calculator", isAuthorized: true),
            elements: [element]
        )

        let multipleCalls = [
            FunctionCall(name: "ui_click", args: ["element_id": AnyCodable("btn_1")]),
            FunctionCall(name: "ui_click", args: ["element_id": "btn_1"])
        ]
        let response = ModelTurnResponse(functionCalls: multipleCalls)

        #expect(throws: ComputerDecisionError.multipleActionsDisallowed(count: 2)) {
            _ = try GeminiComputerDecisionProvider.parseResponse(response, observation: observation)
        }
    }

    @Test("Single valid action parses successfully")
    func singleValidActionParsed() async throws {
        let element = UIElementSnapshot(id: "btn_equals", role: "AXButton", title: "=", frame: CGRect(x: 50, y: 50, width: 30, height: 30))
        let observation = DesktopObservation(
            sessionID: UUID(),
            token: ObservationToken(sessionID: UUID(), revision: 1),
            scope: ComputerControlScope(bundleIdentifier: "com.apple.calculator", isAuthorized: true),
            elements: [element]
        )

        let singleCall = [FunctionCall(name: "ui_click", args: ["element_id": AnyCodable("btn_equals")])]
        let response = ModelTurnResponse(functionCalls: singleCall)

        let decision = try GeminiComputerDecisionProvider.parseResponse(response, observation: observation)
        if case .action(let call, _) = decision {
            #expect(call.name == "ui_click")
            #expect(call.args["element_id"]?.stringValue == "btn_equals")
        } else {
            Issue.record("Expected .action decision")
        }
    }

    // MARK: - 2. Invalid / Unknown Output Cannot Execute Tests

    @Test("Unknown action tools are rejected and cannot execute")
    func unknownActionRejected() async throws {
        let observation = DesktopObservation(
            sessionID: UUID(),
            token: ObservationToken(sessionID: UUID(), revision: 1),
            scope: ComputerControlScope(bundleIdentifier: "com.apple.calculator", isAuthorized: true),
            elements: []
        )

        let call = FunctionCall(name: "raw_shell_exec", args: ["command": AnyCodable("whoami")])
        let response = ModelTurnResponse(functionCalls: [call])

        #expect(throws: ComputerDecisionError.unknownAction("raw_shell_exec")) {
            _ = try GeminiComputerDecisionProvider.parseResponse(response, observation: observation)
        }
    }

    @Test("Hallucinated element ID not present in observation is rejected")
    func hallucinatedElementIDRejected() async throws {
        let existing = UIElementSnapshot(id: "real_btn", role: "AXButton", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        let observation = DesktopObservation(
            sessionID: UUID(),
            token: ObservationToken(sessionID: UUID(), revision: 1),
            scope: ComputerControlScope(bundleIdentifier: "com.apple.calculator", isAuthorized: true),
            elements: [existing]
        )

        let call = FunctionCall(name: "ui_click", args: ["element_id": AnyCodable("fabricated_phantom_button")])
        let response = ModelTurnResponse(functionCalls: [call])

        #expect(throws: ComputerDecisionError.elementNotFoundInObservation(elementID: "fabricated_phantom_button")) {
            _ = try GeminiComputerDecisionProvider.parseResponse(response, observation: observation)
        }
    }

    @Test("Secure text fields are protected and prohibited from target actions")
    func secureTextFieldProtected() async throws {
        let secureField = UIElementSnapshot(id: "pwd_input", role: "AXSecureTextField", frame: CGRect(x: 10, y: 10, width: 200, height: 30))
        let observation = DesktopObservation(
            sessionID: UUID(),
            token: ObservationToken(sessionID: UUID(), revision: 1),
            scope: ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true),
            elements: [secureField]
        )

        let call = FunctionCall(name: "ui_click", args: ["element_id": AnyCodable("pwd_input")])
        let response = ModelTurnResponse(functionCalls: [call])

        #expect(throws: ComputerDecisionError.prohibitedControl("Target element 'pwd_input' is a secure text field.")) {
            _ = try GeminiComputerDecisionProvider.parseResponse(response, observation: observation)
        }
    }

    @Test("Out of bounds coordinates are rejected")
    func outOfBoundsCoordinatesRejected() async throws {
        let observation = DesktopObservation(
            sessionID: UUID(),
            token: ObservationToken(sessionID: UUID(), revision: 1),
            scope: ComputerControlScope(bundleIdentifier: "com.apple.calculator", isAuthorized: true),
            elements: []
        )

        let call = FunctionCall(name: "ui_click", args: ["x": AnyCodable(-50.0), "y": AnyCodable(100.0)])
        let response = ModelTurnResponse(functionCalls: [call])

        #expect(throws: ComputerDecisionError.coordinatesOutOfBounds(x: -50.0, y: 100.0)) {
            _ = try GeminiComputerDecisionProvider.parseResponse(response, observation: observation)
        }
    }

    // MARK: - 3. Observed State Follows Each Action Tests

    @Test("Fresh observation token follows each action and target updates in panel")
    @MainActor
    func freshObservationFollowsEachAction() async throws {
        let btn1 = UIElementSnapshot(id: "btn_1", role: "AXButton", title: "1", frame: CGRect(x: 100, y: 100, width: 40, height: 40))
        let harness = Harness(elements: [btn1])

        _ = harness.session.start(goal: "Add numbers", scope: harness.scope)

        // Queue action 1: click btn_1
        harness.decisionProvider.enqueue(.action(
            FunctionCall(name: "ui_click", args: ["element_id": AnyCodable("btn_1")]),
            explanation: "Clicking button 1"
        ))
        // Queue action 2: finish
        harness.decisionProvider.enqueue(.finish(summary: "Calculation done"))

        var stepsCreated: [TaskStep] = []
        var stepsUpdated: [TaskStep] = []
        var toolCallsDispatched = 0

        let result = await harness.coordinator.runLoop(
            runID: UUID(),
            goal: "Add numbers",
            scope: harness.scope,
            budget: TaskBudget(maxSteps: 5, maxToolCalls: 10),
            onStepCreated: { stepsCreated.append($0) },
            onStepUpdated: { stepsUpdated.append($0) },
            onToolCallDispatched: { toolCallsDispatched += 1 },
            isTaskCancelled: { false }
        )

        #expect(result == .succeeded(summary: "Calculation done"))
        #expect(stepsCreated.count == 1)
        #expect(stepsCreated.first?.tool == "ui_click")
        #expect(toolCallsDispatched == 3) // ui_observe, ui_click, ui_observe
        #expect(harness.feedbackManager.targetUpdates.count >= 1)
        #expect(harness.feedbackManager.targetUpdates.first?.element?.id == "btn_1")
    }

    // MARK: - 4. Budgets and All Primitive Calls Tracked Tests

    @Test("Step limit budget pause is enforced")
    @MainActor
    func stepLimitBudgetPauseEnforced() async throws {
        let btn = UIElementSnapshot(id: "btn_key", role: "AXButton", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        let harness = Harness(elements: [btn])
        _ = harness.session.start(goal: "Looping", scope: harness.scope)

        // Enqueue actions exceeding maxSteps = 2
        for i in 1...5 {
            harness.decisionProvider.enqueue(.action(
                FunctionCall(name: "ui_click", args: ["element_id": AnyCodable("btn_key")]),
                explanation: "Click \(i)"
            ))
        }

        var stepsCount = 0
        let result = await harness.coordinator.runLoop(
            runID: UUID(),
            goal: "Looping",
            scope: harness.scope,
            budget: TaskBudget(maxSteps: 2, maxToolCalls: 20),
            onStepCreated: { _ in stepsCount += 1 },
            onStepUpdated: { _ in },
            onToolCallDispatched: { },
            isTaskCancelled: { false }
        )

        guard case .paused(let pause) = result else {
            Issue.record("Expected budget pause, got \(result)")
            return
        }
        #expect(pause == .budget("Action step limit of 2 steps reached."))
        #expect(stepsCount == 2)
    }

    @Test("Tool calls budget pause includes observation calls")
    @MainActor
    func toolCallBudgetIncludesObservations() async throws {
        let btn = UIElementSnapshot(id: "btn_a", role: "AXButton", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        let harness = Harness(elements: [btn])
        _ = harness.session.start(goal: "Tool Budget", scope: harness.scope)

        harness.decisionProvider.enqueue(.action(
            FunctionCall(name: "ui_click", args: ["element_id": AnyCodable("btn_a")]),
            explanation: "Click A"
        ))
        harness.decisionProvider.enqueue(.action(
            FunctionCall(name: "ui_click", args: ["element_id": AnyCodable("btn_a")]),
            explanation: "Click A again"
        ))

        var dispatchedCount = 0
        // maxToolCalls: 3 -> 1 obs + 1 click + 1 obs = 3, then attempts next click but stops at limit
        let result = await harness.coordinator.runLoop(
            runID: UUID(),
            goal: "Tool Budget",
            scope: harness.scope,
            budget: TaskBudget(maxSteps: 10, maxToolCalls: 3),
            onStepCreated: { _ in },
            onStepUpdated: { _ in },
            onToolCallDispatched: { dispatchedCount += 1 },
            isTaskCancelled: { false }
        )

        guard case .paused(let pause) = result else {
            Issue.record("Expected budget pause for tool calls, got \(result)")
            return
        }
        #expect(pause == .budget("Dispatched tool call limit of 3 calls reached."))
        #expect(dispatchedCount == 3)
    }

    // MARK: - 5. Interactive SafetyGate Rejection Tests

    @Test("Declining confirmation card pauses control safely")
    @MainActor
    func safetyGateDeclinePausesControl() async throws {
        let btn = UIElementSnapshot(id: "btn_danger", role: "AXButton", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        // Harness with autoApproveConfirmation = false
        let harness = Harness(elements: [btn], autoApproveConfirmation: false)
        _ = harness.session.start(goal: "Risky Action", scope: harness.scope)

        harness.decisionProvider.enqueue(.action(
            FunctionCall(name: "ui_click", args: ["element_id": AnyCodable("btn_danger")]),
            explanation: "Click danger button"
        ))

        var updatedSteps: [TaskStep] = []
        let result = await harness.coordinator.runLoop(
            runID: UUID(),
            goal: "Risky Action",
            scope: harness.scope,
            budget: TaskBudget(maxSteps: 10, maxToolCalls: 20),
            onStepCreated: { _ in },
            onStepUpdated: { updatedSteps.append($0) },
            onToolCallDispatched: { },
            isTaskCancelled: { false }
        )

        guard case .paused(let pause) = result else {
            Issue.record("Expected pause after safety rejection, got \(result)")
            return
        }
        #expect(pause == .stepFailed(stepID: "1", reason: "You declined this step."))
        #expect(harness.session.state.isActive == false)
        #expect(updatedSteps.last?.status == .failed("Action declined by user."))
    }

    // MARK: - 6. TaskEngine Adaptive Mode Integration Tests

    @Test("TaskEngine starts and runs adaptive desktop mode end-to-end")
    @MainActor
    func taskEngineAdaptiveModeEndToEnd() async throws {
        let btn = UIElementSnapshot(id: "btn_save", role: "AXButton", title: "Save", frame: CGRect(x: 200, y: 50, width: 60, height: 30))
        let harness = Harness(elements: [btn])

        _ = harness.session.start(goal: "Save File", scope: harness.scope)

        await harness.engine.startAdaptiveDesktop(goal: "Save File", scope: harness.scope)
        #expect(harness.engine.run?.phase == .awaitingApproval)
        #expect(harness.engine.run?.plan.mode == .adaptiveDesktop)
        #expect(harness.engine.run?.plan.steps.count == 1) // initial checkpoint step, not fabricated pixels

        harness.decisionProvider.enqueue(.action(
            FunctionCall(name: "ui_click", args: ["element_id": AnyCodable("btn_save")]),
            explanation: "Click Save button"
        ))
        harness.decisionProvider.enqueue(.finish(summary: "File saved successfully"))

        harness.engine.approvePlan()

        // Wait for loop to finish
        var elapsed = 0
        while harness.engine.run?.phase != .finished(.succeeded) && elapsed < 50 {
            try await Task.sleep(nanoseconds: 50_000_000)
            elapsed += 1
        }

        #expect(harness.engine.run?.phase == .finished(.succeeded))
        #expect(harness.engine.run?.report == "File saved successfully")
        #expect((harness.engine.run?.plan.steps.count ?? 0) >= 2)
        #expect((harness.engine.run?.toolCalls ?? 0) >= 3)
    }

    // MARK: - 7. Cancellation and Stop Tests

    @Test("Coordinator cancellation stops session and marks steps cancelled")
    @MainActor
    func coordinatorCancellationStopsCleanly() async throws {
        let btn = UIElementSnapshot(id: "btn_c", role: "AXButton", frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        let harness = Harness(elements: [btn])
        _ = harness.session.start(goal: "Cancelling", scope: harness.scope)

        harness.coordinator.cancel()
        #expect(harness.coordinator.isCancelled == true)
        #expect(harness.session.state.isActive == false)

        let result = await harness.coordinator.runLoop(
            runID: UUID(),
            goal: "Cancelling",
            scope: harness.scope,
            budget: TaskBudget(),
            onStepCreated: { _ in },
            onStepUpdated: { _ in },
            onToolCallDispatched: { },
            isTaskCancelled: { false }
        )
        #expect(result == .cancelled)
    }

    // MARK: - 8. Backward-Compatible TaskPlan Decoding Tests

    @Test("Legacy TaskPlan JSON without mode decodes cleanly with sequential default")
    func legacyTaskPlanDecoding() throws {
        let legacyJSON = """
        {
            "id": "12345678-1234-1234-1234-123456789abc",
            "goal": "Legacy static task",
            "steps": [],
            "budget": {
                "maxSteps": 10,
                "maxToolCalls": 20,
                "maxDuration": 600,
                "maxReplans": 1
            }
        }
        """
        let data = Data(legacyJSON.utf8)
        let plan = try JSONDecoder().decode(TaskPlan.self, from: data)

        #expect(plan.goal == "Legacy static task")
        #expect(plan.mode == .sequential)
        #expect(plan.scope == nil)
        #expect(plan.budget.maxSteps == 10)
    }
}
