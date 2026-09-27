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
        switch policy.classification(for: tool, call: call) {
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

    /// Maximum allowed length for a calendar event title.
    public static let maxCalendarTitleLength = 500

    /// Validates and sanitizes a calendar event title.
    /// Rejects empty titles, titles exceeding maximum length, and embedded null bytes.
    public static func validateCalendarTitle(_ rawTitle: String) throws -> String {
        let trimmed = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.invalidArgument("Calendar event title cannot be empty.")
        }

        guard trimmed.count <= maxCalendarTitleLength else {
            throw ToolError.invalidArgument("Calendar event title exceeds maximum length of \(maxCalendarTitleLength) characters.")
        }

        if rawTitle.contains("\0") {
            throw ToolError.invalidArgument("Calendar event title contains invalid null bytes.")
        }

        return trimmed
    }

    /// Parses a calendar event date string.
    /// Supports standard ISO 8601 formats and common date/time formats without guessing.
    /// Throws ToolError.invalidArgument if the string cannot be parsed into a deterministic Date.
    public static func parseCalendarDate(_ rawDate: String) throws -> Date {
        let trimmed = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.invalidArgument("Calendar date cannot be empty.")
        }

        if trimmed.contains("\0") {
            throw ToolError.invalidArgument("Calendar date contains invalid null bytes.")
        }

        // 1. ISO 8601 with internet date/time (with timezone)
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        // 2. ISO 8601 with fractional seconds
        let isoFractionalFormatter = ISO8601DateFormatter()
        isoFractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractionalFormatter.date(from: trimmed) {
            return date
        }

        // 3. DateFormatter formats
        let dateFormats = [
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mmZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ssZZZZZ",
            "yyyy-MM-dd HH:mmZZZZZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm"
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        for format in dateFormats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        // Explicitly reject date-only strings lacking a time component
        let dateOnlyFormatter = DateFormatter()
        dateOnlyFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateOnlyFormatter.dateFormat = "yyyy-MM-dd"
        if dateOnlyFormatter.date(from: trimmed) != nil {
            throw ToolError.invalidArgument("Date '\(trimmed)' is missing a time component. Ambiguous dates without a specified time are not allowed; please provide both date and time (e.g. '2026-10-01 14:00' or '2026-10-01T14:00:00Z').")
        }

        throw ToolError.invalidArgument("Cannot parse date '\(trimmed)'. Expected an ISO 8601 or standard date format (e.g. '2026-10-01T15:00:00Z' or '2026-10-01 15:00').")
    }

    /// Sensitive user and credential paths prohibited from access.
    public static let prohibitedPathSegments: [String] = [
        ".ssh",
        ".gnupg",
        ".aws",
        ".git",
        "Library/Keychains"
    ]

    /// Prohibited root system directories.
    public static let prohibitedSystemRoots: [String] = [
        "/System",
        "/usr",
        "/bin",
        "/sbin",
        "/etc",
        "/var",
        "/private",
        "/opt"
    ]

    /// Maximum allowed path length.
    public static let maxPathLength: Int = 4096

    /// Validates, normalizes, and sanitizes a file path before execution.
    /// Rejects empty paths, null bytes, path traversal sequences ('..'), system directories,
    /// sensitive credential directories, and paths escaping the permitted scope.
    public static func validateFilePath(
        _ rawPath: String,
        allowedRoot: URL? = nil
    ) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.invalidArgument("File path cannot be empty.")
        }

        if rawPath.contains("\0") {
            throw ToolError.invalidArgument("File path contains invalid null bytes.")
        }

        guard trimmed.count <= maxPathLength else {
            throw ToolError.invalidArgument("File path exceeds maximum allowed length of \(maxPathLength) characters.")
        }

        // Prevent path traversal sequences
        if trimmed == ".." || trimmed.contains("..") {
            throw ToolError.invalidArgument("Path traversal sequence '..' is prohibited.")
        }

        // Check prohibited system roots directly
        for sysRoot in prohibitedSystemRoots {
            if trimmed == sysRoot || trimmed.hasPrefix(sysRoot + "/") {
                throw ToolError.invalidArgument("Access to system path '\(sysRoot)' is prohibited.")
            }
        }

        // Expand tilde or resolve relative path
        let baseRoot = (allowedRoot ?? FileManager.default.homeDirectoryForCurrentUser).standardized
        let expandedPath: String
        if trimmed.hasPrefix("~") {
            expandedPath = (trimmed as NSString).expandingTildeInPath
        } else if trimmed.hasPrefix("/") {
            expandedPath = trimmed
        } else {
            expandedPath = baseRoot.appendingPathComponent(trimmed).path
        }

        let standardizedURL = URL(fileURLWithPath: expandedPath).standardized
        let standardizedPath = standardizedURL.path

        // Check against sensitive credential path segments
        for prohibited in prohibitedPathSegments {
            if standardizedPath.contains("/" + prohibited + "/") ||
               standardizedPath.hasSuffix("/" + prohibited) ||
               standardizedPath.contains("/" + prohibited) {
                throw ToolError.invalidArgument("Access to sensitive path containing '\(prohibited)' is prohibited.")
            }
        }

        // Permitted scope check
        let resolvedRoot = baseRoot.resolvingSymlinksInPath().path
        let resolvedTarget = standardizedURL.resolvingSymlinksInPath().path

        guard resolvedTarget == resolvedRoot || resolvedTarget.hasPrefix(resolvedRoot + "/") else {
            throw ToolError.invalidArgument("Path '\(trimmed)' escapes permitted scope '\(resolvedRoot)'.")
        }

        return standardizedPath
    }

    /// Validates all arguments for a file_op call.
    public static func validateFileOpArguments(
        _ args: [String: AnyCodable],
        allowedRoot: URL? = nil
    ) throws -> (action: FileAction, path: String, content: String?) {
        guard let actionValue = args["action"] else {
            throw ToolError.missingArgument("action")
        }
        guard let actionString = actionValue.stringValue else {
            throw ToolError.invalidArgument("Argument 'action' must be a string (read, write, delete).")
        }
        guard let action = FileAction(rawValue: actionString.lowercased()) else {
            throw ToolError.invalidArgument("Invalid file action '\(actionString)'. Supported actions: read, write, delete.")
        }

        guard let pathValue = args["path"] else {
            throw ToolError.missingArgument("path")
        }
        guard let rawPath = pathValue.stringValue else {
            throw ToolError.invalidArgument("Argument 'path' must be a string.")
        }
        let validatedPath = try validateFilePath(rawPath, allowedRoot: allowedRoot)

        let content: String?
        if action == .write {
            guard let contentValue = args["content"] else {
                throw ToolError.missingArgument("content")
            }
            guard let contentString = contentValue.stringValue else {
                throw ToolError.invalidArgument("Argument 'content' must be a string for write operation.")
            }
            content = contentString
        } else {
            content = nil
        }

        return (action, validatedPath, content)
    }
}


