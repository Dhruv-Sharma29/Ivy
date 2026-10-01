import Foundation

/// A model reply split into what the chat window draws differently: prose (Markdown), code blocks and diffs.
/// Pure parsing: nothing here is executed, and a diff is only ever displayed (applying one is a `file_op`
/// write, which goes through SafetyGate like any other).
public enum MessageBlock: Equatable, Sendable {
    case text(String)
    case code(language: String?, code: String)
    case diff(String)

    /// Fenced blocks (```lang … ```) become code, or a diff for `diff`/`patch`. An unclosed fence runs to the
    /// end of the message, so a reply cut off mid-block still shows as code.
    public static func parse(_ message: String) -> [MessageBlock] {
        var blocks: [MessageBlock] = []
        var prose: [Substring] = []
        var fence: (language: String?, lines: [Substring])?

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(.text(text)) }
            prose = []
        }

        func closeFence() {
            guard let open = fence else { return }
            let body = open.lines.joined(separator: "\n")
            if let language = open.language, ["diff", "patch"].contains(language) {
                blocks.append(.diff(body))
            } else {
                blocks.append(.code(language: open.language, code: body))
            }
            fence = nil
        }

        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fence != nil {
                if trimmed == "```" {
                    closeFence()
                } else {
                    fence?.lines.append(line)
                }
            } else if trimmed.hasPrefix("```") {
                flushProse()
                let info = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                let language = info.split(separator: " ").first.map(String.init)
                fence = (language?.isEmpty == false ? language : nil, [])
            } else {
                prose.append(line)
            }
        }
        closeFence()
        flushProse()
        return blocks
    }
}

/// How one line of a diff is drawn.
public enum DiffLineKind: Equatable, Sendable {
    case added, removed, hunk, header, context

    public static func of(_ line: Substring) -> DiffLineKind {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return .header }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        return .context
    }
}
