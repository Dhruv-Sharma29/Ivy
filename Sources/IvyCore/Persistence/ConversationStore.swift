import Foundation
import os

/// The persisted form of one chat line: only what's needed to show and continue the conversation.
/// Tool-call turns, raw tool results, thought signatures and audio are deliberately not representable here.
public struct StoredMessage: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case user, model, error
        /// Condensed, redacted record of one tool execution (never the raw result).
        case toolNote
        /// Transcripts of a Live voice session (no audio is stored).
        case voiceUser, voiceModel
    }

    public let id: UUID
    public let role: MessageRole
    public let text: String
    public let timestamp: Date
    public let isError: Bool
    public let kind: Kind

    public init(id: UUID, role: MessageRole, text: String, timestamp: Date, isError: Bool, kind: Kind? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isError = isError
        self.kind = kind ?? Self.kind(role: role, isError: isError)
    }

    /// v1 files have no `kind`: it is derived from `role` and `isError`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(MessageRole.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        isError = try c.decode(Bool.self, forKey: .isError)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? Self.kind(role: role, isError: isError)
    }

    private static func kind(role: MessageRole, isError: Bool) -> Kind {
        isError ? .error : (role == .user ? .user : .model)
    }
}

/// Rolling summary of the turns that are no longer sent verbatim. The messages themselves stay on disk.
public struct ConversationSummaryBlock: Codable, Equatable, Sendable {
    public var text: String
    /// The last message the summary covers; everything after it is still sent verbatim.
    public var throughMessageID: UUID
    public var updatedAt: Date

    public init(text: String, throughMessageID: UUID, updatedAt: Date = Date()) {
        self.text = text
        self.throughMessageID = throughMessageID
        self.updatedAt = updatedAt
    }
}

public struct Conversation: Codable, Equatable, Identifiable, Sendable {
    /// Bump when the on-disk shape changes, and add a migration in `init(from:)`.
    public static let currentSchemaVersion = 2

    public enum TitleSource: String, Codable, Sendable {
        /// Derived from the first message or generated; may be replaced by a better automatic title.
        case auto
        /// Typed by the user; never overwritten automatically.
        case user
    }

    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [StoredMessage]
    /// Empty means "not titled yet": `displayTitle` falls back to the first user message.
    public var title: String
    public var titleSource: TitleSource
    public var isPinned: Bool
    public var archivedAt: Date?
    /// Per-conversation instructions appended to the system prompt.
    public var systemContext: String?
    public var summary: ConversationSummaryBlock?
    /// Files written before versioning decode as 1 and are migrated in memory.
    public var schemaVersion: Int = Conversation.currentSchemaVersion

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [StoredMessage] = [],
        title: String = "",
        titleSource: TitleSource = .auto,
        isPinned: Bool = false,
        archivedAt: Date? = nil,
        systemContext: String? = nil,
        summary: ConversationSummaryBlock? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
        self.title = title
        self.titleSource = titleSource
        self.isPinned = isPinned
        self.archivedAt = archivedAt
        self.systemContext = systemContext
        self.summary = summary
    }

    /// v1 → v2: every v2 field is optional on disk, so older files decode with defaults and lose nothing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= Conversation.currentSchemaVersion else {
            throw ConversationStoreError.newerSchema(version)
        }
        id = try c.decode(UUID.self, forKey: .id)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        messages = try c.decode([StoredMessage].self, forKey: .messages)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        titleSource = try c.decodeIfPresent(TitleSource.self, forKey: .titleSource) ?? .auto
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        systemContext = try c.decodeIfPresent(String.self, forKey: .systemContext)
        summary = try c.decodeIfPresent(ConversationSummaryBlock.self, forKey: .summary)
        schemaVersion = Conversation.currentSchemaVersion
    }

    /// Keeps user/model text lines only, with secret-looking tokens redacted.
    public init(id: UUID, createdAt: Date, chatMessages: [ChatMessage]) {
        let kept = chatMessages.compactMap { StoredMessage(chatMessage: $0) }
        self.init(id: id, createdAt: createdAt, updatedAt: kept.last?.timestamp ?? createdAt, messages: kept)
    }

    /// What the chat shows: tool notes are context for the model, not bubbles.
    public var chatMessages: [ChatMessage] {
        messages.filter { $0.kind != .toolNote }
            .map { ChatMessage(id: $0.id, role: $0.role, text: $0.text, timestamp: $0.timestamp, isError: $0.isError) }
    }

    public var isArchived: Bool { archivedAt != nil }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        let first = messages.first { $0.role == .user && $0.kind != .toolNote }?.text ?? "New conversation"
        return first.count > 60 ? String(first.prefix(60)) + "…" : first
    }

    var indexEntry: ConversationSummary {
        let shown = messages.filter { $0.kind != .toolNote }
        return ConversationSummary(
            id: id, title: displayTitle, updatedAt: updatedAt, messageCount: shown.count,
            isPinned: isPinned, isArchived: isArchived, preview: String((shown.last?.text ?? "").prefix(120))
        )
    }
}

