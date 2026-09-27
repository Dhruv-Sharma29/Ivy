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

/// Safety risk level for an Ivy tool.
public enum ToolSafetyClassification: String, Sendable, Codable, Equatable {
    case safe
    case risky
}

/// The outcome of a SafetyGate evaluation before tool dispatch.
public enum SafetyDecision: Sendable, Equatable {
    case approve
    case reject(reason: String)
}

/// Interception protocol for inspecting and authorizing tool executions.
public protocol SafetyGateProtocol: Sendable {
    /// Evaluates whether a tool call may proceed.
    func evaluate(tool: IvyTool, call: FunctionCall) async -> SafetyDecision
}

/// Default Phase 2A SafetyGate implementation that auto-approves safe tools.
public final class PassThroughSafetyGate: SafetyGateProtocol, Sendable {
    public let policy: SafetyPolicy

    public init(policy: SafetyPolicy = SafetyPolicy()) {
        self.policy = policy
    }

    public func evaluate(tool: IvyTool, call: FunctionCall) async -> SafetyDecision {
        switch policy.classification(for: tool) {
        case .safe:
            return .approve
        case .risky:
            return .reject(reason: "Execution rejected by safety policy: Tool '\(tool.name)' is classified as risky and requires user confirmation.")
        }
    }
}

/// Validation utilities for tool inputs.
public enum ToolValidation {
    /// Maximum allowed length for an application name.
    public static let maxAppNameLength = 100

    /// Validates and sanitizes a macOS application name.
    /// Rejects empty strings, path traversals, shell metacharacters, control characters,
    /// command-line option injection, and BiDi spoofing sequences.
    public static func validateAppName(_ rawName: String) throws -> String {
        // Reject invisible characters and Unicode bidirectional overrides (BiDi spoofing) on raw scalars
        let invisibleOrBiDiScalars: Set<UInt32> = [
            0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
            0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
            0xFEFF
        ]
        if rawName.unicodeScalars.contains(where: { invisibleOrBiDiScalars.contains($0.value) }) {
            throw ToolError.invalidArgument("Application name cannot contain invisible or bidirectional formatting characters.")
        }

        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.invalidArgument("Application name cannot be empty.")
        }

        guard trimmed.count <= maxAppNameLength else {
            throw ToolError.invalidArgument("Application name exceeds maximum length of \(maxAppNameLength) characters.")
        }

        // Prevent command-line flag / option injection (e.g. -rf, --version)
        if trimmed.hasPrefix("-") {
            throw ToolError.invalidArgument("Application name cannot begin with a hyphen.")
        }

        // Reject directory path traversals, hidden files, and separators
        if trimmed == "." || trimmed == ".." || trimmed.hasPrefix(".") || trimmed.contains("..") || trimmed.contains("/") || trimmed.contains("\\") {
            throw ToolError.invalidArgument("Application name cannot contain path separators or traversal sequences.")
        }

        // Reject shell metacharacters, injection vectors, colons, and quotes
        let dangerousChars = CharacterSet(charactersIn: ";`$|&><*?~^\0\n\r\t{}[]():\"")
        if trimmed.rangeOfCharacter(from: dangerousChars) != nil {
            throw ToolError.invalidArgument("Application name contains invalid or unsafe characters.")
        }

        // Reject all Unicode and ASCII control characters
        if trimmed.rangeOfCharacter(from: .controlCharacters) != nil {
            throw ToolError.invalidArgument("Application name cannot contain control characters.")
        }

        return trimmed
    }

    /// Maximum allowed length for an AppleScript payload (64 KB).
    public static let maxScriptLength = 65_536

    /// Validates an AppleScript payload before execution.
    /// Rejects empty scripts, scripts exceeding size limits, and embedded null bytes.
    public static func validateAppleScript(_ rawScript: String) throws -> String {
        let trimmed = rawScript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.invalidArgument("AppleScript cannot be empty.")
        }

        guard rawScript.count <= maxScriptLength else {
            throw ToolError.invalidArgument("AppleScript exceeds maximum allowed length of \(maxScriptLength) characters.")
        }

        if rawScript.contains("\0") {
            throw ToolError.invalidArgument("AppleScript contains invalid null bytes.")
        }

        return trimmed
    }
}


