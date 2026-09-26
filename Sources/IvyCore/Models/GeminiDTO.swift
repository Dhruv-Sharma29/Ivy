import Foundation

public struct GeminiRequest: Codable, Sendable, Equatable {
    public let systemInstruction: SystemInstruction?
    public let contents: [Content]

    public init(systemInstruction: SystemInstruction? = nil, contents: [Content]) {
        self.systemInstruction = systemInstruction
        self.contents = contents
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

    public init(text: String?) {
        self.text = text
    }
}

public struct GeminiResponse: Codable, Sendable, Equatable {
    public let candidates: [Candidate]?
    public let error: GeminiAPIError?

    public init(candidates: [Candidate]? = nil, error: GeminiAPIError? = nil) {
        self.candidates = candidates
        self.error = error
    }

    public var firstText: String? {
        candidates?.first?.content?.parts.compactMap(\.text).joined()
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
