import Foundation
import Testing
import CoreGraphics
@testable import IvyCore

@Suite("Phase 19.9 - Chat, Command Bar and Voice Integration Tests")
struct ComputerControlEntryPointsTests {

    // MARK: - Test Helpers

    @MainActor
    private final class MockPlanner: TaskPlanning {
        var plannedSteps: [TaskStep] = []
        func plan(goal: String, context: String, tools: [FunctionDeclaration]) async throws -> String {
            let stepsJSON = plannedSteps.map { s in
                """
                {"id": "\(s.id)", "title": "\(s.title)", "tool": "\(s.tool)"}
                """
            }.joined(separator: ", ")
            return """
            {"goal": "\(goal)", "steps": [\(stepsJSON)]}
            """
        }
    }

    @MainActor
    private struct EntryPointsHarness {
        let session: ComputerControlSession
        let driver: MockComputerInputDriver
        let observationProvider: MockDesktopObservationProvider
        let decisionProvider: MockComputerDecisionProvider
        let safetyGate: InteractiveSafetyGate
        let dispatcher: ToolDispatcher
        let coordinator: ComputerControlCoordinator
        let engine: TaskEngine
        let planner: MockPlanner
        let scope: ComputerControlScope

        init(elements: [UIElementSnapshot] = []) {
            let scope = ComputerControlScope(
                bundleIdentifier: "com.apple.TextEdit",
                processIdentifier: 1234,
                windowTitle: "Untitled",
                windowID: 101,
                displayID: 1,
                isAuthorized: true
            )
            self.scope = scope
            let session = ComputerControlSession()
            let driver = MockComputerInputDriver(isAuthorized: true)
            let obs = MockDesktopObservationProvider(defaultElements: elements)
            let dec = MockComputerDecisionProvider()
            let gate = InteractiveSafetyGate(confirmationProvider: ClosureConfirmationProvider { _ in true })
            let reg = ToolRegistry(tools: ComputerControlTools.all(session: session, driver: driver, observationProvider: obs))
            let disp = ToolDispatcher(registry: reg, safetyGate: gate)
            let coord = ComputerControlCoordinator(
                session: session,
                decisionProvider: dec,
                dispatcher: disp,
                observationProvider: obs,
                driver: driver
            )
            let planner = MockPlanner()
            let engine = TaskEngine(
                planner: planner,
                dispatcher: disp,
                denyPendingConfirmation: {},
                coordinator: coord,
                store: InMemoryTaskStore()
            )

            self.session = session
            self.driver = driver
            self.observationProvider = obs
            self.decisionProvider = dec
            self.safetyGate = gate
            self.dispatcher = disp
            self.coordinator = coord
            self.engine = engine
            self.planner = planner
        }
    }

    // MARK: - 1. Shared Entry Points and Routing

    @Test("CommandBar parseDesktopCommand splits bundle ID and goal correctly")
    @MainActor
    func commandBarParseDesktopCommand() {
        let (bundle1, goal1) = CommandBarSession.parseDesktopCommand("com.apple.TextEdit Create a new document")
        #expect(bundle1 == "com.apple.TextEdit")
        #expect(goal1 == "Create a new document")

        let (bundle2, goal2) = CommandBarSession.parseDesktopCommand("Organize my notes")
        #expect(bundle2 == nil)
        #expect(goal2 == "Organize my notes")

        let (bundle3, goal3) = CommandBarSession.parseDesktopCommand("com.google.Chrome https://apple.com")
        #expect(bundle3 == "com.google.Chrome")
        #expect(goal3 == "https://apple.com")
    }

    private final class StartTracker: @unchecked Sendable {
        var goal: String?
        var scope: ComputerControlScope?
        var isActive: Bool = false
    }

