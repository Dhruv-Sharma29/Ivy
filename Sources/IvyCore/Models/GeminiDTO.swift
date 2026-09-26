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

public struct GeminiRequest: Codable, Sendable, Equatable {
    public let systemInstruction: SystemInstruction?
    public let contents: [Content]
    public let generationConfig: GenerationConfig?

    public init(
        systemInstruction: SystemInstruction? = nil,
        contents: [Content],
        generationConfig: GenerationConfig? = nil
    ) {
        self.systemInstruction = systemInstruction
        self.contents = contents
        self.generationConfig = generationConfig
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

    public init(text: String?, thought: Bool? = nil) {
        self.text = text
        self.thought = thought
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
