import Foundation

public enum ModelRequestPurpose: String, Sendable, Codable {
    case chat, taskPlan, briefing, conversationTitle, summary
}

/// Provider-neutral inputs. Adapters resolve credentials privately, never from conversation text.
public struct ModelRequest: Sendable {
    public let history: [ChatMessage]
    public let systemPrompt: String
    public let tools: [ToolDeclarationWrapper]?
    public let purpose: ModelRequestPurpose

    public init(history: [ChatMessage], systemPrompt: String,
                tools: [ToolDeclarationWrapper]? = nil, purpose: ModelRequestPurpose = .chat) {
        self.history = history
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.purpose = purpose
    }
}

public struct ModelProviderDescriptor: Sendable, Equatable, Codable {
    public let providerID: String
    /// Nil means the adapter cannot identify the actual model; reports must say unavailable.
    public let modelID: String?
    public let supportsTools: Bool
    public let supportsImages: Bool
    public let requiresGeminiCredential: Bool

    public init(providerID: String, modelID: String? = nil, supportsTools: Bool = false,
                supportsImages: Bool = false, requiresGeminiCredential: Bool = false) {
        self.providerID = providerID
        self.modelID = modelID
        self.supportsTools = supportsTools
        self.supportsImages = supportsImages
        self.requiresGeminiCredential = requiresGeminiCredential
    }
}

public enum ModelProviderError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedImages, unsupportedTools, unexpectedToolCalls, emptyResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedImages: "This model cannot read image attachments. Choose an image-capable model or send text."
        case .unsupportedTools: "This model does not support tool calls."
        case .unexpectedToolCalls: "The model returned tool calls where only a text reply was allowed. No action was run."
        case .emptyResponse: "The model returned no answer. Please try again."
        }
    }
}

public protocol ModelProvider: Sendable {
    var descriptor: ModelProviderDescriptor { get }
    func generate(_ request: ModelRequest) async throws -> ModelTurnResponse
}

public extension ModelProvider {
    /// All production callers use this boundary, including late responses from cancelled transports.
    func response(to request: ModelRequest) async throws -> ModelTurnResponse {
        try Task.checkCancellation()
        if !descriptor.supportsImages, request.history.contains(where: { $0.attachments.contains { !$0.jpeg.isEmpty } }) {
            throw ModelProviderError.unsupportedImages
        }
        if !descriptor.supportsTools, !(request.tools ?? []).isEmpty {
            throw ModelProviderError.unsupportedTools
        }
        let result = try await generate(request)
        try Task.checkCancellation()
        if !result.functionCalls.isEmpty, (request.tools ?? []).isEmpty || !descriptor.supportsTools {
            throw ModelProviderError.unexpectedToolCalls
        }
        return result
    }

    func text(for request: ModelRequest) async throws -> String {
        let result = try await response(to: request)
        guard result.functionCalls.isEmpty else { throw ModelProviderError.unexpectedToolCalls }
        guard let text = result.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ModelProviderError.emptyResponse
        }
        return text
    }
}

/// Keeps Gemini's wire format, retry policy and signed tool parts inside its existing transport.
public struct GeminiModelProvider: ModelProvider {
    public let descriptor: ModelProviderDescriptor
    private let client: GeminiClientProtocol
    private let credentials: CredentialProvider

    public init(client: GeminiClientProtocol, credentials: CredentialProvider, modelID: String? = nil) {
        self.client = client
        self.credentials = credentials
        let endpoint = (client as? URLSessionGeminiClient).flatMap { URLComponents(string: $0.baseURLString)?.path }
        let endpointModel = endpoint?.components(separatedBy: "/models/").dropFirst().first?
            .components(separatedBy: ":").first
        descriptor = ModelProviderDescriptor(providerID: "gemini", modelID: modelID ?? endpointModel,
                                             supportsTools: true, supportsImages: true,
                                             requiresGeminiCredential: true)
    }

    public func generate(_ request: ModelRequest) async throws -> ModelTurnResponse {
        guard let key = credentials.credential(for: .geminiAPIKey) else { throw GeminiClientError.missingAPIKey }
        if request.tools == nil {
            let text = try await client.generateContent(history: request.history, systemPrompt: request.systemPrompt, apiKey: key)
            return ModelTurnResponse(text: text)
        }
        return try await client.generateContent(history: request.history, systemPrompt: request.systemPrompt,
                                                tools: request.tools, apiKey: key)
    }
}
