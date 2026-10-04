import Foundation
import Combine

/// A reviewable request, not an executable patch. The model must read the target and ask SafetyGate
/// approval for the final file_op write. A unified diff is never passed as the file's replacement content.
public enum DiffDraft {
    public enum DraftError: LocalizedError {
        case invalidPath, invalidDiff
        public var errorDescription: String? {
            switch self {
            case .invalidPath: "Choose a file path without newlines, null bytes or parent traversal."
            case .invalidDiff: "This block doesn't contain a text diff, or is too large to draft."
            }
        }
    }

    public static func suggestedPath(in diff: String) -> String {
        guard let header = diff.split(separator: "\n").first(where: { $0.hasPrefix("+++ ") }) else { return "" }
        var path = String(header.dropFirst(4).split(separator: "\t").first ?? "")
        if path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
        return path == "/dev/null" ? "" : path
    }

    public static func make(diff: String, path: String) throws -> String {
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains(where: { $0.isNewline || $0 == "\0" }),
              !path.split(separator: "/").contains("..") else { throw DraftError.invalidPath }
        let lines = diff.split(separator: "\n")
        guard diff.utf8.count <= 200_000,
              lines.contains(where: { ($0.hasPrefix("+") && !$0.hasPrefix("+++")) || ($0.hasPrefix("-") && !$0.hasPrefix("---")) }),
              !diff.contains("GIT binary patch"), !diff.contains("Binary files ") else { throw DraftError.invalidDiff }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let request: [String: AnyCodable] = ["tool": "file_op", "action": "write", "path": .string(path), "proposed_diff": .string(diff)]
        let data = try encoder.encode(request)
        return "Review this proposed file_op change. Read the target file first, apply only matching text hunks, and show the resulting write for approval. If the path or hunks are ambiguous, ask me. The proposed_diff is a patch, not replacement file content.\n\n"
            + String(decoding: data, as: UTF8.self)
    }

    public static func appending(_ draft: String, to existing: String) -> String {
        existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? draft : existing + "\n\n" + draft
    }
}

@MainActor
public final class DiffDraftProposal: ObservableObject, Identifiable {
    public let id = UUID()
    public let diff: String
    @Published public var path: String
    @Published public private(set) var error: String?
    public init(diff: String) { self.diff = diff; self.path = DiffDraft.suggestedPath(in: diff) }
    public func draft() -> String? {
        do {
            let result = try DiffDraft.make(diff: diff, path: path)
            error = nil
            return result
        } catch { self.error = error.localizedDescription; return nil }
    }
}