    @Test("ControlAppTool validates permissions, prohibited apps, and plans adaptive desktop task")
    @MainActor
    func controlAppToolLifecycle() async throws {
        let tracker = StartTracker()

        let tool = ControlAppTool(
            onStartTask: { goal, scope in
                tracker.goal = goal
                tracker.scope = scope
                return .started(UUID())
            },
            isDesktopActive: { false }
        )

        // Prohibited app is rejected in validation
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "bundle_id": AnyCodable("com.apple.keychainaccess"),
                "goal": AnyCodable("Steal credentials")
            ])
        }

        // Permitted app passes validation and returns confirmation sheet details
        try tool.validate(arguments: [
            "bundle_id": AnyCodable("com.apple.TextEdit"),
            "goal": AnyCodable("Draft letter")
        ])
        let confirmation = tool.confirmation(for: [
            "bundle_id": AnyCodable("com.apple.TextEdit"),
            "goal": AnyCodable("Draft letter")
        ])
        #expect(confirmation?.title == "Control Application")
        #expect(confirmation?.prompt.contains("com.apple.TextEdit") == true)

        // Execution starts the task and informs user review is required
        let result = try await tool.execute(arguments: [
            "bundle_id": AnyCodable("com.apple.TextEdit"),
            "goal": AnyCodable("Draft letter")
        ])
        #expect(!result.isError)
        #expect(result.output.contains("review and approve"))
        #expect(tracker.goal == "Draft letter")
        #expect(tracker.scope?.bundleIdentifier == "com.apple.TextEdit")
    }

    // MARK: - 2. Concurrency Exclusivity (Single Desktop-Input Lane)

    @Test("Concurrent desktop control attempt is rejected with explicit user-facing conflict reason")
    @MainActor
    func concurrentDesktopControlAttemptRejected() async throws {
        let harness = EntryPointsHarness()

        let first = await harness.engine.startAdaptiveDesktop(goal: "Write report", scope: harness.scope)
        #expect(first.isStarted)
        #expect(harness.engine.isDesktopControlActive)

        // Second desktop attempt while first is awaiting approval
        let second = await harness.engine.startAdaptiveDesktop(goal: "Draw diagram", scope: harness.scope)
        #expect(!second.isStarted)
        #expect(second.rejectionReason?.contains("Only one desktop session can control") == true)

        // Attempting a sequential task while desktop is active is also rejected cleanly
        let third = await harness.engine.start(goal: "Sequential task")
        #expect(!third.isStarted)
        #expect(third.rejectionReason?.contains("desktop control session is currently active") == true)
    }

    @Test("ControlAppTool rejects execution when another desktop session is active")
    @MainActor
    func controlAppToolRejectsWhenActive() async throws {
        let tracker = StartTracker()
        tracker.isActive = true
        let tool = ControlAppTool(
            onStartTask: { _, _ in .started(UUID()) },
            isDesktopActive: { tracker.isActive }
        )

        let result = try await tool.execute(arguments: [
            "bundle_id": AnyCodable("com.apple.Safari"),
            "goal": AnyCodable("Open docs")
        ])
        #expect(result.isError)
        #expect(result.output.contains("Only one desktop session can control the cursor and keyboard") == true)

        // When not active, succeeds
        tracker.isActive = false
        let successResult = try await tool.execute(arguments: [
            "bundle_id": AnyCodable("com.apple.Safari"),
            "goal": AnyCodable("Open docs")
        ])
        #expect(!successResult.isError)
    }

    @Test("Prohibited applications are rejected from startAdaptiveDesktop")
    @MainActor
    func prohibitedAppRejectedFromStartAdaptiveDesktop() async throws {
        let harness = EntryPointsHarness()
        let prohibitedScope = ComputerControlScope(bundleIdentifier: "com.apple.loginwindow", isAuthorized: true)

        let result = await harness.engine.startAdaptiveDesktop(goal: "Login test", scope: prohibitedScope)
        #expect(!result.isStarted)
        #expect(result.rejectionReason?.contains("prohibited for security") == true)
        #expect(harness.engine.run == nil)
    }

    // MARK: - 3. Voice Integration & Push-To-Talk

    @Test("Voice stop request cancels running desktop task and releases driver inputs")
    @MainActor
    func voiceStopRequestCancelsDesktopTask() async throws {
        let harness = EntryPointsHarness()
        _ = harness.session.start(goal: "Long task", scope: harness.scope)
        await harness.engine.startAdaptiveDesktop(goal: "Long task", scope: harness.scope)

        // Queue a slow action
        harness.decisionProvider.enqueue(.action(
            FunctionCall(name: "ui_click", args: ["x": AnyCodable(100), "y": AnyCodable(100)]),
            explanation: "Click somewhere"
        ))

        harness.engine.approvePlan()
        #expect(harness.engine.run?.isActive == true)

        // Simulate voice coordinator triggering stop command
        harness.engine.cancel()

        #expect(harness.engine.run?.isActive == false)
        if case .finished(let outcome) = harness.engine.run?.phase {
            #expect(outcome == .cancelled)
        } else {
            Issue.record("Expected task to be finished with cancellation")
        }
        // Yield briefly for driver release task
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(harness.driver.recordedEvents.contains(.releaseAll))
        #expect(harness.coordinator.isCancelled)
    }

    // MARK: - 4. Redacted Tool Cards and Persistence Representation

    @Test("ToolActivity redacts ui_type text and large observation payloads")
    @MainActor
    func toolActivityRedactsUITypeAndObservation() {
        let activity = ToolActivity()

        // 1. ui_type text argument is masked
        let typeCall = FunctionCall(
            name: "ui_type",
            args: ["text": AnyCodable("SecretSuperPassword!"), "replace": AnyCodable(true)],
            id: "call-1"
        )
        let typeID = activity.begin(typeCall)
        activity.complete(typeID, response: FunctionResponse(
            name: "ui_type",
            response: ["success": AnyCodable(true), "message": AnyCodable("Typed 20 characters")]
        ))

        let typeRecord = activity.records.first { $0.id == typeID }
        #expect(typeRecord != nil)
        #expect(typeRecord?.arguments.contains("SecretSuperPassword!") == false)
        #expect(typeRecord?.arguments.contains("[redacted") == true)

        // 2. Observation payload with elements and base64 imageData is masked
        let observeCall = FunctionCall(
            name: "ui_observe",
            args: ["bundle_id": AnyCodable("com.apple.Safari")],
            id: "call-2"
        )
        let observeID = activity.begin(observeCall)
        activity.complete(observeID, response: FunctionResponse(
            name: "ui_observe",
            response: [
                "success": AnyCodable(true),
                "imageData": AnyCodable("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="),
                "elements": AnyCodable(["btn_1", "btn_2", "btn_3"])
            ]
        ))

        let observeRecord = activity.records.first { $0.id == observeID }
        #expect(observeRecord != nil)
        #expect(observeRecord?.output?.contains("iVBORw0KGgo") == false)
        #expect(observeRecord?.output?.contains("[redacted observation payload]") == true)
    }

    @Test("TaskStep encodes redacted arguments for persistence and decodes cleanly")
    func taskStepPersistenceRedaction() throws {
        let originalStep = TaskStep(
            id: "s1",
            title: "Type sensitive info",
            tool: "ui_type",
            arguments: [
                "text": AnyCodable("MySensitiveRecoveryKey456"),
                "element_id": AnyCodable("field_password"),
                "token": AnyCodable("secret_token_123")
            ]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(originalStep)
        let jsonString = String(decoding: data, as: UTF8.self)

        // Raw typed text and token must not be written to JSON
        #expect(!jsonString.contains("MySensitiveRecoveryKey456"))
        #expect(!jsonString.contains("secret_token_123"))
        #expect(jsonString.contains("[redacted"))

        // Decodes cleanly back into TaskStep
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TaskStep.self, from: data)
        #expect(decoded.id == "s1")
        #expect(decoded.tool == "ui_type")
        #expect(decoded.arguments["text"]?.stringValue?.contains("[redacted") == true)
    }

    @Test("FileTaskStore saves and loads TaskRun without leaking unredacted secrets")
    func fileTaskStorePersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = FileTaskStore(directory: tempDir)
        let step = TaskStep(
            id: "1",
            title: "Type master key",
            tool: "ui_type",
            arguments: ["text": AnyCodable("PrivateMasterKey999")]
        )
        let plan = TaskPlan(
            goal: "Configure credentials",
            steps: [step],
            mode: .adaptiveDesktop,
            scope: ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)
        )
        let run = TaskRun(plan: plan, phase: .finished(.succeeded), createdAt: Date())

        try store.save(run)

        let loaded = store.recent(limit: 5)
        #expect(loaded.count == 1)
        #expect(loaded.first?.goal == "Configure credentials")
        #expect(loaded.first?.plan.mode == .adaptiveDesktop)

        // Verify on-disk file permissions and content
        let fileURL = tempDir.appendingPathComponent("\(run.id.uuidString).json")
        let contents = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!contents.contains("PrivateMasterKey999"))
        #expect(contents.contains("[redacted"))
    }

    // MARK: - 5. Structured Partial-Result Reports

    @Test("Partial report on paused task reflects stopping point and non-undone steps")
    @MainActor
    func partialReportOnPausedTask() {
        var step1 = TaskStep(id: "1", title: "Open notes", tool: "ui_observe")
        step1.status = .succeeded
        var step2 = TaskStep(id: "2", title: "Click new note", tool: "ui_click")
        step2.status = .failed("Button was not found on screen")

        let plan = TaskPlan(goal: "Create note", steps: [step1, step2], mode: .adaptiveDesktop)
        var run = TaskRun(plan: plan, phase: .paused(.stepFailed(stepID: "2", reason: "Button was not found on screen")), createdAt: Date())
        run.toolCalls = 3

        let report = TaskEngine.partialReport(for: run)
        #expect(report.contains("Task in progress: Create note"))
        #expect(report.contains("Paused at Click new note: Button was not found on screen"))
        #expect(report.contains("1 of 2 steps completed."))
        #expect(report.contains("✓ Open notes — done"))
        #expect(report.contains("✗ Click new note — failed (Button was not found on screen)"))
        #expect(report.contains("Completed steps were not undone."))
    }

    @Test("Partial report on cancelled task reflects concrete outcome and preserved steps")
    @MainActor
    func partialReportOnCancelledTask() {
        var step1 = TaskStep(id: "1", title: "Navigate to page", tool: "ui_click")
        step1.status = .succeeded
        var step2 = TaskStep(id: "2", title: "Type form input", tool: "ui_type")
        step2.status = .cancelled

        let plan = TaskPlan(goal: "Fill web form", steps: [step1, step2], mode: .adaptiveDesktop)
        var run = TaskRun(plan: plan, phase: .finished(.cancelled), createdAt: Date())
        run.finishedAt = Date()
        let report = TaskEngine.report(run, outcome: .cancelled)

        #expect(report.contains("Task stopped by you: Fill web form"))
        #expect(report.contains("1 of 2 steps completed."))
        #expect(report.contains("✓ Navigate to page — done"))
        #expect(report.contains("– Type form input — cancelled"))
        #expect(report.contains("Completed steps were not undone."))
    }

    @Test("Partial report on failed task reflects stopping reason and step progress")
    @MainActor
    func partialReportOnFailedTask() {
        var step1 = TaskStep(id: "1", title: "Inspect window", tool: "ui_observe")
        step1.status = .succeeded
        var step2 = TaskStep(id: "2", title: "Click toolbar item", tool: "ui_click")
        step2.status = .failed("Target window was closed")

        let plan = TaskPlan(goal: "Format document", steps: [step1, step2], mode: .adaptiveDesktop)
        let run = TaskRun(plan: plan, phase: .finished(.failed), createdAt: Date())
        let report = TaskEngine.report(run, outcome: .failed, stoppingReason: "Target window was closed")

        #expect(report.contains("Task stopped with problems: Format document — Target window was closed"))
        #expect(report.contains("1 of 2 steps completed."))
        #expect(report.contains("✓ Inspect window — done"))
        #expect(report.contains("Completed steps were not undone."))
    }
}
