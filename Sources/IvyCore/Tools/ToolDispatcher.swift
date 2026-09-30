import Foundation

/// Dispatches Gemini FunctionCalls to registered IvyTools and handles execution results and errors.
public final class ToolDispatcher: Sendable {
    public let registry: ToolRegistry
    public let safetyGate: SafetyGateProtocol
    public let permissions: PermissionManaging

    public init(
        registry: ToolRegistry,
        safetyGate: SafetyGateProtocol = PassThroughSafetyGate(),
        permissions: PermissionManaging = SystemPermissionManager()
    ) {
        self.registry = registry
        self.safetyGate = safetyGate
        self.permissions = permissions
    }

    /// Dispatches a single FunctionCall and produces a FunctionResponse.
    public func dispatch(_ call: FunctionCall) async -> FunctionResponse {
        guard let tool = registry.tool(named: call.name) else {
            return FunctionResponse(
                name: call.name,
                response: [
                    "error": AnyCodable("Tool '\(call.name)' is not recognized."),
                    "success": AnyCodable(false),
                    "toolNotFound": AnyCodable(true)
                ],
                id: call.id
            )
        }

        // 1. Argument validation before SafetyGate
        do {
            try tool.validate(arguments: call.args)
        } catch {
            return FunctionResponse(
                name: call.name,
                response: [
                    "error": AnyCodable(error.localizedDescription),
                    "success": AnyCodable(false),
                    "validationError": AnyCodable(true)
                ],
                id: call.id
            )
        }

        // 2. SafetyGate evaluation & confirmation
        let decision = await safetyGate.evaluate(tool: tool, call: call)
        switch decision {
        case .reject(let reason):
            let isCancelled = reason.localizedCaseInsensitiveContains("cancel")
            var resp: [String: AnyCodable] = [
                "error": AnyCodable(reason),
                "success": AnyCodable(false),
                "rejected": AnyCodable(true)
            ]
            if isCancelled {
                resp["cancelled"] = AnyCodable(true)
            }
            return FunctionResponse(
                name: call.name,
                response: resp,
                id: call.id
            )
        case .approve:
            break
        }

        // 3. macOS permissions: only now, so the user is never prompted for access to something they
        // haven't agreed to let Ivy do.
        for permission in tool.requiredPermissions(for: call.args) {
            let state = await permissions.requestPermission(for: permission)
            guard state == .authorized else {
                var response: [String: AnyCodable] = [
                    "error": AnyCodable("\(permission.displayName) access is \(state == .unsupported ? "not available" : "not allowed") for Ivy. "
                        + "The user can turn it on in System Settings › Privacy & Security › \(permission.displayName), then ask again."),
                    "success": AnyCodable(false),
                    "permissionDenied": AnyCodable(true),
                    "permission": AnyCodable(permission.rawValue)
                ]
                if let url = permission.settingsURL {
                    response["settingsURL"] = AnyCodable(url.absoluteString)
                }
                return FunctionResponse(name: call.name, response: response, id: call.id)
            }
        }

        do {
            var result = try await tool.execute(arguments: call.args)
            // The v1.0 core tools keep their own limits; everything newer is capped here.
            if tool.group != .core { result = result.capped() }
            if let summary = result.summary, !result.isError {
                return FunctionResponse(
                    name: call.name,
                    response: [
                        "result": AnyCodable(result.output),
                        "success": AnyCodable(true),
                        "summary": AnyCodable(summary)
                    ],
                    id: call.id
                )
            }
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
