import Foundation

/// Produces a plan (as the planner's JSON text) for a goal. One model call per plan or re-plan.
public protocol TaskPlanning: Sendable {
    /// `context` is empty for a first plan; for a re-plan it describes what ran and what failed.
    func plan(goal: String, context: String, tools: [FunctionDeclaration]) async throws -> String
}

/// Plans with Gemini over REST. The prompt lists the real tools; the reply is parsed and validated before
/// the user ever sees it, and nothing in it is executed without passing SafetyGate step by step.
public struct GeminiTaskPlanner: TaskPlanning {
    private let planner: ModelTaskPlanner

    public init(client: GeminiClientProtocol, credentials: CredentialProvider) {
        planner = ModelTaskPlanner(provider: GeminiModelProvider(client: client, credentials: credentials))
    }

    public func plan(goal: String, context: String, tools: [FunctionDeclaration]) async throws -> String {
        try await planner.plan(goal: goal, context: context, tools: tools)
    }

    static let systemPrompt = """
    You plan multi-step tasks for Ivy, a macOS assistant. Reply with JSON only, no prose, in exactly this shape:
    {"steps":[{"id":"1","title":"short human description","tool":"tool_name","arguments":{...},"dependsOn":[],"verify":{"fileExists":"~/path"} or {"outputContains":"text"} or null,"onFailure":"retry|replan|ask|abort"}]}
    Rules: use only the tools listed, with their exact argument names. At most 20 steps. Prefer few, safe, \
    read-only steps; never use sudo, never force-push, never delete anything the goal didn't ask to delete. \
    The user approves the plan and every risky step separately, so never try to skip or pre-approve anything. \
    If the goal can't be done with these tools, reply {"steps":[]}.
    """

    static func request(goal: String, context: String, tools: [FunctionDeclaration]) -> String {
        let catalogue = tools.sorted { $0.name < $1.name }.map { tool -> String in
            let params = (tool.parameters?.properties ?? [:]).keys.sorted().joined(separator: ", ")
            return "- \(tool.name)(\(params)): \(tool.description)"
        }.joined(separator: "\n")
        var text = "Goal: \(SecretRedactor.redact(goal))\n\nTools:\n\(catalogue)"
        if !context.isEmpty { text += "\n\nSo far (plan only the remaining work):\n\(SecretRedactor.redact(context))" }
        return text
    }
}

/// A plan is text to validate and review, never permission to execute a model's tool calls.
public struct ModelTaskPlanner: TaskPlanning {
    private let provider: any ModelProvider

    public init(provider: any ModelProvider) { self.provider = provider }

    public func plan(goal: String, context: String, tools: [FunctionDeclaration]) async throws -> String {
        try await provider.text(for: ModelRequest(
            history: [ChatMessage(role: .user, text: GeminiTaskPlanner.request(goal: goal, context: context, tools: tools))],
            systemPrompt: GeminiTaskPlanner.systemPrompt, purpose: .taskPlan))
    }
}
