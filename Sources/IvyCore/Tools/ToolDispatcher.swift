import Foundation

/// Dispatches Gemini FunctionCalls to registered IvyTools and handles execution results and errors.
public final class ToolDispatcher: Sendable {
    public let registry: ToolRegistry
    public let safetyGate: SafetyGateProtocol

    public init(
        registry: ToolRegistry,
        safetyGate: SafetyGateProtocol = PassThroughSafetyGate()
    ) {
        self.registry = registry
        self.safetyGate = safetyGate
    }

    /// Dispatches a single FunctionCall and produces a FunctionResponse.
    public func dispatch(_ call: FunctionCall) async -> FunctionResponse {
        guard let tool = registry.tool(named: call.name) else {
            return FunctionResponse(
                name: call.name,
                response: ["error": AnyCodable("Tool '\(call.name)' is not recognized.")],
                id: call.id
            )
        }

        let decision = await safetyGate.evaluate(tool: tool, call: call)
        switch decision {
        case .reject(let reason):
            return FunctionResponse(
                name: call.name,
                response: [
                    "error": AnyCodable("Execution rejected by safety policy: \(reason)"),
                    "success": AnyCodable(false)
                ],
                id: call.id
            )
        case .approve:
            break
        }

        do {
            let result = try await tool.execute(arguments: call.args)
            if result.isError {
                return FunctionResponse(
                    name: call.name,
                    response: [
                        "error": AnyCodable(result.output),
                        "success": AnyCodable(false)
                    ],
                    id: call.id
                )
            } else {
                return FunctionResponse(
                    name: call.name,
                    response: [
                        "result": AnyCodable(result.output),
                        "success": AnyCodable(true)
                    ],
                    id: call.id
                )
            }
        } catch {
            return FunctionResponse(
                name: call.name,
                response: [
                    "error": AnyCodable(error.localizedDescription),
                    "success": AnyCodable(false)
                ],
                id: call.id
            )
        }
    }

    /// Dispatches multiple FunctionCalls sequentially and collects their FunctionResponses.
    public func dispatchAll(_ calls: [FunctionCall]) async -> [FunctionResponse] {
        var responses: [FunctionResponse] = []
        for call in calls {
            responses.append(await dispatch(call))
        }
        return responses
    }
}
