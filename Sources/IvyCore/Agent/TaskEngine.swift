import Foundation
import Combine

public enum TaskOutcome: String, Codable, Sendable {
    case succeeded, failed, cancelled
}

/// Why a running task stopped to ask the user.
public enum TaskPause: Codable, Equatable, Sendable {
    /// A step failed (or the user declined its card); the user picks skip / retry / stop.
    case stepFailed(stepID: String, reason: String)
    /// A budget ran out; the user picks continue (one more budget's worth) or stop.
    case budget(String)
}

public enum TaskPhase: Codable, Equatable, Sendable {
    case planning
    /// The plan is shown; nothing has run. Approving it approves the order, not the actions.
    case awaitingApproval
    case running(stepID: String)
    case paused(TaskPause)
    case finished(TaskOutcome)
}

/// One task from goal to report. Persisted (redacted) under Application Support/Ivy/Tasks.
public struct TaskRun: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var plan: TaskPlan
    public var phase: TaskPhase
    public let createdAt: Date
    public var finishedAt: Date?
    public var toolCalls = 0
    public var replans = 0
    /// How many times the user said "continue" after a budget ran out.
    public var budgetExtensions = 0
    /// Time spent running (not waiting for approval), for the duration budget.
    public var activeSeconds: TimeInterval = 0
    public var report: String?

    public var goal: String { plan.goal }

    public init(id: UUID = UUID(), plan: TaskPlan, phase: TaskPhase, createdAt: Date) {
        self.id = id
        self.plan = plan
        self.phase = phase
        self.createdAt = createdAt
    }

    public var isActive: Bool {
        if case .finished = phase { return false }
        return true
    }
}

public enum TaskPauseChoice: Sendable {
    /// Leave the failed step and carry on with the ones that don't depend on it.
    case skip
    case retry
    /// After a budget pause: allow one more budget's worth.
    case `continue`
    case stop
}

/// Result of attempting to start or plan a task.
public enum TaskStartResult: Equatable, Sendable {
    case started(UUID)
    case rejected(reason: String)

    public var isStarted: Bool {
        if case .started = self { return true }
        return false
    }

    public var rejectionReason: String? {
        if case .rejected(let reason) = self { return reason }
        return nil
    }
}

/// Plans, shows, and runs multi-step tasks. Every step is an ordinary tool call through the given dispatcher,
/// so SafetyGate is unchanged and authoritative: approving a plan approves the order; each risky step still
/// gets its own card with its exact arguments. Plan text, step titles and model output can never approve.
@MainActor
public final class TaskEngine: ObservableObject {
    public static let maxRetries = 1

    @Published public private(set) var run: TaskRun?
    @Published public private(set) var history: [TaskRun] = []

    /// Called once per finished task (report into the conversation, a notification).
    public var onFinished: ((TaskRun) -> Void)?

    private let planner: TaskPlanning
    private let dispatcher: ToolDispatcher
    private let denyPendingConfirmation: () -> Void
    private let store: TaskStore
    private let fileExists: (String) -> Bool
    private let now: () -> Date
    private var loop: Task<Void, Never>?
    private var activeSince: Date?
    private var coordinator: ComputerControlCoordinator?

    public init(
        planner: TaskPlanning,
        dispatcher: ToolDispatcher,
        denyPendingConfirmation: @escaping () -> Void,
        coordinator: ComputerControlCoordinator? = nil,
        store: TaskStore = InMemoryTaskStore(),
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        now: @escaping () -> Date = { Date() }
    ) {
        self.planner = planner
        self.dispatcher = dispatcher
        self.denyPendingConfirmation = denyPendingConfirmation
        self.coordinator = coordinator
        self.store = store
        self.fileExists = fileExists
        self.now = now
        history = store.recent()
    }

    public func setCoordinator(_ coordinator: ComputerControlCoordinator) {
        self.coordinator = coordinator
    }

    /// True if an adaptive desktop control session is currently running, awaiting approval, or paused.
    /// Exclusivity guarantee: only one desktop session may control the cursor and keyboard at any time.
    public var isDesktopControlActive: Bool {
        if run?.isActive == true && run?.plan.mode == .adaptiveDesktop {
            return true
        }
        return false
    }

    private var tools: [FunctionDeclaration] {
        dispatcher.registry.allTools.filter { !PlanValidator.forbiddenTools.contains($0.name) }.map(\.declaration)
    }

    // MARK: - Lifecycle

