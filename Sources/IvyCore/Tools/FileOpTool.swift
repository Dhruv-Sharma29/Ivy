import Foundation

/// Ivy tool for reading, writing, and deleting files within permitted filesystem scopes.
public final class FileOpTool: IvyTool, Sendable {
    public let name: String = "file_op"
    public let description: String = "Performs file operations (read, write, delete) on the local filesystem within permitted scopes."

    /// Default safety classification when evaluated without call context.
    /// In InteractiveSafetyGate with call context, 'read' is classified as safe,
    /// while 'write' and 'delete' are classified as risky.
    public var safetyClassification: ToolSafetyClassification {
        .risky
    }

    public let declaration: FunctionDeclaration = FunctionDeclaration(
        name: "file_op",
        description: "Performs file operations (read, write, delete) on the local filesystem within permitted scopes.",
        parameters: ToolParameters(
            type: "OBJECT",
            properties: [
                "action": ToolProperty(
                    type: "STRING",
                    description: "The file operation to perform. Supported values: 'read', 'write', 'delete'."
                ),
                "path": ToolProperty(
                    type: "STRING",
                    description: "The path of the file to operate on. Must be within the permitted user scope (e.g. '~/Documents/notes.txt')."
                ),
                "content": ToolProperty(
                    type: "STRING",
                    description: "The text content to write to the file. Required when action is 'write'."
                )
            ],
            required: ["action", "path"]
        )
    )

    private let executor: FileExecutorProtocol
    public let allowedRoot: URL?

    public init(
        executor: FileExecutorProtocol = SystemFileExecutor(),
        allowedRoot: URL? = nil
    ) {
        self.executor = executor
        self.allowedRoot = allowedRoot
    }

    public func validate(arguments: [String: AnyCodable]) throws {
        _ = try ToolValidation.validateFileOpArguments(arguments, allowedRoot: allowedRoot)
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let (action, validatedPath, content) = try ToolValidation.validateFileOpArguments(arguments, allowedRoot: allowedRoot)

        do {
            let result: FileOpResult
            switch action {
            case .read:
                result = try await executor.readFile(at: validatedPath)
            case .write:
                guard let content else {
                    throw ToolError.missingArgument("content")
                }
                result = try await executor.writeFile(at: validatedPath, content: content)
            case .delete:
                result = try await executor.deleteFile(at: validatedPath)
            }
            return ToolResult.success(result.message)
        } catch let fileErr as FileOpError {
            return ToolResult.failure(fileErr.localizedDescription)
        } catch let toolErr as ToolError {
            return ToolResult.failure(toolErr.localizedDescription)
        } catch {
            return ToolResult.failure("File operation error: \(error.localizedDescription)")
        }
    }
}
