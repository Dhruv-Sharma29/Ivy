import Foundation

/// The outcome of an Ivy tool execution.
public struct ToolResult: Sendable, Equatable {
    public let output: String
    public let isError: Bool

    public init(output: String, isError: Bool = false) {
        self.output = output
        self.isError = isError
    }

    public static func success(_ output: String) -> ToolResult {
        ToolResult(output: output, isError: false)
    }

    public static func failure(_ error: String) -> ToolResult {
        ToolResult(output: error, isError: true)
    }
}

/// Errors occurring during tool resolution, validation, or execution.
public enum ToolError: Error, LocalizedError, Equatable, Sendable {
    case missingArgument(String)
    case invalidArgument(String)
    case toolNotFound(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingArgument(let arg):
            return "Missing required argument: '\(arg)'"
        case .invalidArgument(let msg):
            return "Invalid argument: \(msg)"
        case .toolNotFound(let name):
            return "Unknown tool: '\(name)'"
        case .executionFailed(let msg):
            return "Execution failed: \(msg)"
        }
    }
}

/// Validation utilities for tool inputs.
public enum ToolValidation {
    /// Maximum allowed length for an application name.
    public static let maxAppNameLength = 100

    /// Validates and sanitizes a macOS application name.
    /// Rejects empty strings, path traversals, shell metacharacters, and overly long inputs.
    public static func validateAppName(_ rawName: String) throws -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.invalidArgument("Application name cannot be empty.")
        }

        guard trimmed.count <= maxAppNameLength else {
            throw ToolError.invalidArgument("Application name exceeds maximum length of \(maxAppNameLength) characters.")
        }

        // Reject directory path traversals, hidden files, and separators
        if trimmed == "." || trimmed == ".." || trimmed.hasPrefix(".") || trimmed.contains("..") || trimmed.contains("/") || trimmed.contains("\\") {
            throw ToolError.invalidArgument("Application name cannot contain path separators or traversal sequences.")
        }

        // Reject shell metacharacters, control characters, and injection vectors
        let dangerousChars = CharacterSet(charactersIn: ";`$|&><*?~^\0\n\r\t{}[]()")
        if trimmed.rangeOfCharacter(from: dangerousChars) != nil {
            throw ToolError.invalidArgument("Application name contains invalid or unsafe characters.")
        }

        return trimmed
    }
}
