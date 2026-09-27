import Foundation

/// A structured request presented to the user to authorize execution of a risky tool.
public struct ConfirmationRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let toolName: String
    public let title: String
    public let prompt: String
    public let detail: String

    public init(
        id: UUID = UUID(),
        toolName: String,
        title: String,
        prompt: String,
        detail: String
    ) {
        self.id = id
        self.toolName = toolName
        self.title = title
        self.prompt = prompt
        self.detail = detail
    }
}

/// Protocol providing user confirmation decisions for risky tool executions.
public protocol ConfirmationProvider: Sendable {
    /// Requests explicit user approval for a risky tool action.
    /// Returns `true` if approved ("Do it"), `false` if cancelled ("Cancel").
    func requestConfirmation(for request: ConfirmationRequest) async -> Bool
}

/// A handler running on MainActor that presents and responds to confirmation requests.
@MainActor
public protocol ConfirmationHandler: AnyObject {
    /// Handles presenting the confirmation request to the user and awaits their decision.
    func handleConfirmation(_ request: ConfirmationRequest) async -> Bool
}

/// A MainActor-isolated ConfirmationProvider bridging async tool execution to the UI.
@MainActor
public final class ConfirmationBridge: ConfirmationProvider {
    public weak var handler: (any ConfirmationHandler)?

    public init(handler: (any ConfirmationHandler)? = nil) {
        self.handler = handler
    }

    public func requestConfirmation(for request: ConfirmationRequest) async -> Bool {
        guard let handler else { return false }
        return await handler.handleConfirmation(request)
    }
}

/// A closure-backed ConfirmationProvider for unit testing and custom policy routing.
public final class ClosureConfirmationProvider: ConfirmationProvider, Sendable {
    private let handler: @Sendable (ConfirmationRequest) async -> Bool

    public init(handler: @escaping @Sendable (ConfirmationRequest) async -> Bool) {
        self.handler = handler
    }

    public func requestConfirmation(for request: ConfirmationRequest) async -> Bool {
        await handler(request)
    }
}

/// Centralized safety risk policy governing tool classification.
/// Decouples security and risk policy from individual tool implementations.
public struct SafetyPolicy: Sendable, Equatable {
    public let safeToolNames: Set<String>
    public let riskyToolNames: Set<String>
    public let defaultClassification: ToolSafetyClassification

    public init(
        safeToolNames: Set<String> = ["open_app"],
        riskyToolNames: Set<String> = ["run_applescript"],
        defaultClassification: ToolSafetyClassification = .risky
    ) {
        self.safeToolNames = safeToolNames
        self.riskyToolNames = riskyToolNames
        self.defaultClassification = defaultClassification
    }

    /// Evaluates the safety classification for a given tool name.
    public func classification(for toolName: String) -> ToolSafetyClassification {
        if riskyToolNames.contains(toolName) {
            return .risky
        }
        if safeToolNames.contains(toolName) {
            return .safe
        }
        return defaultClassification
    }

    /// Evaluates the safety classification for an IvyTool.
    /// Defends in depth: if the centralized policy classifies the tool name as risky,
    /// or if the tool marks itself as risky, user confirmation is mandatory.
    public func classification(for tool: IvyTool) -> ToolSafetyClassification {
        if riskyToolNames.contains(tool.name) || tool.safetyClassification == .risky {
            return .risky
        }
        if safeToolNames.contains(tool.name) {
            return .safe
        }
        return tool.safetyClassification
    }
}

/// Production SafetyGate that automatically executes safe tools and intercepts risky tools for user confirmation.
public final class InteractiveSafetyGate: SafetyGateProtocol, Sendable {
    public let policy: SafetyPolicy
    private let confirmationProvider: ConfirmationProvider

    public init(
        confirmationProvider: ConfirmationProvider,
        policy: SafetyPolicy = SafetyPolicy()
    ) {
        self.confirmationProvider = confirmationProvider
        self.policy = policy
    }

    public func evaluate(tool: IvyTool, call: FunctionCall) async -> SafetyDecision {
        switch policy.classification(for: tool) {
        case .safe:
            return .approve

        case .risky:
            let request = buildConfirmationRequest(tool: tool, call: call)
            let approved = await confirmationProvider.requestConfirmation(for: request)
            if approved {
                return .approve
            } else {
                return .reject(reason: "User cancelled operation with prejudice.")
            }
        }
    }

    private func buildConfirmationRequest(tool: IvyTool, call: FunctionCall) -> ConfirmationRequest {
        if tool.name == "run_applescript" {
            let script = call.args["script"]?.stringValue ?? "(empty script)"
            return ConfirmationRequest(
                toolName: tool.name,
                title: "AppleScript Execution",
                prompt: "You're about to run an AppleScript. If you regret this, don't blame me. Do it or chicken out?",
                detail: script
            )
        } else {
            return ConfirmationRequest(
                toolName: tool.name,
                title: "\(tool.name) Execution",
                prompt: "You're about to run '\(tool.name)'. If you regret this, don't blame me. Do it or chicken out?",
                detail: "\(call.args)"
            )
        }
    }
}
