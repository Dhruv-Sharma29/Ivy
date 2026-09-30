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

    /// Classification of one specific call, for tools whose actions differ (listing is safe, creating is
    /// risky). Defaults to `safetyClassification`.
    func classification(for arguments: [String: AnyCodable]) -> ToolSafetyClassification

    /// Which declaration group the tool belongs to. Defaults to `core` (always declared).
    var group: ToolGroup { get }

    /// macOS permissions this call needs. Checked (and requested) only after the user has approved the call.
    func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType]

    /// The tool's own approval-card copy; nil uses the generic card.
    func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation?

    /// Validates arguments before safety evaluation and execution.
    func validate(arguments: [String: AnyCodable]) throws

    /// Executes the tool with parsed arguments and returns a ToolResult.
    func execute(arguments: [String: AnyCodable]) async throws -> ToolResult
}

public extension IvyTool {
    var safetyClassification: ToolSafetyClassification {
        .safe
    }

    func classification(for arguments: [String: AnyCodable]) -> ToolSafetyClassification {
        safetyClassification
    }

    var group: ToolGroup { .core }

    func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType] { [] }

    func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? { nil }

    func validate(arguments: [String: AnyCodable]) throws {}
}
