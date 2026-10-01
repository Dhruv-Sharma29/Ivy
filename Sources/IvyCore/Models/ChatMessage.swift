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
    public let thoughtSignature: String?
    /// Images/PDFs shown with this message. Memory only: never encoded, never persisted (history keeps
    /// `ImageAttachment.placeholder`), and only the newest user message sends them (see `IvyBrain.requestContext`).
    public let attachments: [ImageAttachment]

    public init(
        id: UUID = UUID(),
        role: MessageRole,
        text: String = "",
        timestamp: Date = Date(),
        isError: Bool = false,
        functionCall: FunctionCall? = nil,
        functionResponse: FunctionResponse? = nil,
        functionCallPart: Part? = nil,
        thoughtSignature: String? = nil,
        attachments: [ImageAttachment] = []
    ) {
        self.id = id
        self.attachments = attachments
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.isError = isError
        let resolvedSig = thoughtSignature ?? functionCallPart?.thoughtSignature ?? functionCall?.thoughtSignature
        var resolvedCall = functionCallPart?.functionCall ?? functionCall
        if resolvedCall?.thoughtSignature == nil, let sig = resolvedSig {
            resolvedCall = resolvedCall.map {
                FunctionCall(name: $0.name, args: $0.args, id: $0.id, thoughtSignature: sig)
            }
        }
        self.functionCall = resolvedCall
        self.functionResponse = functionResponse
        self.thoughtSignature = resolvedSig
        self.functionCallPart = functionCallPart ?? resolvedCall.map {
            Part(functionCall: $0, thoughtSignature: resolvedSig)
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, role, text, timestamp, isError, functionCall, functionResponse, functionCallPart, thoughtSignature
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.attachments = []
        self.id = try container.decode(UUID.self, forKey: .id)
        self.role = try container.decode(MessageRole.self, forKey: .role)
        self.text = try container.decode(String.self, forKey: .text)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.isError = try container.decode(Bool.self, forKey: .isError)
        let part = try container.decodeIfPresent(Part.self, forKey: .functionCallPart)
        let call = try container.decodeIfPresent(FunctionCall.self, forKey: .functionCall)
        self.functionResponse = try container.decodeIfPresent(FunctionResponse.self, forKey: .functionResponse)
        let sig = try container.decodeIfPresent(String.self, forKey: .thoughtSignature)
            ?? part?.thoughtSignature
            ?? call?.thoughtSignature

        var resolvedCall = part?.functionCall ?? call
        if resolvedCall?.thoughtSignature == nil, let sig {
            resolvedCall = resolvedCall.map {
                FunctionCall(name: $0.name, args: $0.args, id: $0.id, thoughtSignature: sig)
            }
        }
        self.functionCall = resolvedCall
        self.thoughtSignature = sig
        self.functionCallPart = part ?? resolvedCall.map {
            Part(functionCall: $0, thoughtSignature: sig)
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
        try container.encodeIfPresent(thoughtSignature, forKey: .thoughtSignature)
    }
}

extension ChatMessage {
    /// The same message with its attachments replaced by their placeholders (for older turns in a request).
    public var withAttachmentPlaceholders: ChatMessage {
        guard !attachments.isEmpty else { return self }
        let lines = [text] + attachments.map(\.placeholder)
        return ChatMessage(id: id, role: role, text: lines.filter { !$0.isEmpty }.joined(separator: "\n"), timestamp: timestamp, isError: isError)
    }
}
