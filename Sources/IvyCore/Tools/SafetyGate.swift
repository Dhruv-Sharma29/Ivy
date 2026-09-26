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

/// Production SafetyGate that automatically executes safe tools and intercepts risky tools for user confirmation.
public final class InteractiveSafetyGate: SafetyGateProtocol, Sendable {
    private let confirmationProvider: ConfirmationProvider

    public init(confirmationProvider: ConfirmationProvider) {
        self.confirmationProvider = confirmationProvider
    }

    public func evaluate(tool: IvyTool, call: FunctionCall) async -> SafetyDecision {
        switch tool.safetyClassification {
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
