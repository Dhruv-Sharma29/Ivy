import Foundation
import os

/// Recovery-session history. It cannot migrate, quarantine, or overwrite files from the existing install.
public final class TemporaryConversationStore: ConversationStore, Sendable {
    private let items = OSAllocatedUnfairLock(initialState: [UUID: Conversation]())
    public init() {}
    public func save(_ conversation: Conversation) throws { items.withLock { $0[conversation.id] = conversation } }
    public func load(_ id: UUID) -> Conversation? { items.withLock { $0[id] } }
    public func update(_ conversation: Conversation) throws {
        try items.withLock {
            guard $0[conversation.id] != nil else { throw ConversationStoreError.notFound }
            $0[conversation.id] = conversation
        }
    }
    public func delete(_ id: UUID) throws { _ = items.withLock { $0.removeValue(forKey: id) } }
    public func list() -> [ConversationSummary] {
        items.withLock { Array($0.values) }.map(\.indexEntry).sorted { $0.updatedAt > $1.updatedAt }
    }
}
