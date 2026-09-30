import Foundation
import Combine

public struct ConversationSearchResult: Equatable, Identifiable, Sendable {
    public var id: UUID { conversationID }
    public let conversationID: UUID
    public let title: String
    /// The first matching message (scroll target); nil when only the title matched.
    public let messageID: UUID?
    public let snippet: String
    public let updatedAt: Date
}

/// In-memory inverted index over titles and message text: lowercased word → conversations containing it.
/// Query words match by prefix and must all be present. Nothing is written to disk; audio is never indexed.
struct ConversationSearchIndex {
    private struct Document {
        let entry: ConversationSummary
        let messages: [(id: UUID, text: String)]
    }

    private var documents: [UUID: Document] = [:]
    private var postings: [String: Set<UUID>] = [:]
    /// Sorted vocabulary for prefix lookup; rebuilt after the index changes.
    private var vocabulary: [String]?

    static func tokens(_ text: String) -> [Substring] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }
    }

    /// Brings the index in line with the library: only conversations whose entry changed are read again.
    mutating func sync(with entries: [ConversationSummary], load: (UUID) -> Conversation?) {
        let current = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let stale = documents.keys.filter { current[$0] != documents[$0]?.entry }
        if !stale.isEmpty {
            let gone = Set(stale)
            for word in postings.keys { postings[word]?.subtract(gone) }
            for id in stale { documents[id] = nil }
            vocabulary = nil
        }
        for entry in entries where documents[entry.id] == nil {
            guard let conversation = load(entry.id) else { continue }
            let lines = conversation.messages.filter { $0.kind != .toolNote }.map { (id: $0.id, text: $0.text) }
            documents[entry.id] = Document(entry: entry, messages: lines)
            var words = Set(Self.tokens(entry.title).map(String.init))
            for line in lines { words.formUnion(Self.tokens(line.text).map(String.init)) }
            for word in words { postings[word, default: []].insert(entry.id) }
            vocabulary = nil
        }
    }

    mutating func search(_ query: String, limit: Int = 50) -> [ConversationSearchResult] {
        let words = Self.tokens(query).map(String.init)
        guard !words.isEmpty else { return [] }
        let sorted = vocabulary ?? postings.keys.sorted()
        vocabulary = sorted

        var matches: Set<UUID>?
        for word in words {
            var found = Set<UUID>()
            var i = sorted.partitioningIndex { $0 >= word }
            while i < sorted.count, sorted[i].hasPrefix(word) {
                found.formUnion(postings[sorted[i]] ?? [])
                i += 1
            }
            matches = matches.map { $0.intersection(found) } ?? found
            if matches?.isEmpty == true { return [] }
        }

        return (matches ?? []).compactMap { documents[$0] }
            .sorted { $0.entry.updatedAt > $1.entry.updatedAt }
            .prefix(limit)
            .map { document in
                // ponytail: the snippet is the first message containing the first query word anywhere in it
                // (substring, not word-prefix); tighten if mid-word hits turn out to be confusing.
                for line in document.messages {
                    if let range = line.text.range(of: words[0], options: .caseInsensitive) {
                        return ConversationSearchResult(
                            conversationID: document.entry.id, title: document.entry.title, messageID: line.id,
                            snippet: Self.snippet(line.text, around: range), updatedAt: document.entry.updatedAt)
                    }
                }
                return ConversationSearchResult(
                    conversationID: document.entry.id, title: document.entry.title, messageID: nil,
                    snippet: document.entry.preview, updatedAt: document.entry.updatedAt)
            }
    }

    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end] + (end < text.endIndex ? "…" : "")
    }
}

private extension Array {
    /// First index for which `predicate` is true, assuming it is false then true across the array.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let mid = (low + high) / 2
            if predicate(self[mid]) { high = mid } else { low = mid + 1 }
        }
        return low
    }
}

/// Markdown and JSON forms of a conversation. Both pass every text field through `SecretRedactor`.
public enum ConversationExporter {
    public enum Format: String, Sendable {
        case markdown, json
        public var fileExtension: String { self == .markdown ? "md" : "json" }
    }

    public static func data(_ conversation: Conversation, format: Format) throws -> Data {
        switch format {
        case .markdown:
            return Data(markdown(conversation).utf8)
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(redacted(conversation))
        }
    }

    public static func markdown(_ conversation: Conversation) -> String {
        let c = redacted(conversation)
        let stamp = ISO8601DateFormatter()
        var out = "# \(c.displayTitle)\n\n_Exported from Ivy · created \(stamp.string(from: c.createdAt))_\n"
        if let summary = c.summary {
            out += "\n> **Summary of earlier turns:** \(summary.text.replacingOccurrences(of: "\n", with: " "))\n"
        }
        for message in c.messages {
            out += "\n**\(speaker(message.kind))** · \(stamp.string(from: message.timestamp))\n\n\(message.text)\n"
        }
        return out
    }

