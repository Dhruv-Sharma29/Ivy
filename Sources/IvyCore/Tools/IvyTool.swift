import Foundation

/// Protocol governing Ivy tools executable via Gemini function calling.
public protocol IvyTool: Sendable {
    /// Unique identifier for the tool, matching Gemini function name.
    var name: String { get }

    /// Human/model-readable description of what the tool does.
    var description: String { get }

    /// The Gemini FunctionDeclaration schema describing parameters.
    var declaration: FunctionDeclaration { get }

    /// Safety classification of the tool (safe vs risky).
    var safetyClassification: ToolSafetyClassification { get }

    /// Executes the tool with parsed arguments and returns a ToolResult.
    func execute(arguments: [String: AnyCodable]) async throws -> ToolResult
}

public extension IvyTool {
    var safetyClassification: ToolSafetyClassification {
        .safe
    }
}
