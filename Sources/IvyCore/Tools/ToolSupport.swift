import Foundation
import os

/// Tools are declared to the model in groups: `core` always, the others when the request calls for them,
/// so a request doesn't carry thirty declarations to open an app.
public enum ToolGroup: String, CaseIterable, Sendable {
    case core, system, files, media, productivity

    var summary: String {
        switch self {
        case .core: return "apps, shell, AppleScript, files, calendar events"
        case .system: return "notifications, clipboard, System Settings panes, volume, Wi-Fi/Bluetooth, windows, screenshots"
        case .files: return "Finder (reveal, open, selection) and Spotlight file search"
        case .media: return "music playback control"
        case .productivity: return "reminders, notes, contacts, mail drafts"
        }
    }
}

/// Picks tool groups from the words of the user's message. Cheap and local; when it misses, the model can
/// still ask for a group with `enable_tools`.
public enum ToolRouter {
    static let keywords: [ToolGroup: [String]] = [
        .system: ["clipboard", "copied", "copy", "paste", "notify", "notification", "alert me", "settings", "preferences",
                  "volume", "mute", "louder", "quieter", "brightness", "wifi", "wi-fi", "bluetooth", "network",
                  "window", "tile", "resize", "screenshot", "screen shot", "capture the screen", "my screen"],
        .files: ["finder", "folder", "reveal", "find my", "find the file", "search for", "spotlight", "where is", "locate",
                 "pdf", "document", "downloads", "selected file", "selection"],
        .media: ["play", "pause", "song", "track", "music", "spotify", "skip", "next song", "previous", "now playing", "playing"],
        .productivity: ["remind", "reminder", "to-do", "todo", "note", "notes", "contact", "phone number", "email", "e-mail",
                        "mail", "draft", "inbox", "address of"],
    ]

    public static func groups(for message: String) -> Set<ToolGroup> {
        let text = message.lowercased()
        let words = text.split { !$0.isLetter && !$0.isNumber && $0 != "-" }
        var groups: Set<ToolGroup> = [.core]
        for (group, keywords) in keywords {
            // Single words match from the start of a word ("remind" finds "reminders", "play" doesn't find
            // "display"); phrases match anywhere.
            let hit = keywords.contains { keyword in
                keyword.contains(" ") ? text.contains(keyword) : words.contains { $0.hasPrefix(keyword) }
            }
            if hit { groups.insert(group) }
        }
        return groups
    }
}

/// The meta-tool the model calls when it needs a group that wasn't offered. Handled by the brain itself:
/// it changes which declarations are sent next, and runs nothing.
public enum EnableToolsTool {
    public static let name = "enable_tools"

    public static let declaration = FunctionDeclaration(
        name: name,
        description: "Makes another group of tools available for this conversation. Call it when the user's request needs a tool you don't currently have. Groups: "
            + ToolGroup.allCases.filter { $0 != .core }.map { "\($0.rawValue) (\($0.summary))" }.joined(separator: "; ") + ".",
        parameters: ToolParameters(
            properties: ["group": ToolProperty(type: "STRING", description: "One of: system, files, media, productivity.")],
            required: ["group"]
        )
    )

    /// The group asked for, or nil if the argument isn't one.
    public static func group(from call: FunctionCall) -> ToolGroup? {
        guard let raw = call.args["group"]?.stringValue?.lowercased(), let group = ToolGroup(rawValue: raw), group != .core else { return nil }
        return group
    }
}

/// Typed, validated access to a tool call's arguments. Everything a model sends is untrusted.
public struct ToolArguments: Sendable {
    public let raw: [String: AnyCodable]

    public init(_ raw: [String: AnyCodable]) {
        self.raw = raw
    }

    private static let invisibleScalars: Set<UInt32> = [
        0x200B, 0x200C, 0x200D, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF,
    ]

    public func allow(_ keys: Set<String>) throws {
        for key in raw.keys.sorted() where !keys.contains(key) {
            throw ToolError.invalidArgument("Unexpected argument: '\(key)'.")
        }
    }