    /// Asks for a plan and shows it for approval. Nothing runs yet.
    @discardableResult
    public func start(goal rawGoal: String, budget: TaskBudget = TaskBudget()) async -> TaskStartResult {
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return .rejected(reason: "Goal cannot be empty.") }
        guard run?.isActive != true else {
            if isDesktopControlActive {
                return .rejected(reason: "A desktop control session is currently active. Stop or finish the desktop session before planning another task.")
            }
            return .rejected(reason: "A task is already running in Ivy. Stop or finish the current task before starting a new one.")
        }
        let id = UUID()
        run = TaskRun(id: id, plan: TaskPlan(goal: goal, steps: [], budget: budget), phase: .planning, createdAt: now())

        var context = ""
        for attempt in 0..<2 {
            do {
                let raw = try await planner.plan(goal: goal, context: context, tools: tools)
                guard run?.id == id, run?.phase == .planning else { return .rejected(reason: "Task planning was superseded or cancelled.") }
                let steps = try PlannerOutput.parse(raw).steps()
                let valid = try PlanValidator.validate(steps, registry: dispatcher.registry, budget: budget)
                run?.plan.steps = valid
                run?.phase = .awaitingApproval
                return .started(id)
            } catch PlanValidationError.empty {
                finish(.failed, report: "I can't do that with the tools I have. Try asking in chat instead.")
                return .rejected(reason: "I can't do that with the tools I have. Try asking in chat instead.")
            } catch let error as PlanValidationError where attempt == 0 {
                context = "The previous plan was rejected: \(error.localizedDescription) Produce a corrected plan."
            } catch {
                guard run?.id == id else { return .rejected(reason: "Task planning was cancelled.") }
                finish(.failed, report: "I couldn't make a usable plan: \(error.localizedDescription)")
                return .rejected(reason: "I couldn't make a usable plan: \(error.localizedDescription)")
            }
        }
        return .rejected(reason: "Task planning failed after retry.")
    }

    /// Starts an adaptive desktop control task.
    /// Initial review shows the goal, target application scope, and checkpoints — not fabricated future pixel coordinates.
    @discardableResult
    public func startAdaptiveDesktop(
        goal rawGoal: String,
        scope: ComputerControlScope,
        coordinator: ComputerControlCoordinator? = nil,
        budget: TaskBudget = TaskBudget(maxSteps: 20, maxToolCalls: 40)
    ) async -> TaskStartResult {
        let goal = rawGoal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            return .rejected(reason: "Goal cannot be empty.")
        }
        guard !isDesktopControlActive else {
            return .rejected(reason: "A desktop control session is already active. Only one desktop session can control the cursor and keyboard at a time.")
        }
        guard run?.isActive != true else {
            return .rejected(reason: "A task is already running in Ivy. Stop or finish the current task before starting a new one.")
        }
        guard scope.isPermittedApp else {
            return .rejected(reason: "Control of '\(scope.bundleIdentifier)' is prohibited for security.")
        }
        if let coordinator {
            self.coordinator = coordinator
        }
        let id = UUID()
        let initialStep = TaskStep(
            id: "1",
            title: "Target \(scope.bundleIdentifier) and observe application window",
            tool: "ui_observe",
            arguments: ["bundle_id": AnyCodable(scope.bundleIdentifier)]
        )
        let plan = TaskPlan(
            id: id,
            goal: goal,
            steps: [initialStep],
            budget: budget,
            mode: .adaptiveDesktop,
            scope: scope
        )
        run = TaskRun(id: id, plan: plan, phase: .awaitingApproval, createdAt: now())
        return .started(id)
    }

    public func approvePlan() {
        guard run?.phase == .awaitingApproval else { return }
        if run?.plan.mode == .adaptiveDesktop {
            startAdaptiveLoop()
        } else {
            startLoop()
        }
    }

    /// Stops everything: the running tool is cancelled (a shell command and its children are killed), a card
    /// waiting for approval is denied, and the remaining steps are marked cancelled. Completed steps aren't undone.
    public func cancel() {
        guard run?.isActive == true else { return }
        loop?.cancel()
        loop = nil
        coordinator?.cancel()
        denyPendingConfirmation()
        if let steps = run?.plan.steps {
            for index in steps.indices where !steps[index].status.isFinished {
                run?.plan.steps[index].status = .cancelled
            }
        }
        finish(.cancelled, report: nil)
    }

    public func resolvePause(_ choice: TaskPauseChoice) {
        guard case .paused(let pause)? = run?.phase else { return }
        switch (pause, choice) {
        case (_, .stop):
            cancel()
        case (.stepFailed(let id, let reason), .skip):
            setStatus(id, .skipped(reason))
            resumeLoop()
        case (.stepFailed(let id, _), .retry):
            setStatus(id, .pending)
            resumeLoop()
        case (.budget, .continue):
            run?.budgetExtensions += 1
            resumeLoop()
        default:
            break // a choice that doesn't fit this pause: ignore it
        }
    }

    private func resumeLoop() {
        if run?.plan.mode == .adaptiveDesktop {
            startAdaptiveLoop()
        } else {
            startLoop()
        }
    }

    /// Hides a finished task.
    public func dismiss() {
        guard run?.isActive == false else { return }
        run = nil
    }

    /// Starts the same goal again: a new plan, approved again. Nothing from the earlier run is reused.
    public func rerun(_ previous: TaskRun) async {
        if previous.plan.mode == .adaptiveDesktop, let scope = previous.plan.scope {
            await startAdaptiveDesktop(goal: previous.goal, scope: scope, budget: previous.plan.budget)
        } else {
            await start(goal: previous.goal, budget: previous.plan.budget)
        }
    }

    // MARK: - Running

    private func startLoop() {
        loop?.cancel()
        activeSince = now()
        let id = run?.id
        loop = Task { [weak self] in
            await self?.runSteps(id: id)
        }
    }

    private func startAdaptiveLoop() {
        loop?.cancel()
        activeSince = now()
        let id = run?.id
        loop = Task { [weak self] in
            await self?.runAdaptiveSteps(id: id)
        }
    }

    private func runAdaptiveSteps(id: UUID?) async {
        guard let current = run, current.id == id, let scope = current.plan.scope, let coordinator = coordinator else {
            finish(.failed, report: "Adaptive desktop coordinator or scope not configured.")
            return
        }

        run?.phase = .running(stepID: current.plan.steps.last?.id ?? "1")

        let result = await coordinator.runLoop(
            runID: current.id,
            goal: current.goal,
            scope: scope,
            budget: current.plan.budget,
            startTime: activeSince ?? now(),
            existingStepCount: current.plan.steps.filter { $0.id != "1" && $0.tool != "ui_observe" }.count,
            existingToolCalls: current.toolCalls,
            onStepCreated: { [weak self] step in
                guard let self, self.run?.id == id else { return }
                self.run?.plan.steps.append(step)
                self.run?.phase = .running(stepID: step.id)
                self.persist()
            },
            onStepUpdated: { [weak self] step in
                guard let self, self.run?.id == id else { return }
                if let idx = self.run?.plan.steps.firstIndex(where: { $0.id == step.id }) {
                    self.run?.plan.steps[idx] = step
                }
                self.persist()
            },
            onToolCallDispatched: { [weak self] in
                guard let self, self.run?.id == id else { return }
                self.run?.toolCalls += 1
            },
            isTaskCancelled: { [weak self] in
                Task.isCancelled || self?.run?.id != id
            }
        )

        guard run?.id == id, !Task.isCancelled else { return }

        switch result {
        case .succeeded(let summary):
            finish(.succeeded, report: summary)
        case .paused(let pause):
            pauseRun(pause)
        case .failed(let reason):
            finish(.failed, report: Self.report(current, outcome: .failed, stoppingReason: reason))
        case .cancelled:
            finish(.cancelled, report: nil)
        }
    }

    private func runSteps(id: UUID?) async {
        while let current = run, current.id == id, !Task.isCancelled {
            if let pause = budgetExceeded() {
                pauseRun(.budget(pause))
                return
            }
            guard let index = nextRunnable() else {
                let failed = current.plan.steps.contains { if case .failed = $0.status { return true } else { return false } }
                finish(failed ? .failed : .succeeded, report: nil)
                return
            }
            let keepGoing = await execute(index, runID: current.id)
            if !keepGoing { return }
        }
    }

    /// The first pending step whose dependencies all succeeded; steps behind a failure are skipped.
    private func nextRunnable() -> Int? {
        guard let steps = run?.plan.steps else { return nil }
        for (index, step) in steps.enumerated() where step.status == .pending {
            let deps = step.dependsOn.compactMap { dep in steps.first { $0.id == dep } }
            if deps.contains(where: { $0.status != .succeeded && $0.status.isFinished }) {
                run?.plan.steps[index].status = .skipped("A step it depends on didn't complete.")
                continue
            }
            if deps.allSatisfy({ $0.status == .succeeded }) { return index }
        }
        return nil
    }

    /// Runs one step. Returns false when the loop must stop (pause, re-plan, finish, cancellation).
    private func execute(_ index: Int, runID: UUID) async -> Bool {
        guard var step = run?.plan.steps[index] else { return false }
        step.attempts += 1
        step.status = .running
        run?.plan.steps[index] = step
        run?.toolCalls += 1
        run?.phase = .running(stepID: step.id)

        let call = FunctionCall(name: step.tool, args: step.arguments, id: "task-\(runID.uuidString.prefix(8))-\(step.id)-\(step.attempts)")
        let response = await dispatcher.dispatch(call)
        guard run?.id == runID, !Task.isCancelled else { return false }

        let output = response.resultMessage ?? response.errorMessage ?? ""
        run?.plan.steps[index].output = TaskStep.clip(output)

        if response.isCancelled || response.isSafetyRejection {
            // The user said no to this step's card. Never retried on its own.
            run?.plan.steps[index].status = .failed("You declined this step.")
            pauseRun(.stepFailed(stepID: step.id, reason: "You declined this step."))
            return false
        }
        if response.isSuccess, let problem = verificationProblem(step.verification, output: output) {
            return await handleFailure(index, reason: problem)
        }
        if response.isSuccess {
            run?.plan.steps[index].status = .succeeded
            persist()
            return true
        }
        return await handleFailure(index, reason: TaskStep.clip(response.errorMessage ?? "The tool reported a failure."))
    }

    private func verificationProblem(_ verification: StepVerification, output: String) -> String? {
        switch verification {
        case .succeeded:
            return nil
        case .fileExists(let raw):
            guard let path = try? ToolValidation.validateFilePath(raw), fileExists(path) else {
                return "Check failed: \(raw) doesn't exist afterwards."
            }
            return nil
        case .outputContains(let text):
            return output.localizedCaseInsensitiveContains(text) ? nil : "Check failed: the output doesn't mention \"\(text)\"."
        }
    }

    private func handleFailure(_ index: Int, reason: String) async -> Bool {
        guard let step = run?.plan.steps[index] else { return false }
        run?.plan.steps[index].status = .failed(reason)
        switch step.onFailure {
        case .retry where step.attempts <= Self.maxRetries:
            run?.plan.steps[index].status = .pending
            return true
        case .replan where (run?.replans ?? 0) < (run?.plan.budget.maxReplans ?? 0):
            await replan(after: index, reason: reason)
            return false
        case .abort:
            finish(.failed, report: nil)
            return false
        default:
            pauseRun(.stepFailed(stepID: step.id, reason: reason))
            return false
        }
    }

    /// A new remainder from the planner, shown for approval again. Finished steps stay as they are.
    private func replan(after index: Int, reason: String) async {
        guard let current = run else { return }
        let id = current.id
        run?.replans += 1
        run?.phase = .planning
        let done = current.plan.steps.filter(\.status.isFinished).map { step -> String in
            let output = step.output.map { text in " — " + String(text.prefix(300)) } ?? ""
            return "- \(step.title) [\(step.tool)]: \(Self.describe(step.status))\(output)"
        }
        let failedID = current.plan.steps[index].id
        let context = done.joined(separator: "\n") + "\nFailed: \(current.plan.steps[index].title): \(reason)"
        do {
            let raw = try await planner.plan(goal: current.goal, context: context, tools: tools)
            guard run?.id == id else { return }
            let prefix = "r\(current.replans + 1)-"
            let fresh = try PlanValidator.validate(PlannerOutput.parse(raw).steps(idPrefix: prefix), registry: dispatcher.registry,
                                                   budget: TaskBudget(maxSteps: max(1, current.plan.budget.maxSteps - done.count)))
            // The failed step is superseded by the new remainder, so it no longer fails the task.
            setStatus(failedID, .skipped("Replaced by a new plan after: \(reason)"))
            let kept = (run?.plan.steps ?? []).filter(\.status.isFinished)
            run?.plan.steps = kept + fresh
            run?.phase = .awaitingApproval
        } catch {
            guard run?.id == id else { return }
            pauseRun(.stepFailed(stepID: current.plan.steps[index].id, reason: "\(reason) (A new plan couldn't be made: \(error.localizedDescription))"))
        }
    }

    private func budgetExceeded() -> String? {
        guard let run else { return nil }
        let allowance = Double(run.budgetExtensions + 1)
        let active = run.activeSeconds + (activeSince.map { now().timeIntervalSince($0) } ?? 0)
        if run.toolCalls >= Int(Double(run.plan.budget.maxToolCalls) * allowance) {
            return "\(run.toolCalls) tool calls so far."
        }
        if active >= run.plan.budget.maxDuration * allowance {
            return "\(Int(active / 60)) minutes so far."
        }
        return nil
    }

    // MARK: - Bookkeeping

    private func setStatus(_ id: String, _ status: StepStatus) {
        guard let index = run?.plan.steps.firstIndex(where: { $0.id == id }) else { return }
        run?.plan.steps[index].status = status
    }

    private func stopClock() {
        if let since = activeSince {
            run?.activeSeconds += now().timeIntervalSince(since)
            activeSince = nil
        }
    }

    private func pauseRun(_ pause: TaskPause) {
        stopClock()
        run?.phase = .paused(pause)
        persist()
    }

    private func finish(_ outcome: TaskOutcome, report: String?) {
        stopClock()
        guard var finished = run else { return }
        finished.phase = .finished(outcome)
        finished.finishedAt = now()
        finished.report = report ?? Self.report(finished, outcome: outcome)
        run = finished
        loop = nil
        persist()
        history = store.recent()
        onFinished?(finished)
    }

    private func persist() {
        guard let run else { return }
        do {
            try store.save(run)
        } catch {
            print("[TASKS] task history couldn't be saved: \(error.localizedDescription)")
        }
    }

    static func describe(_ status: StepStatus) -> String {
        switch status {
        case .pending: return "not run"
        case .running: return "running"
        case .succeeded: return "done"
        case .failed(let why): return "failed (\(why))"
        case .skipped(let why): return "skipped (\(why))"
        case .cancelled: return "cancelled"
        }
    }

    /// Structured partial-result report describing completed steps, stopping point, and outcome.
    public static func partialReport(for run: TaskRun) -> String {
        let steps = run.plan.steps
        let done = steps.filter { $0.status == .succeeded }.count
        let statusDescription: String
        switch run.phase {
        case .paused(let pause):
            switch pause {
            case .stepFailed(let stepID, let reason):
                let title = steps.first(where: { $0.id == stepID })?.title ?? "Step \(stepID)"
                statusDescription = "Paused at \(title): \(reason)"
            case .budget(let budgetReason):
                statusDescription = "Paused on budget: \(budgetReason)"
            }
        case .running(let stepID):
            let title = steps.first(where: { $0.id == stepID })?.title ?? "Step \(stepID)"
            statusDescription = "Running: currently on \(title)"
        case .awaitingApproval:
            statusDescription = "Awaiting your approval to start"
        case .planning:
            statusDescription = "Planning task"
        case .finished(let outcome):
            return report(run, outcome: outcome)
        }

        let lines = steps.map { step -> String in
            let mark = step.status == .succeeded ? "✓" : (step.status == .pending || step.status == .cancelled ? "–" : "✗")
            return "\(mark) \(step.title) — \(describe(step.status))"
        }
        var text = "Task in progress: \(run.goal)\nStatus: \(statusDescription)\n\(done) of \(steps.count) steps completed."
        if !lines.isEmpty {
            text += "\n" + lines.joined(separator: "\n")
        }
        if done > 0 {
            text += "\nCompleted steps were not undone."
        }
        return text
    }

    /// Current task's partial-result report, or 'No active task.' if none exists.
    public var partialReport: String {
        guard let run else { return "No active task." }
        return Self.partialReport(for: run)
    }

    /// Plain, factual summary: what ran, what didn't. Nothing is claimed that a step didn't report.
    public static func report(_ run: TaskRun, outcome: TaskOutcome, stoppingReason: String? = nil) -> String {
        let steps = run.plan.steps
        let done = steps.filter { $0.status == .succeeded }.count
        let head: String
        switch outcome {
        case .succeeded: head = "Task done: \(run.goal)"
        case .failed:
            if let reason = stoppingReason {
                head = "Task stopped with problems: \(run.goal) — \(reason)"
            } else {
                head = "Task stopped with problems: \(run.goal)"
            }
        case .cancelled: head = "Task stopped by you: \(run.goal)"
        }
        let lines = steps.map { step -> String in
            let mark = step.status == .succeeded ? "✓" : (step.status == .pending || step.status == .cancelled ? "–" : "✗")
            return "\(mark) \(step.title) — \(describe(step.status))"
        }
        var text = head + "\n\(done) of \(steps.count) steps completed."
        if !lines.isEmpty {
            text += "\n" + lines.joined(separator: "\n")
        }
        if outcome != .succeeded, done > 0 { text += "\nCompleted steps were not undone." }
        return text
    }
}