    static func redacted(_ conversation: Conversation) -> Conversation {
        var c = conversation
        c.title = SecretRedactor.redact(c.title)
        c.systemContext = c.systemContext.map(SecretRedactor.redact)
        if let summary = c.summary?.text { c.summary?.text = SecretRedactor.redact(summary) }
        c.messages = c.messages.map {
            StoredMessage(id: $0.id, role: $0.role, text: SecretRedactor.redact($0.text), timestamp: $0.timestamp, isError: $0.isError, kind: $0.kind)
        }
        return c
    }

    private static func speaker(_ kind: StoredMessage.Kind) -> String {
        switch kind {
        case .user: return "You"
        case .model: return "Ivy"
        case .error: return "Ivy (error)"
        case .toolNote: return "Tool"
        case .voiceUser: return "You (voice)"
        case .voiceModel: return "Ivy (voice)"
        }
    }
}

/// The user's saved conversations: browse, switch, organise, search, export.
@MainActor
public final class ConversationLibrary: ObservableObject {
    public enum Filter: Sendable {
        /// Everything not archived, pinned first.
        case active
        case pinned
        case archived
    }

    /// Newest first. Refreshed after every library operation; call `refresh()` when showing the list.
    @Published public private(set) var entries: [ConversationSummary] = []
    /// The last operation that failed, in words the user can act on.
    @Published public private(set) var lastError: String?

    private let store: ConversationStore
    private let brain: IvyBrain
    private var searchIndex = ConversationSearchIndex()

    public init(store: ConversationStore, brain: IvyBrain) {
        self.store = store
        self.brain = brain
        refresh()
    }

    public var activeConversationID: UUID { brain.conversationID }

    public func refresh() {
        entries = store.list()
    }

    public func list(_ filter: Filter = .active) -> [ConversationSummary] {
        switch filter {
        case .active:
            let shown = entries.filter { !$0.isArchived }
            return shown.filter(\.isPinned) + shown.filter { !$0.isPinned }
        case .pinned:
            return entries.filter { $0.isPinned && !$0.isArchived }
        case .archived:
            return entries.filter(\.isArchived)
        }
    }

    /// Switches the chat to a saved conversation. A pending tool approval in the current one is denied.
    @discardableResult
    public func open(_ id: UUID) -> Bool {
        guard id != brain.conversationID else { return true }
        guard let conversation = store.load(id) else {
            lastError = "That conversation couldn't be opened."
            refresh()
            return false
        }
        brain.load(conversation)
        refresh()
        return true
    }

    public func newConversation() {
        brain.startNewConversation()
        refresh()
    }

    /// An empty title hands naming back to Ivy.
    public func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        change(id) {
            $0.title = trimmed
            $0.titleSource = trimmed.isEmpty ? .auto : .user
        }
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        change(id) { $0.isPinned = pinned }
    }

    /// Reversible. Archiving the conversation on screen moves the chat to a new one.
    public func setArchived(_ id: UUID, _ archived: Bool) {
        change(id) { $0.archivedAt = archived ? Date() : nil }
        if archived, id == brain.conversationID {
            brain.startNewConversation()
        }
        refresh()
    }

    /// Permanent: removes the file and its index entry. The UI confirms before calling this.
    public func delete(_ id: UUID) {
        if id == brain.conversationID {
            brain.clearHistory()
        } else {
            do {
                try store.delete(id)
            } catch {
                lastError = "The conversation couldn't be deleted: \(error.localizedDescription)"
            }
        }
        refresh()
    }

    /// Publishes nothing, so it is safe to call while a view is being drawn.
    public func search(_ query: String) -> [ConversationSearchResult] {
        searchIndex.sync(with: store.list(), load: store.load)
        return searchIndex.search(query)
    }

    /// Redacted export data for the save panel; nil (with `lastError` set) if the conversation is gone.
    public func export(_ id: UUID, format: ConversationExporter.Format) -> Data? {
        guard let conversation = id == brain.conversationID ? brain.currentConversation : store.load(id) else {
            lastError = "That conversation couldn't be exported."
            return nil
        }
        do {
            return try ConversationExporter.data(conversation, format: format)
        } catch {
            lastError = "Export failed: \(error.localizedDescription)"
            return nil
        }
    }

    public func dismissError() {
        lastError = nil
    }

    private func change(_ id: UUID, _ edit: (inout Conversation) -> Void) {
        if id == brain.conversationID {
            brain.updateConversation(edit)
        } else if var conversation = store.load(id) {
            edit(&conversation)
            do {
                try store.save(conversation)
            } catch {
                lastError = "The change couldn't be saved: \(error.localizedDescription)"
            }
        }
        refresh()
    }
}