    /// Trimmed, non-empty text without null bytes, other control characters (newlines and tabs only when
    /// `multiline`) or invisible/bidirectional characters that could disguise what the user is approving.
    public func string(_ key: String, max: Int, multiline: Bool = false) throws -> String {
        guard let value = raw[key] else { throw ToolError.missingArgument(key) }
        guard let text = value.stringValue else { throw ToolError.invalidArgument("Argument '\(key)' must be a string.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ToolError.invalidArgument("Argument '\(key)' cannot be empty.") }
        guard trimmed.count <= max else { throw ToolError.invalidArgument("Argument '\(key)' exceeds \(max) characters.") }
        for scalar in trimmed.unicodeScalars {
            if Self.invisibleScalars.contains(scalar.value) {
                throw ToolError.invalidArgument("Argument '\(key)' contains invisible or bidirectional formatting characters.")
            }
            let isLayout = scalar == "\n" || scalar == "\t" || scalar == "\r"
            if CharacterSet.controlCharacters.contains(scalar), !(multiline && isLayout) {
                throw ToolError.invalidArgument("Argument '\(key)' contains control characters.")
            }
        }
        return trimmed
    }

    public func optionalString(_ key: String, max: Int, multiline: Bool = false) throws -> String? {
        guard raw[key] != nil else { return nil }
        return try string(key, max: max, multiline: multiline)
    }

    /// A lowercase choice from a fixed list.
    public func choice<T: RawRepresentable & CaseIterable>(_ key: String, _ type: T.Type) throws -> T where T.RawValue == String {
        let text = try string(key, max: 40).lowercased()
        guard let value = T(rawValue: text) else {
            throw ToolError.invalidArgument("Invalid \(key) '\(text)'. Supported: \(T.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return value
    }

    /// Whole numbers only (a JSON `3.0` counts; `3.5` and strings do not).
    public func optionalInt(_ key: String) throws -> Int? {
        guard let value = raw[key] else { return nil }
        if let i = value.intValue { return i }
        if case .double(let d) = value, d == d.rounded(), abs(d) < 1e9 { return Int(d) }
        throw ToolError.invalidArgument("Argument '\(key)' must be a whole number.")
    }

    public func int(_ key: String) throws -> Int {
        guard let value = try optionalInt(key) else { throw ToolError.missingArgument(key) }
        return value
    }

    public func optionalBool(_ key: String) throws -> Bool? {
        guard let value = raw[key] else { return nil }
        guard let flag = value.boolValue else { throw ToolError.invalidArgument("Argument '\(key)' must be true or false.") }
        return flag
    }
}

/// Stops a model that loops on a tool: at most `limit` uses per `window`.
public final class ToolRateLimiter: Sendable {
    private let limit: Int
    private let window: TimeInterval
    private let now: @Sendable () -> Date
    private let uses = OSAllocatedUnfairLock(initialState: [Date]())

    public init(limit: Int, per window: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = limit
        self.window = window
        self.now = now
    }

    /// Records a use and returns true, or returns false when the limit is reached.
    public func allow() -> Bool {
        let time = now()
        return uses.withLock { uses in
            uses.removeAll { time.timeIntervalSince($0) >= window }
            guard uses.count < limit else { return false }
            uses.append(time)
            return true
        }
    }
}

/// Builds AppleScript string literals from untrusted text. The result is always exactly one string
/// expression: quotes and backslashes are escaped and line breaks become `linefeed`, so text can never
/// close the literal and continue as script.
public enum AppleScriptLiteral {
    public static func quote(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\"" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return lines.count == 1 ? lines[0] : "(" + lines.joined(separator: " & linefeed & ") + ")"
    }
}

/// What a tool shows on the approval card. Always says exactly what will happen.
public struct ToolConfirmation: Sendable, Equatable {
    public let title: String
    public let prompt: String
    public let detail: String

    public init(title: String, prompt: String, detail: String) {
        self.title = title
        self.prompt = prompt
        self.detail = detail
    }
}

extension ToolResult {
    /// Results larger than this are cut before they reach Gemini.
    public static let maxOutputBytes = 8 * 1024

    /// The same result, cut to `maxOutputBytes` with a marker saying so.
    func capped() -> ToolResult {
        guard output.utf8.count > Self.maxOutputBytes else { return self }
        var cut = String(output.prefix(Self.maxOutputBytes))
        while cut.utf8.count > Self.maxOutputBytes { cut.removeLast(64) }
        return ToolResult(output: cut + "\n… [truncated: result was \(output.utf8.count) bytes]", isError: isError, summary: summary)
    }
}
