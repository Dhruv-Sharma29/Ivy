import Foundation

public enum MessageRole: String, Codable, Sendable {
    case user
    case model
    case system
    case function
}

public struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let role: MessageRole
    public let text: String
    public let timestamp: Date
    public let isError: Bool
    public let functionCall: FunctionCall?
    public let functionResponse: FunctionResponse?

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String = "",
        timestamp: Date = Date(),
        isError: Bool = false,
        functionCall: FunctionCall? = nil,
        functionResponse: FunctionResponse? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isError = isError
        self.functionCall = functionCall
        self.functionResponse = functionResponse
    }
}
