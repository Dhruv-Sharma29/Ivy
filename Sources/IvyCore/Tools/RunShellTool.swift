import Foundation

/// Ivy tool for executing shell commands on macOS.
/// Always classified as risky and requires explicit user confirmation via SafetyGate.
public final class RunShellTool: IvyTool, Sendable {
    public let name: String = "run_shell"
    public let description: String = "Executes a shell command on macOS and returns stdout, stderr, and exit status. Always requires explicit user confirmation before execution."

    public var safetyClassification: ToolSafetyClassification {
        .risky
    }

    public let declaration: FunctionDeclaration = FunctionDeclaration(
        name: "run_shell",
        description: "Executes a shell command on macOS and returns stdout, stderr, and exit status. Always requires explicit user confirmation before execution.",
        parameters: ToolParameters(
            type: "OBJECT",
            properties: [
                "command": ToolProperty(
                    type: "STRING",
                    description: "The shell command to execute (e.g. 'sw_vers', 'git status', 'uname -a')."
                )
            ],
            required: ["command"]
        )
    )

    private let executor: ShellExecutorProtocol

    public init(executor: ShellExecutorProtocol = SystemShellExecutor()) {
        self.executor = executor
    }

    public func validate(arguments: [String: AnyCodable]) throws {
        _ = try ToolValidation.validateShellArguments(arguments)
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let command = try ToolValidation.validateShellArguments(arguments)

        do {
            let result = try await executor.execute(command: command)
            if result.isSuccess {
                return ToolResult.success(result.formattedOutput)
            } else {
                return ToolResult.failure(result.formattedOutput)
            }
        } catch let shellErr as ShellError {
            return ToolResult.failure(shellErr.localizedDescription)
        } catch let toolErr as ToolError {
            return ToolResult.failure(toolErr.localizedDescription)
        } catch {
            return ToolResult.failure("Shell execution error: \(error.localizedDescription)")
        }
    }
}
