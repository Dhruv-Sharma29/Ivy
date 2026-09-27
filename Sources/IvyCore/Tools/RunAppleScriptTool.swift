import Foundation

/// Ivy tool for executing AppleScript snippets via AppleScriptExecutorProtocol.
public final class RunAppleScriptTool: IvyTool, Sendable {
    public let name: String = "run_applescript"
    public let description: String = "Executes an AppleScript snippet on macOS to automate applications or inspect system state."

    public var safetyClassification: ToolSafetyClassification {
        .risky
    }

    public let declaration: FunctionDeclaration = FunctionDeclaration(
        name: "run_applescript",
        description: "Executes an AppleScript snippet on macOS to automate applications or inspect system state.",
        parameters: ToolParameters(
            type: "OBJECT",
            properties: [
                "script": ToolProperty(
                    type: "STRING",
                    description: "The valid AppleScript code string to execute."
                )
            ],
            required: ["script"]
        )
    )

    private let executor: AppleScriptExecutorProtocol

    public init(executor: AppleScriptExecutorProtocol = SystemAppleScriptExecutor()) {
        self.executor = executor
    }

    public func validate(arguments: [String: AnyCodable]) throws {
        guard let scriptValue = arguments["script"] else {
            throw ToolError.missingArgument("script")
        }

        guard let rawScript = scriptValue.stringValue else {
            throw ToolError.invalidArgument("Argument 'script' must be a string.")
        }

        _ = try ToolValidation.validateAppleScript(rawScript)
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard let scriptValue = arguments["script"] else {
            throw ToolError.missingArgument("script")
        }

        guard let rawScript = scriptValue.stringValue else {
            throw ToolError.invalidArgument("Argument 'script' must be a string.")
        }

        let validatedScript = try ToolValidation.validateAppleScript(rawScript)

        do {
            let output = try await executor.execute(script: validatedScript)
            return ToolResult.success(output)
        } catch let toolErr as ToolError {
            return ToolResult.failure(toolErr.localizedDescription)
        } catch {
            return ToolResult.failure("AppleScript execution error: \(error.localizedDescription)")
        }
    }
}
