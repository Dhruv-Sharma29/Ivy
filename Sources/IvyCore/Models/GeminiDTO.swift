import Foundation

public enum ThinkingLevel: String, Codable, Sendable {
    case low
    case medium
    case high
}

public struct ThinkingConfig: Codable, Sendable, Equatable {
    public let thinkingLevel: ThinkingLevel

    public init(thinkingLevel: ThinkingLevel = .medium) {
        self.thinkingLevel = thinkingLevel
    }

    enum CodingKeys: String, CodingKey {
        case thinkingLevel = "thinking_level"
    }
}

public struct GenerationConfig: Codable, Sendable, Equatable {
    public let thinkingConfig: ThinkingConfig?

    public init(thinkingConfig: ThinkingConfig? = nil) {
        self.thinkingConfig = thinkingConfig
    }
}

// MARK: - Function Calling & Tools DTOs

public struct ToolDeclarationWrapper: Codable, Sendable, Equatable {
    public let functionDeclarations: [FunctionDeclaration]

    public init(functionDeclarations: [FunctionDeclaration]) {
        self.functionDeclarations = functionDeclarations
    }
}

public struct FunctionDeclaration: Codable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let parameters: ToolParameters?

    public init(name: String, description: String, parameters: ToolParameters? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

public struct ToolParameters: Codable, Sendable, Equatable {
    public let type: String
    public let properties: [String: ToolProperty]
    public let required: [String]?

    public init(type: String = "OBJECT", properties: [String: ToolProperty], required: [String]? = nil) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

public struct ToolProperty: Codable, Sendable, Equatable {
    public let type: String
    public let description: String

    public init(type: String, description: String) {
        self.type = type
        self.description = description
    }
}

public struct FunctionCall: Codable, Sendable, Equatable {
    public let name: String
    public let args: [String: AnyCodable]
    public let id: String?
    public let thoughtSignature: String?

    public init(
        name: String,
        args: [String: AnyCodable] = [:],
        id: String? = nil,
        thoughtSignature: String? = nil
    ) {
        self.name = name
        self.args = args
        self.id = id
        self.thoughtSignature = thoughtSignature
    }

    enum CodingKeys: String, CodingKey {
        case name
        case args
        case id
        case thoughtSignature
        case thoughtSignatureSnakeCase = "thought_signature"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decode(String.self, forKey: .name)
        self.args = try container.decodeIfPresent([String: AnyCodable].self, forKey: .args) ?? [:]
        self.id = try container.decodeIfPresent(String.self, forKey: .id)
        self.thoughtSignature = try container.decodeIfPresent(String.self, forKey: .thoughtSignature)
            ?? container.decodeIfPresent(String.self, forKey: .thoughtSignatureSnakeCase)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(args, forKey: .args)
        try container.encodeIfPresent(id, forKey: .id)
        // NOTE: thoughtSignature is a Part-level field in the Gemini REST API.
        // It must NEVER be serialized inside the function_call object.
    }
}

public struct FunctionResponse: Codable, Sendable, Equatable {
    public let name: String
    public let response: [String: AnyCodable]
    public let id: String?

    public init(name: String, response: [String: AnyCodable], id: String? = nil) {
        self.name = name
        self.response = response
        self.id = id
    }

    public var isSuccess: Bool {
        response["success"]?.boolValue ?? false
    }

    public var isCancelled: Bool {
        response["cancelled"]?.boolValue ?? false
    }

    public var isSafetyRejection: Bool {
        response["rejected"]?.boolValue ?? false
    }

    public var isValidationError: Bool {
        response["validationError"]?.boolValue ?? false
    }

    public var isToolNotFound: Bool {
        response["toolNotFound"]?.boolValue ?? false
    }

    public var errorMessage: String? {
        response["error"]?.stringValue
    }

    public var resultMessage: String? {
        response["result"]?.stringValue
    }
}

public struct GeminiRequest: Codable, Sendable, Equatable {
    public let systemInstruction: SystemInstruction?
    public let contents: [Content]
    public let generationConfig: GenerationConfig?
    public let tools: [ToolDeclarationWrapper]?

    public init(
        systemInstruction: SystemInstruction? = nil,
        contents: [Content],
        generationConfig: GenerationConfig? = nil,
        tools: [ToolDeclarationWrapper]? = nil
    ) {
        self.systemInstruction = systemInstruction
        self.contents = contents
        self.generationConfig = generationConfig
        self.tools = tools
    }
}

public struct SystemInstruction: Codable, Sendable, Equatable {
    public let parts: [Part]

    public init(parts: [Part]) {
        self.parts = parts
    }

    public init(text: String) {
        self.parts = [Part(text: text)]
    }
}

public struct Content: Codable, Sendable, Equatable {
    public let role: String
    public let parts: [Part]

    public init(role: String, parts: [Part]) {
        self.role = role
        self.parts = parts
    }

    public init(role: String, text: String) {
        self.role = role
        self.parts = [Part(text: text)]
    }
}

/// Bytes sent inline with a request (an image), base64 on the wire.
public struct InlineData: Codable, Sendable, Equatable {
    public let mimeType: String
    public let data: String

    public init(mimeType: String, data: Data) {
        self.mimeType = mimeType
        self.data = data.base64EncodedString()
    }
}

public struct Part: Codable, Sendable, Equatable {
    public let text: String?
    public let inlineData: InlineData?
    public let thought: Bool?
    public let functionCall: FunctionCall?
    public let functionResponse: FunctionResponse?
    public let thoughtSignature: String?

    public init(
        text: String? = nil,
        thought: Bool? = nil,
        functionCall: FunctionCall? = nil,
        functionResponse: FunctionResponse? = nil,
        thoughtSignature: String? = nil,
        inlineData: InlineData? = nil
    ) {
        self.text = text
        self.inlineData = inlineData
        self.thought = thought
        let resolvedSig = thoughtSignature ?? functionCall?.thoughtSignature
        if let call = functionCall, call.thoughtSignature == nil, let resolvedSig {
            self.functionCall = FunctionCall(name: call.name, args: call.args, id: call.id, thoughtSignature: resolvedSig)
        } else {
            self.functionCall = functionCall
        }
        self.functionResponse = functionResponse
        self.thoughtSignature = resolvedSig
    }

    enum CodingKeys: String, CodingKey {
        case text
        case inlineData
        case thought
        case functionCall
        case functionResponse
        case thoughtSignature
        case thoughtSignatureSnakeCase = "thought_signature"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.inlineData = try container.decodeIfPresent(InlineData.self, forKey: .inlineData)
        self.thought = try container.decodeIfPresent(Bool.self, forKey: .thought)
        var call = try container.decodeIfPresent(FunctionCall.self, forKey: .functionCall)
        self.functionResponse = try container.decodeIfPresent(FunctionResponse.self, forKey: .functionResponse)

        let sig = try container.decodeIfPresent(String.self, forKey: .thoughtSignature)
            ?? container.decodeIfPresent(String.self, forKey: .thoughtSignatureSnakeCase)
            ?? call?.thoughtSignature
        self.thoughtSignature = sig

        if let currentCall = call, currentCall.thoughtSignature == nil, let sig {
            call = FunctionCall(name: currentCall.name, args: currentCall.args, id: currentCall.id, thoughtSignature: sig)
        }
        self.functionCall = call
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(text, forKey: .text)
        try container.encodeIfPresent(inlineData, forKey: .inlineData)
        try container.encodeIfPresent(thought, forKey: .thought)
        try container.encodeIfPresent(functionCall, forKey: .functionCall)
        try container.encodeIfPresent(functionResponse, forKey: .functionResponse)
        let sig = thoughtSignature ?? functionCall?.thoughtSignature
        try container.encodeIfPresent(sig, forKey: .thoughtSignature)
    }
}

public struct GeminiResponse: Codable, Sendable, Equatable {
    public let candidates: [Candidate]?
    public let error: GeminiAPIError?

    public init(candidates: [Candidate]? = nil, error: GeminiAPIError? = nil) {
        self.candidates = candidates
        self.error = error
    }

    /// Returns the user-facing text response, filtering out internal reasoning thoughts.
    public var firstText: String? {
        guard let candidates else { return nil }
        for candidate in candidates {
            guard let parts = candidate.content?.parts else { continue }
            let nonThoughtParts = parts.filter { $0.thought != true }
            let candidateText = nonThoughtParts.compactMap(\.text).joined()
            if !candidateText.isEmpty {
                return candidateText
            }
            let fallbackText = parts.compactMap(\.text).joined()
            if !fallbackText.isEmpty {
                return fallbackText
            }
        }
        return nil
    }

    /// Returns all function call parts across candidate parts, preserving thought signatures.
    public var functionCallParts: [Part] {
        guard let candidates else { return [] }
        var result: [Part] = []
        for candidate in candidates {
            guard let parts = candidate.content?.parts else { continue }
            let candidateSig = parts.compactMap(\.thoughtSignature).first
            for part in parts {
                if var call = part.functionCall {
                    let sig = part.thoughtSignature ?? call.thoughtSignature ?? candidateSig
                    if call.thoughtSignature == nil, let sig {
                        call = FunctionCall(name: call.name, args: call.args, id: call.id, thoughtSignature: sig)
                    }
                    let updatedPart = Part(
                        text: part.text,
                        thought: part.thought,
                        functionCall: call,
                        functionResponse: part.functionResponse,
                        thoughtSignature: sig
                    )
                    result.append(updatedPart)
                }
            }
        }
        return result
    }

    /// Returns the first function call in candidate parts, if present.
    public var firstFunctionCall: FunctionCall? {
        return functionCallParts.first?.functionCall
    }

    /// Returns all function calls across candidate parts.
    public var functionCalls: [FunctionCall] {
        return functionCallParts.compactMap(\.functionCall)
    }
}

public struct Candidate: Codable, Sendable, Equatable {
    public let content: Content?
    public let finishReason: String?

    public init(content: Content? = nil, finishReason: String? = nil) {
        self.content = content
        self.finishReason = finishReason
    }
}

public struct GeminiAPIError: Codable, Sendable, Equatable {
    public let code: Int
    public let message: String
    public let status: String
    public let details: [Detail]?

    /// Unknown Google error-detail fields are intentionally ignored.
    public struct Detail: Codable, Sendable, Equatable {
        public let reason: String?
        public init(reason: String? = nil) { self.reason = reason }
    }

    public init(code: Int, message: String, status: String, details: [Detail]? = nil) {
        self.code = code
        self.message = message
        self.status = status
        self.details = details
    }
}
