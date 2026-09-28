import Foundation
import os
@testable import IvyCore

/// In-memory Keychain with the same contract as `SystemKeychainStore`; never touches the real Keychain.
final class InMemoryKeychainStore: KeychainStore, @unchecked Sendable {
    private let items = OSAllocatedUnfairLock(initialState: [CredentialKey: Data]())
    private let failure = OSAllocatedUnfairLock<KeychainError?>(initialState: nil)

    /// Makes every read fail with `error` (e.g. `.accessDenied`).
    func failReads(with error: KeychainError?) { failure.withLock { $0 = error } }
    var snapshot: [CredentialKey: Data] { items.withLock { $0 } }

    func save(_ data: Data, for key: CredentialKey) throws {
        try items.withLock { items in
            guard items[key] == nil else { throw KeychainError.duplicateItem }
            items[key] = data
        }
    }

    func read(_ key: CredentialKey) throws -> Data {
        if let error = failure.withLock({ $0 }) { throw error }
        guard let data = items.withLock({ $0[key] }) else { throw KeychainError.itemNotFound }
        return data
    }

    func update(_ data: Data, for key: CredentialKey) throws {
        try items.withLock { items in
            guard items[key] != nil else { throw KeychainError.itemNotFound }
            items[key] = data
        }
    }

    func delete(_ key: CredentialKey) throws {
        try items.withLock { items in
            guard items.removeValue(forKey: key) != nil else { throw KeychainError.itemNotFound }
        }
    }

    func exists(_ key: CredentialKey) -> Bool {
        items.withLock { $0[key] != nil }
    }
}

final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let stored = OSAllocatedUnfairLock<IvySettings?>(initialState: nil)
    init(_ initial: IvySettings? = nil) { stored.withLock { $0 = initial } }
    func load() -> IvySettings { stored.withLock { $0 } ?? .defaults }
    func save(_ settings: IvySettings) throws { stored.withLock { $0 = settings } }
    var saved: IvySettings? { stored.withLock { $0 } }
}

final class InMemoryConversationStore: ConversationStore, @unchecked Sendable {
    private let items = OSAllocatedUnfairLock(initialState: [UUID: Conversation]())
    var all: [Conversation] { items.withLock { Array($0.values) } }

    func save(_ conversation: Conversation) throws { items.withLock { $0[conversation.id] = conversation } }
    func load(_ id: UUID) -> Conversation? { items.withLock { $0[id] } }
    func update(_ conversation: Conversation) throws {
        try items.withLock { items in
            guard items[conversation.id] != nil else { throw ConversationStoreError.notFound }
            items[conversation.id] = conversation
        }
    }
    func delete(_ id: UUID) throws { _ = items.withLock { $0.removeValue(forKey: id) } }
    func list() -> [ConversationSummary] {
        items.withLock { Array($0.values) }
            .map { ConversationSummary(id: $0.id, title: $0.title, updatedAt: $0.updatedAt, messageCount: $0.messages.count) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}

/// Gemini client that records the key it was given and can script one tool call before replying.
final class RecordingGeminiClient: GeminiClientProtocol, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (keys: [String](), calls: 0))
    let toolCall: FunctionCall?
    let reply: String

    init(toolCall: FunctionCall? = nil, reply: String = "Fine, done.") {
        self.toolCall = toolCall
        self.reply = reply
    }

    var receivedKeys: [String] { state.withLock { $0.keys } }

    func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { reply }

    func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
        let first = state.withLock { s -> Bool in
            s.keys.append(apiKey)
            s.calls += 1
            return s.calls == 1
        }
        if first, let toolCall, history.last?.functionResponse == nil {
            return ModelTurnResponse(functionCalls: [toolCall])
        }
        return ModelTurnResponse(text: reply)
    }
}

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ivy-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
