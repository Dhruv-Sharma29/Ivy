import Foundation

public enum ChatFeedItem: Identifiable, Equatable, Sendable {
    case message(ChatMessage)
    case tool(ToolExecution)

    public var id: String {
        switch self {
        case .message(let value): "message-\(value.id)"
        case .tool(let value): "tool-\(value.id)"
        }
    }

    var date: Date {
        switch self {
        case .message(let value): value.timestamp
        case .tool(let value): value.startedAt
        }
    }
}

/// Orders display cards by their request, not by a voice transcription's delivery time.
public enum ChatFeedTimeline {
    public static func items(messages: [ChatMessage], records: [ToolExecution]) -> [ChatFeedItem] {
        let requests = Set(messages.filter { $0.role == .user }.map(\.id))
        var linked: [UUID: [ChatFeedItem]] = [:]
        var timeline = messages.map(ChatFeedItem.message)
        for record in records {
            if let requestID = record.requestMessageID, requests.contains(requestID) {
                linked[requestID, default: []].append(.tool(record))
            } else {
                // Unsaved/missing transcripts and legacy unlinked cards retain chronological placement.
                timeline.append(.tool(record))
            }
        }
        func chronological(_ items: [ChatFeedItem]) -> [ChatFeedItem] {
            items.enumerated().sorted {
                $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date
            }.map(\.element)
        }
        return chronological(timeline).flatMap { item -> [ChatFeedItem] in
            guard case .message(let message) = item, let cards = linked[message.id] else { return [item] }
            return [item] + chronological(cards)
        }
    }
}
