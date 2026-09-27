import Foundation

/// Ivy tool for launching macOS applications via WorkspaceProtocol.
public final class OpenAppTool: IvyTool, Sendable {
    public let name: String = "open_app"
    public let description: String = "Opens a native macOS application by name (e.g., Safari, Notes, Calendar, Slack)."

    public let declaration: FunctionDeclaration = FunctionDeclaration(
        name: "open_app",
        description: "Opens a native macOS application by name (e.g., Safari, Notes, Calendar, Slack).",
        parameters: ToolParameters(
            type: "OBJECT",
            properties: [
                "name": ToolProperty(
                    type: "STRING",
                    description: "The name of the macOS application to launch (e.g., Safari, Notes, Calendar, Slack)."
                )
            ],
            required: ["name"]
        )
    )

    public var safetyClassification: ToolSafetyClassification { .safe }

    private let workspace: WorkspaceProtocol

    public init(workspace: WorkspaceProtocol = SystemWorkspace()) {
        self.workspace = workspace
    }

    public func validate(arguments: [String: AnyCodable]) throws {
        for key in arguments.keys {
            if key != "name" {
                throw ToolError.invalidArgument("Unexpected argument: '\(key)'.")
            }
        }

        guard let nameValue = arguments["name"] else {
            throw ToolError.missingArgument("name")
        }

        guard let nameArg = nameValue.stringValue else {
            throw ToolError.invalidArgument("Argument 'name' must be a string.")
        }

        _ = try ToolValidation.validateAppName(nameArg)
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard let nameValue = arguments["name"] else {
            throw ToolError.missingArgument("name")
        }

        guard let nameArg = nameValue.stringValue else {
            throw ToolError.invalidArgument("Argument 'name' must be a string.")
        }

        let validatedName = try ToolValidation.validateAppName(nameArg)

        guard let appURL = workspace.findApplicationURL(named: validatedName) else {
            return ToolResult.failure("Application '\(validatedName)' not found. Make sure it is installed in /Applications.")
        }

        do {
            try await workspace.openApplication(at: appURL)
            return ToolResult.success("Opened \(validatedName) successfully.")
        } catch {
            return ToolResult.failure("Failed to open '\(validatedName)': \(error.localizedDescription)")
        }
    }
}
