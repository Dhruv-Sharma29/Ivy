import Foundation

/// The persisted form of one chat line: only what's needed to show and continue the conversation.
/// Tool-call turns, tool results, thought signatures and audio are deliberately not representable here.
public struct StoredMessage: Codable, Equatable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public let text: String
    public let timestamp: Date
    public let isError: Bool

    public init(id: UUID, role: MessageRole, text: String, timestamp: Date, isError: Bool) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isError = isError
    }
}

public struct Conversation: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public var messages: [StoredMessage]

    public init(id: UUID = UUID(), createdAt: Date = Date(), updatedAt: Date = Date(), messages: [StoredMessage] = []) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    /// Keeps user/model text lines only, with secret-looking tokens redacted.
    public init(id: UUID, createdAt: Date, chatMessages: [ChatMessage]) {
        let kept = chatMessages.compactMap { m -> StoredMessage? in
            guard m.role == .user || m.role == .model,
                  m.functionCall == nil, m.functionResponse == nil,
                  !m.text.isEmpty else { return nil }
            return StoredMessage(id: m.id, role: m.role, text: SecretRedactor.redact(m.text), timestamp: m.timestamp, isError: m.isError)
        }
        self.init(id: id, createdAt: createdAt, updatedAt: kept.last?.timestamp ?? createdAt, messages: kept)
    }

    public var chatMessages: [ChatMessage] {
        messages.map { ChatMessage(id: $0.id, role: $0.role, text: $0.text, timestamp: $0.timestamp, isError: $0.isError) }
    }

    public var title: String {
        let first = messages.first { $0.role == .user }?.text ?? "Conversation"
        return first.count > 60 ? String(first.prefix(60)) + "…" : first
    }
}

public struct ConversationSummary: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let title: String
    public let updatedAt: Date
    public let messageCount: Int
}

public enum ConversationStoreError: Error, LocalizedError, Equatable, Sendable {
    case notFound

    public var errorDescription: String? { "The conversation no longer exists." }
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
}

/// One JSON file per conversation under Application Support, readable only by the user.
public struct FileConversationStore: ConversationStore {
    public let directory: URL

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
    }

    public func load(_ id: UUID) -> Conversation? {
        let url = fileURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try JSONDecoder().decode(Conversation.self, from: Data(contentsOf: url))
        } catch {
            print("[HISTORY] conversation file is unreadable; skipping it")
            return nil
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
    }

    public func list() -> [ConversationSummary] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { UUID(uuidString: $0.deletingPathExtension().lastPathComponent).flatMap(load) }
            .map { ConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt, messageCount: $0.messages.count) }
            .sorted { $0.updatedAt > $1.updatedAt }
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
