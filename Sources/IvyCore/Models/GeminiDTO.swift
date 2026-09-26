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

    public init(name: String, args: [String: AnyCodable] = [:], id: String? = nil) {
        self.name = name
        self.args = args
        self.id = id
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

public struct Part: Codable, Sendable, Equatable {
    public let text: String?
    public let thought: Bool?
    public let functionCall: FunctionCall?
    public let functionResponse: FunctionResponse?

    public init(
        text: String? = nil,
        thought: Bool? = nil,
        functionCall: FunctionCall? = nil,
        functionResponse: FunctionResponse? = nil
    ) {
        self.text = text
        self.thought = thought
        self.functionCall = functionCall
        self.functionResponse = functionResponse
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

    /// Returns the first function call in candidate parts, if present.
    public var firstFunctionCall: FunctionCall? {
        guard let candidates else { return nil }
        for candidate in candidates {
            guard let parts = candidate.content?.parts else { continue }
            for part in parts {
                if let call = part.functionCall {
                    return call
                }
            }
        }
        return nil
    }

    /// Returns all function calls across candidate parts.
    public var functionCalls: [FunctionCall] {
        guard let candidates else { return [] }
        var calls: [FunctionCall] = []
        for candidate in candidates {
            guard let parts = candidate.content?.parts else { continue }
            for part in parts {
                if let call = part.functionCall {
                    calls.append(call)
                }
            }
        }
        return calls
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

    public init(code: Int, message: String, status: String) {
        self.code = code
        self.message = message
        self.status = status
    }
}
