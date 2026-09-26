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
    public let functionCallPart: Part?

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String = "",
        timestamp: Date = Date(),
        isError: Bool = false,
        functionCall: FunctionCall? = nil,
        functionResponse: FunctionResponse? = nil,
        functionCallPart: Part? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isError = isError
        var resolvedCall = functionCallPart?.functionCall ?? functionCall
        if resolvedCall?.thoughtSignature == nil, let sig = functionCallPart?.thoughtSignature {
            resolvedCall = resolvedCall.map {
                FunctionCall(name: $0.name, args: $0.args, id: $0.id, thoughtSignature: sig)
            }
        }
        self.functionCall = resolvedCall
        self.functionResponse = functionResponse
        self.functionCallPart = functionCallPart ?? resolvedCall.map {
            Part(functionCall: $0, thoughtSignature: $0.thoughtSignature)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, role, text, timestamp, isError, functionCall, functionResponse, functionCallPart
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(MessageRole.self, forKey: .role)
        self.text = try container.decode(String.self, forKey: .text)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.isError = try container.decode(Bool.self, forKey: .isError)
        let part = try container.decodeIfPresent(Part.self, forKey: .functionCallPart)
        let call = try container.decodeIfPresent(FunctionCall.self, forKey: .functionCall)
        self.functionResponse = try container.decodeIfPresent(FunctionResponse.self, forKey: .functionResponse)

        var resolvedCall = part?.functionCall ?? call
        if resolvedCall?.thoughtSignature == nil, let sig = part?.thoughtSignature {
            resolvedCall = resolvedCall.map {
                FunctionCall(name: $0.name, args: $0.args, id: $0.id, thoughtSignature: sig)
            }
        }
        self.functionCall = resolvedCall
        self.functionCallPart = part ?? resolvedCall.map {
            Part(functionCall: $0, thoughtSignature: $0.thoughtSignature)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(isError, forKey: .isError)
        try container.encodeIfPresent(functionCall, forKey: .functionCall)
        try container.encodeIfPresent(functionResponse, forKey: .functionResponse)
        try container.encodeIfPresent(functionCallPart, forKey: .functionCallPart)
    }
}
