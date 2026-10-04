import Foundation

/// Limits a task can't exceed without the user saying "continue".
public struct TaskBudget: Codable, Equatable, Sendable {
    public var maxSteps: Int
    public var maxToolCalls: Int
    public var maxDuration: TimeInterval
    public var maxReplans: Int

    public init(maxSteps: Int = 20, maxToolCalls: Int = 40, maxDuration: TimeInterval = 15 * 60, maxReplans: Int = 2) {
        self.maxSteps = maxSteps
        self.maxToolCalls = maxToolCalls
        self.maxDuration = maxDuration
        self.maxReplans = maxReplans
    }
}

/// How a step is checked after its tool reports success.
public enum StepVerification: Codable, Equatable, Sendable {
    /// The tool said it succeeded (the default).
    case succeeded
    /// A path exists afterwards (validated like `file_op` paths).
    case fileExists(String)
    /// The tool's output contains this text (case-insensitive).
    case outputContains(String)
}

public enum StepFailurePolicy: String, Codable, CaseIterable, Sendable {
    /// Run it once more, then ask.
    case retry
    /// Ask the planner for a new remainder (bounded by `maxReplans`), which the user approves again.
    case replan
    /// Pause and ask the user (skip / retry / stop).
    case ask
    /// Stop the task.
    case abort
}

public enum StepStatus: Codable, Equatable, Sendable {
    case pending
    case running
    case succeeded
    case failed(String)
    case skipped(String)
    case cancelled

    public var isFinished: Bool {
        switch self {
        case .pending, .running: return false
        case .succeeded, .failed, .skipped, .cancelled: return true
        }
    }
}

public struct TaskStep: Codable, Identifiable, Equatable, Sendable {
    public static let maxOutputBytes = 4 * 1024

    public let id: String
    public var title: String
    public var tool: String
    public var arguments: [String: AnyCodable]
    public var dependsOn: [String]
    public var verification: StepVerification
    public var onFailure: StepFailurePolicy
    public var status: StepStatus = .pending
    /// Redacted, at most `maxOutputBytes`.
    public var output: String?
    public var attempts = 0

    public init(id: String, title: String, tool: String, arguments: [String: AnyCodable] = [:], dependsOn: [String] = [],
                verification: StepVerification = .succeeded, onFailure: StepFailurePolicy = .ask) {
        self.id = id
        self.title = title
        self.tool = tool
        self.arguments = arguments
        self.dependsOn = dependsOn
        self.verification = verification
        self.onFailure = onFailure
    }

    /// Keeps step output small and free of secrets before it is shown, stored or sent to the planner.
    static func clip(_ text: String) -> String {
        let redacted = SecretRedactor.redact(text)
        guard redacted.utf8.count > maxOutputBytes else { return redacted }
        var cut = String(redacted.prefix(maxOutputBytes))
        while cut.utf8.count > maxOutputBytes { cut.removeLast() }
        return cut + "\n… [truncated]"
    }
}

/// Mode in which the task is executed.
public enum TaskExecutionMode: String, Codable, Sendable {
    case sequential
    case adaptiveDesktop
}

public struct TaskPlan: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var goal: String
    public var steps: [TaskStep]
    public var budget: TaskBudget
    public var mode: TaskExecutionMode
    public var scope: ComputerControlScope?

    public init(
        id: UUID = UUID(),
        goal: String,
        steps: [TaskStep],
        budget: TaskBudget = TaskBudget(),
        mode: TaskExecutionMode = .sequential,
        scope: ComputerControlScope? = nil
    ) {
        self.id = id
        self.goal = goal
        self.steps = steps
        self.budget = budget
        self.mode = mode
        self.scope = scope
    }

    enum CodingKeys: String, CodingKey {
        case id, goal, steps, budget, mode, scope
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.goal = try container.decode(String.self, forKey: .goal)
        self.steps = try container.decode([TaskStep].self, forKey: .steps)
        self.budget = try container.decode(TaskBudget.self, forKey: .budget)
        self.mode = try container.decodeIfPresent(TaskExecutionMode.self, forKey: .mode) ?? .sequential
        self.scope = try container.decodeIfPresent(ComputerControlScope.self, forKey: .scope)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(goal, forKey: .goal)
        try container.encode(steps, forKey: .steps)
        try container.encode(budget, forKey: .budget)
        try container.encode(mode, forKey: .mode)
        try container.encodeIfPresent(scope, forKey: .scope)
    }
}

// MARK: - Planner output

/// The JSON the planner is asked for. Parsed leniently (code fences, prose around it), validated strictly.
struct PlannerOutput: Decodable {
    struct Step: Decodable {
        let id: String?
        let title: String
        let tool: String
        let arguments: [String: AnyCodable]?
        let dependsOn: [String]?
        let verify: Verify?
        let onFailure: String?
    }

    struct Verify: Decodable {
        let fileExists: String?
        let outputContains: String?
    }

