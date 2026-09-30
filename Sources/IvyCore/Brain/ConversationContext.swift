import Foundation

/// How much conversation is sent verbatim before older turns are folded into a summary.
public struct ContextBudget: Sendable, Equatable {
    /// The model's input limit in tokens.
    public var modelLimit: Int
    /// Turns (a user message and the replies to it) that are always sent word for word.
    public static let verbatimTurns = 6
    public static let summaryWordLimit = 300

    public init(modelLimit: Int = 1_048_576) {
        self.modelLimit = modelLimit
    }

    /// Compaction starts above 60% of the model limit, leaving room for the reply and tool traffic.
    public var targetTokens: Int { modelLimit * 6 / 10 }

    /// ponytail: chars / 4, which over-counts English slightly (the safe direction). Swap in the API's
    /// `countTokens` if requests start bouncing off the real limit.
    public static func estimateTokens(_ text: String) -> Int { (text.count + 3) / 4 }

    public static func estimateTokens(_ messages: [ChatMessage]) -> Int {
        messages.reduce(0) { $0 + estimateTokens($1.text) }
    }

    static let summaryPrompt = """
    You maintain the running summary of a conversation between a user and their assistant, Ivy. \
    Merge the existing summary (if any) with the new turns into one summary of at most \(summaryWordLimit) words. \
    Keep facts, decisions, names, file paths and open tasks. Never include credentials, API keys, tokens or passwords. \
    Reply with the summary only.
    """

    static let briefingPrompt = """
    Turn the list below into a short spoken-style briefing of the user's day, at most 80 words, in Ivy's dry voice. \
    Use only what is in the list: do not add events, advice or guesses. If the list says nothing is scheduled, say so in one line.
    """

    static let titlePrompt = """
    Write a title of at most 6 words for this conversation. \
    Reply with the title only: no quotes, no trailing punctuation.
    """

    /// The summariser's input: the previous summary plus the turns being folded in.
    static func summaryRequest(previous: String?, turns: [ChatMessage]) -> String {
        let lines = turns.map { "\($0.role == .user ? "User" : "Ivy"): \($0.text)" }.joined(separator: "\n")
        return "Existing summary:\n\(previous ?? "(none)")\n\nNew turns:\n\(lines)"
    }

    static func cleanSummary(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let limited = words.count > summaryWordLimit ? words.prefix(summaryWordLimit).joined(separator: " ") + "…" : text
        return SecretRedactor.redact(limited.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// One short line: the model's first line, unquoted, at most 6 words.
    static func cleanTitle(_ text: String) -> String {
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let stripped = firstLine.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`*#.:!“”‘’ \t"))
        return SecretRedactor.redact(stripped.split(separator: " ").prefix(6).joined(separator: " "))
    }
}

/// The condensed, redacted memory of one tool execution. Raw results are never kept.
public enum ToolNote {
    public static let resultLimit = 200
    static let argumentLimit = 80

    public static func text(call: FunctionCall, response: FunctionResponse) -> String {
        let args = call.args.keys.sorted()
            .map { "\($0): \(clip(describe(call.args[$0] ?? .null), argumentLimit))" }
            .joined(separator: ", ")
        let outcome: String
        if let error = response.response["error"]?.stringValue {
            outcome = "failed: \(clip(error, resultLimit))"
        } else if let summary = response.response["summary"]?.stringValue {
            // Personal data (contacts, clipboard, mail, notes): remember that it happened, never what came back.
            outcome = "ok: \(clip(summary, resultLimit))"
        } else {
            outcome = "ok: \(clip(response.response["result"]?.stringValue ?? "", resultLimit))"
        }
        return SecretRedactor.redact("\(call.name)(\(args)) → \(outcome)")
    }

    public static func make(call: FunctionCall, response: FunctionResponse, at date: Date = Date()) -> StoredMessage {
        StoredMessage(id: UUID(), role: .function, text: text(call: call, response: response), timestamp: date, isError: false, kind: .toolNote)
    }

    private static func describe(_ value: AnyCodable) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .null: return "null"
        case .array(let a): return "[\(a.map(describe).joined(separator: ", "))]"
        case .dictionary(let d): return "{\(d.keys.sorted().map { "\($0): \(describe(d[$0] ?? .null))" }.joined(separator: ", "))}"
        }
    }

    private static func clip(_ text: String, _ limit: Int) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