extension StoredMessage {
    /// Nil for anything that must not be persisted: tool-call turns, tool results, empty lines.
    init?(chatMessage m: ChatMessage, kind: Kind? = nil) {
        guard m.role == .user || m.role == .model,
              m.functionCall == nil, m.functionResponse == nil,
              !m.text.isEmpty else { return nil }
        self.init(id: m.id, role: m.role, text: SecretRedactor.redact(m.text), timestamp: m.timestamp, isError: m.isError, kind: kind)
    }
}

/// One row of the library; also the entry format of `index.json`.
public struct ConversationSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let messageCount: Int
    public var isPinned: Bool = false
    public var isArchived: Bool = false
    /// Start of the latest message.
    public var preview: String = ""
}

public enum ConversationStoreError: Error, LocalizedError, Equatable, Sendable {
    case notFound
    /// Written by a newer Ivy; left in place untouched.
    case newerSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .notFound: return "The conversation no longer exists."
        case .newerSchema: return "This conversation was saved by a newer version of Ivy."
        }
    }
}

public protocol ConversationStore: Sendable {
    /// Creates or replaces the conversation.
    func save(_ conversation: Conversation) throws
    /// Nil when missing or unreadable (corrupt data never crashes or throws here).
    func load(_ id: UUID) -> Conversation?
    /// Replaces an existing conversation; throws `notFound` if it was never saved or was deleted.
    func update(_ conversation: Conversation) throws
    /// Idempotent.
    func delete(_ id: UUID) throws
    /// Newest first; unreadable entries are skipped.
    func list() -> [ConversationSummary]
    /// Things the user should be told once (e.g. a corrupt file was set aside). Reading clears them.
    func drainRecoveryNotices() -> [String]
}

public extension ConversationStore {
    func drainRecoveryNotices() -> [String] { [] }
}