    let steps: [Step]

    static func parse(_ raw: String) throws -> PlannerOutput {
        // The first '{' to the last '}': tolerates ```json fences and a sentence before or after.
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else {
            throw PlanValidationError.notJSON
        }
        do {
            return try JSONDecoder().decode(PlannerOutput.self, from: Data(raw[start...end].utf8))
        } catch {
            throw PlanValidationError.notJSON
        }
    }

    func steps(idPrefix: String = "") -> [TaskStep] {
        steps.enumerated().map { index, step in
            let verification: StepVerification
            if let path = step.verify?.fileExists, !path.isEmpty {
                verification = .fileExists(path)
            } else if let text = step.verify?.outputContains, !text.isEmpty {
                verification = .outputContains(text)
            } else {
                verification = .succeeded
            }
            return TaskStep(
                id: idPrefix + (step.id?.trimmingCharacters(in: .whitespaces).isEmpty == false ? step.id! : "\(index + 1)"),
                title: step.title, tool: step.tool, arguments: step.arguments ?? [:],
                dependsOn: (step.dependsOn ?? []).map { idPrefix + $0 },
                verification: verification,
                onFailure: step.onFailure.flatMap { StepFailurePolicy(rawValue: $0.lowercased()) } ?? .ask)
        }
    }
}

// MARK: - Validation

public enum PlanValidationError: Error, LocalizedError, Equatable, Sendable {
    case notJSON
    case empty
    case tooManySteps(Int)
    case duplicateID(String)
    case unknownTool(step: String, tool: String)
    case forbiddenTool(step: String, tool: String)
    case invalidArguments(step: String, reason: String)
    case unknownDependency(step: String, dependsOn: String)
    case cycle

    public var errorDescription: String? {
        switch self {
        case .notJSON: return "The plan wasn't valid JSON."
        case .empty: return "The plan has no steps."
        case .tooManySteps(let max): return "The plan has more than \(max) steps."
        case .duplicateID(let id): return "Two steps share the id \(id)."
        case .unknownTool(let step, let tool): return "Step \(step) uses \(tool), which isn't an available tool."
        case .forbiddenTool(let step, let tool): return "Step \(step) uses \(tool), which a task may not use."
        case .invalidArguments(let step, let reason): return "Step \(step) has invalid arguments: \(reason)"
        case .unknownDependency(let step, let dep): return "Step \(step) depends on \(dep), which doesn't exist."
        case .cycle: return "The steps depend on each other in a loop."
        }
    }
}

public enum PlanValidator {
    /// Tools a task may not call: they change what Ivy itself does or remembers, which only the user decides.
    public static let forbiddenTools: Set<String> = ["enable_tools", "remember_preference", "schedule_followup"]

    /// Checks every step against the real tools (name exists, arguments pass the tool's own validation), ids
    /// unique, dependencies known and acyclic, and the step budget. Returns the steps in a runnable order
    /// (dependencies first, otherwise as planned).
    public static func validate(_ steps: [TaskStep], registry: ToolRegistry, budget: TaskBudget) throws -> [TaskStep] {
        guard !steps.isEmpty else { throw PlanValidationError.empty }
        guard steps.count <= budget.maxSteps else { throw PlanValidationError.tooManySteps(budget.maxSteps) }

        var ids = Set<String>()
        for step in steps {
            guard ids.insert(step.id).inserted else { throw PlanValidationError.duplicateID(step.id) }
        }
        for step in steps {
            guard !forbiddenTools.contains(step.tool) else { throw PlanValidationError.forbiddenTool(step: step.id, tool: step.tool) }
            guard let tool = registry.tool(named: step.tool) else { throw PlanValidationError.unknownTool(step: step.id, tool: step.tool) }
            do {
                try tool.validate(arguments: step.arguments)
            } catch {
                throw PlanValidationError.invalidArguments(step: step.id, reason: error.localizedDescription)
            }
            for dep in step.dependsOn where !ids.contains(dep) {
                throw PlanValidationError.unknownDependency(step: step.id, dependsOn: dep)
            }
            if case .fileExists(let path) = step.verification {
                do {
                    _ = try ToolValidation.validateFilePath(path)
                } catch {
                    throw PlanValidationError.invalidArguments(step: step.id, reason: "its check refers to a path Ivy can't use (\(path)).")
                }
            }
        }
        return try ordered(steps)
    }

    /// Kahn's algorithm, picking the earliest planned step each time, so independent steps keep their order.
    static func ordered(_ steps: [TaskStep]) throws -> [TaskStep] {
        var remaining = steps
        var done = Set<String>()
        var result: [TaskStep] = []
        while !remaining.isEmpty {
            guard let index = remaining.firstIndex(where: { $0.dependsOn.allSatisfy(done.contains) }) else {
                throw PlanValidationError.cycle
            }
            let step = remaining.remove(at: index)
            done.insert(step.id)
            result.append(step)
        }
        return result
    }
}