/// One JSON file per conversation under Application Support, readable only by the user.
public struct FileConversationStore: ConversationStore {
    public let directory: URL
    private let notices = NoticeBox()
    /// Serialises read-modify-write of `index.json`.
    private let indexLock = OSAllocatedUnfairLock()

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ivy/Conversations", isDirectory: true)
    }

    public init(directory: URL = FileConversationStore.defaultDirectory) {
        self.directory = directory
    }

    public func save(_ conversation: Conversation) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = fileURL(conversation.id)
        try JSONEncoder().encode(conversation).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        updateIndex { $0.removeAll { $0.id == conversation.id }; $0.append(conversation.indexEntry) }
    }

    public func load(_ id: UUID) -> Conversation? {
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: url))
        } catch ConversationStoreError.newerSchema {
            // Not corrupt: a newer Ivy wrote it. Leave it where it is.
            notices.add("A conversation saved by a newer version of Ivy was skipped.")
            return nil
        } catch {
            quarantine(url)
            return nil
        }
    }

    public func drainRecoveryNotices() -> [String] {
        notices.drain()
    }

    /// Unreadable files are moved aside (never deleted) so they stop failing on every launch and can be recovered by hand.
    private func quarantine(_ url: URL) {
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let folder = directory.deletingLastPathComponent().appendingPathComponent("Quarantine/\(day)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var target = folder.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)")
            }
            try FileManager.default.moveItem(at: url, to: target)
            print("[HISTORY] unreadable conversation file moved to Quarantine")
            notices.add("A conversation couldn't be read and was set aside in \(folder.path).")
        } catch {
            print("[HISTORY] conversation file is unreadable and could not be quarantined: \(error.localizedDescription)")
            notices.add("A conversation couldn't be read.")
        }
    }

    public func update(_ conversation: Conversation) throws {
        guard FileManager.default.fileExists(atPath: fileURL(conversation.id).path) else {
            throw ConversationStoreError.notFound
        }
        try save(conversation)
    }

    public func delete(_ id: UUID) throws {
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        updateIndex { $0.removeAll { $0.id == id } }
    }

    /// Served from `index.json` (no conversation file is opened). The index is derived data: if it is missing,
    /// unreadable, or disagrees with the files on disk, it is rebuilt by scanning them.
    public func list() -> [ConversationSummary] {
        indexLock.withLock { currentIndex() }.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func conversationIDsOnDisk() -> Set<UUID> {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        } catch {
            return [] // no directory yet: nothing has been saved
        }
        return Set(names.compactMap { $0.hasSuffix(".json") ? UUID(uuidString: String($0.dropLast(5))) : nil })
    }

    /// Call with `indexLock` held.
    private func currentIndex() -> [ConversationSummary] {
        let onDisk = conversationIDsOnDisk()
        if let data = FileManager.default.contents(atPath: indexURL.path) {
            do {
                let entries = try JSONDecoder().decode([ConversationSummary].self, from: data)
                if Set(entries.map(\.id)) == onDisk, entries.count == onDisk.count { return entries }
            } catch {
                print("[HISTORY] conversation index is unreadable; rebuilding")
            }
        }
        // ponytail: a file from a newer Ivy stays on disk but out of the index, so every list() rescans while
        // one exists; track skipped ids in the index if downgrades become common.
        let rebuilt = onDisk.compactMap { load($0)?.indexEntry }
        writeIndex(rebuilt)
        return rebuilt
    }

    private func updateIndex(_ change: @Sendable (inout [ConversationSummary]) -> Void) {
        indexLock.withLock {
            var entries = currentIndex()
            change(&entries)
            writeIndex(entries)
        }
    }

    private func writeIndex(_ entries: [ConversationSummary]) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do {
            try JSONEncoder().encode(entries).write(to: indexURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
        } catch {
            // Not fatal: the next list() sees the mismatch and rebuilds from the conversation files.
            print("[HISTORY] failed to write conversation index: \(error.localizedDescription)")
        }
    }

    private func fileURL(_ id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}

/// Masks credential-shaped tokens before text is persisted or logged.
public enum SecretRedactor {
    public static let placeholder = "[REDACTED]"

    /// ponytail: pattern list covers Google/Gemini, ElevenLabs, OpenAI/Anthropic-style and bearer/assignment forms;
    /// extend it if a new provider's key shape shows up.
    static let patterns = [
        #"AIza[0-9A-Za-z_\-]{30,}"#,
        #"AQ\.[0-9A-Za-z_\-]{30,}"#,
        #"\bsk[-_](?:ant-|proj-)?[0-9A-Za-z_\-]{20,}"#,
        #"(?i)\bbearer\s+[0-9A-Za-z._\-]{16,}"#,
        #"(?i)\b(api[_-]?key|secret|token|password)\b(\s*[:=]\s*)["']?[^\s"']{8,}"#
    ]

    public static func redact(_ text: String) -> String {
        var out = text
        for (i, pattern) in patterns.enumerated() {
            let template = i == patterns.count - 1 ? "$1$2\(placeholder)" : placeholder
            out = out.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return out
    }
}

/// Thread-safe, de-duplicated list of one-time user notices.
final class NoticeBox: Sendable {
    private let items = OSAllocatedUnfairLock(initialState: [String]())

    func add(_ notice: String) {
        items.withLock { if !$0.contains(notice) { $0.append(notice) } }
    }

    func drain() -> [String] {
        items.withLock { notices in
            defer { notices = [] }
            return notices
        }
    }
}
