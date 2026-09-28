import Foundation

// MARK: - Client-to-Server Messages

/// Top-level client message sent over the Gemini Live WebSocket.
public struct BidiClientMessage: Codable, Sendable, Equatable {
    public let setup: BidiSetup?
    public let realtimeInput: BidiRealtimeInput?
    public let clientContent: BidiClientContent?
    public let toolResponse: BidiToolResponse?

    public init(
        setup: BidiSetup? = nil,
        realtimeInput: BidiRealtimeInput? = nil,
        clientContent: BidiClientContent? = nil,
        toolResponse: BidiToolResponse? = nil
    ) {
        self.setup = setup
        self.realtimeInput = realtimeInput
        self.clientContent = clientContent
        self.toolResponse = toolResponse
    }
}

public struct BidiSetup: Codable, Sendable, Equatable {
    public let model: String
    public let generationConfig: BidiGenerationConfig
    public let systemInstruction: BidiSystemInstruction?
    public let tools: [ToolDeclarationWrapper]?

    public init(
        model: String = "models/gemini-3.1-flash-live-preview",
        generationConfig: BidiGenerationConfig? = nil,
        systemInstruction: BidiSystemInstruction? = nil,
        tools: [ToolDeclarationWrapper]? = nil
    ) {
        self.model = model
        self.generationConfig = generationConfig ?? BidiGenerationConfig()
        self.systemInstruction = systemInstruction
        self.tools = tools
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case generationConfig
        case systemInstruction
        case tools
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decode(String.self, forKey: .model)
        self.generationConfig = (try? container.decode(BidiGenerationConfig.self, forKey: .generationConfig)) ?? BidiGenerationConfig()
        self.systemInstruction = try? container.decode(BidiSystemInstruction.self, forKey: .systemInstruction)
        self.tools = try? container.decode([ToolDeclarationWrapper].self, forKey: .tools)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(generationConfig, forKey: .generationConfig)
        try container.encodeIfPresent(systemInstruction, forKey: .systemInstruction)
        try container.encodeIfPresent(tools, forKey: .tools)
    }
}

public struct BidiGenerationConfig: Codable, Sendable, Equatable {
    public let responseModalities: [String]
    public let speechConfig: BidiSpeechConfig

    public init(
        responseModalities: [String]? = nil,
        speechConfig: BidiSpeechConfig? = nil
    ) {
        self.responseModalities = responseModalities ?? ["AUDIO"]
        self.speechConfig = speechConfig ?? BidiSpeechConfig()
    }

    private enum CodingKeys: String, CodingKey {
        case responseModalities
        case speechConfig
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.responseModalities = (try? container.decode([String].self, forKey: .responseModalities)) ?? ["AUDIO"]
        self.speechConfig = (try? container.decode(BidiSpeechConfig.self, forKey: .speechConfig)) ?? BidiSpeechConfig()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(responseModalities, forKey: .responseModalities)
        try container.encode(speechConfig, forKey: .speechConfig)
    }
}

public struct BidiSpeechConfig: Codable, Sendable, Equatable {
    public let voiceConfig: BidiVoiceConfig

    public init(voiceConfig: BidiVoiceConfig? = nil) {
        self.voiceConfig = voiceConfig ?? BidiVoiceConfig()
    }

    private enum CodingKeys: String, CodingKey {
        case voiceConfig
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.voiceConfig = (try? container.decode(BidiVoiceConfig.self, forKey: .voiceConfig)) ?? BidiVoiceConfig()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(voiceConfig, forKey: .voiceConfig)
    }
}

public struct BidiVoiceConfig: Codable, Sendable, Equatable {
    public let prebuiltVoiceConfig: BidiPrebuiltVoiceConfig

    public init(prebuiltVoiceConfig: BidiPrebuiltVoiceConfig? = nil) {
        self.prebuiltVoiceConfig = prebuiltVoiceConfig ?? BidiPrebuiltVoiceConfig()
    }

    private enum CodingKeys: String, CodingKey {
        case prebuiltVoiceConfig
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.prebuiltVoiceConfig = (try? container.decode(BidiPrebuiltVoiceConfig.self, forKey: .prebuiltVoiceConfig)) ?? BidiPrebuiltVoiceConfig()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(prebuiltVoiceConfig, forKey: .prebuiltVoiceConfig)
    }
}

public struct BidiPrebuiltVoiceConfig: Codable, Sendable, Equatable {
    public static let liveVoiceName: String = "Kore"
    public let voiceName: String

    public init(voiceName: String = liveVoiceName) {
        // Enforce Kore - no other Gemini voice or fallback is permitted
        self.voiceName = Self.liveVoiceName
    }

    private enum CodingKeys: String, CodingKey {
        case voiceName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try? container.decode(String.self, forKey: .voiceName)
        // Hard-lock to Kore - no other Gemini voice or server override is permitted
        self.voiceName = Self.liveVoiceName
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.liveVoiceName, forKey: .voiceName)
    }
}

public struct BidiSystemInstruction: Codable, Sendable, Equatable {
    public let parts: [BidiTextPart]

    public init(parts: [BidiTextPart]) {
        self.parts = parts
    }

    public init(text: String) {
        self.parts = [BidiTextPart(text: text)]
    }
}

public struct BidiTextPart: Codable, Sendable, Equatable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public struct BidiRealtimeInput: Codable, Sendable, Equatable {
    public let audio: BidiBlob?
    public let mediaChunks: [BidiBlob]?

    public init(audio: BidiBlob) {
        self.audio = audio
        self.mediaChunks = nil
    }

    public init(mediaChunks: [BidiBlob]) {
        self.audio = nil
        self.mediaChunks = mediaChunks
    }

    public init(pcmData: Data, sampleRate: Int = 16000) {
        let base64 = pcmData.base64EncodedString()
        self.audio = BidiBlob(mimeType: "audio/pcm;rate=\(sampleRate)", data: base64)
        self.mediaChunks = nil
    }
}

public struct BidiBlob: Codable, Sendable, Equatable {
    public let mimeType: String
    public let data: String

    public init(mimeType: String, data: String) {
        self.mimeType = mimeType
        self.data = data
    }
}

public struct BidiClientContent: Codable, Sendable, Equatable {
    public let turns: [BidiTurn]?
    public let turnComplete: Bool?

    public init(turns: [BidiTurn]? = nil, turnComplete: Bool? = nil) {
        self.turns = turns
        self.turnComplete = turnComplete
    }
}

public struct BidiTurn: Codable, Sendable, Equatable {
    public let role: String
    public let parts: [BidiPart]

    public init(role: String, parts: [BidiPart]) {
        self.role = role
        self.parts = parts
    }
}

public struct BidiToolResponse: Codable, Sendable, Equatable {
    public let functionResponses: [BidiFunctionResponse]

    public init(functionResponses: [BidiFunctionResponse]) {
        self.functionResponses = functionResponses
    }

    public init(functionResponse: FunctionResponse) {
        self.functionResponses = [BidiFunctionResponse(from: functionResponse)]
    }
}

public struct BidiFunctionResponse: Codable, Sendable, Equatable {
    public let id: String?
    public let name: String?
    public let response: [String: AnyCodable]

    public init(id: String? = nil, name: String? = nil, response: [String: AnyCodable]) {
        self.id = id
        self.name = name
        self.response = response
    }

    public init(from functionResponse: FunctionResponse) {
        self.id = functionResponse.id
        self.name = functionResponse.name
        self.response = functionResponse.response
    }
}

// MARK: - Server-to-Client Messages

/// Top-level server message received over the Gemini Live WebSocket.
public struct BidiServerMessage: Codable, Sendable, Equatable {
    public let setupComplete: BidiSetupComplete?
    public let serverContent: BidiServerContent?
    public let toolCall: BidiToolCall?
    public let toolCallCancellation: BidiToolCallCancellation?

    public init(
        setupComplete: BidiSetupComplete? = nil,
        serverContent: BidiServerContent? = nil,
        toolCall: BidiToolCall? = nil,
        toolCallCancellation: BidiToolCallCancellation? = nil
    ) {
        self.setupComplete = setupComplete
        self.serverContent = serverContent
        self.toolCall = toolCall
        self.toolCallCancellation = toolCallCancellation
    }
}

public struct BidiToolCall: Codable, Sendable, Equatable {
    public let functionCalls: [FunctionCall]

    public init(functionCalls: [FunctionCall]) {
        self.functionCalls = functionCalls
    }
}

public struct BidiToolCallCancellation: Codable, Sendable, Equatable {
    public let ids: [String]

    public init(ids: [String] = []) {
        self.ids = ids
    }
}

public struct BidiSetupComplete: Codable, Sendable, Equatable {
    public init() {}
}

public struct BidiServerContent: Codable, Sendable, Equatable {
    public let modelTurn: BidiModelTurn?
    public let turnComplete: Bool?
    public let interrupted: Bool?

    public init(modelTurn: BidiModelTurn? = nil, turnComplete: Bool? = nil, interrupted: Bool? = nil) {
        self.modelTurn = modelTurn
        self.turnComplete = turnComplete
        self.interrupted = interrupted
    }
}

public struct BidiModelTurn: Codable, Sendable, Equatable {
    public let parts: [BidiPart]

    public init(parts: [BidiPart]) {
        self.parts = parts
    }
}

public struct BidiPart: Codable, Sendable, Equatable {
    public let text: String?
    public let inlineData: BidiBlob?
    public let functionCall: FunctionCall?
    public let thoughtSignature: String?

    public init(
        text: String? = nil,
        inlineData: BidiBlob? = nil,
        functionCall: FunctionCall? = nil,
        thoughtSignature: String? = nil
    ) {
        self.text = text
        self.inlineData = inlineData
        let resolvedSig = thoughtSignature ?? functionCall?.thoughtSignature
        if let call = functionCall, call.thoughtSignature == nil, let resolvedSig {
            self.functionCall = FunctionCall(name: call.name, args: call.args, id: call.id, thoughtSignature: resolvedSig)
        } else {
            self.functionCall = functionCall
        }
        self.thoughtSignature = resolvedSig
    }

    enum CodingKeys: String, CodingKey {
        case text
        case inlineData
        case functionCall
        case thoughtSignature
        case thoughtSignatureSnakeCase = "thought_signature"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.inlineData = try container.decodeIfPresent(BidiBlob.self, forKey: .inlineData)
        var call = try container.decodeIfPresent(FunctionCall.self, forKey: .functionCall)
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
        try container.encodeIfPresent(functionCall, forKey: .functionCall)
        try container.encodeIfPresent(thoughtSignature, forKey: .thoughtSignature)
    }
}

// MARK: - Domain Events & Errors

/// High-level events emitted by the Gemini Live session.
public enum LiveEvent: Sendable, Equatable {
    case connected
    case audioChunk(Data)
    case textTurn(String)
    case turnComplete
    case interrupted
    case disconnected
    case toolCall(FunctionCall)
}

/// Errors occurring in the Gemini Live session.
public enum LiveError: Error, LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidURL
    case connectionFailed(String)
    case setupFailed(String)
    case decodingError(String)
    case serverError(String)
    case sessionClosed
    case audioEncodingFailed
    case microphonePermissionDenied
    case microphonePermissionRestricted

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Gemini API key provided for live voice session."
        case .invalidURL:
            return "Invalid Ivy Live WebSocket URL."
        case .connectionFailed(let msg):
            return "Failed to connect to Ivy Live: \(msg)"
        case .setupFailed(let msg):
            return "Ivy Live setup handshake failed: \(msg)"
        case .decodingError(let msg):
            return "Failed to decode Ivy Live message: \(msg)"
        case .serverError(let msg):
            return "Ivy Live server error: \(msg)"
        case .sessionClosed:
            return "Ivy Live session closed."
        case .audioEncodingFailed:
            return "Failed to encode audio for streaming."
        case .microphonePermissionDenied:
            return "Microphone access was denied. Please allow microphone access in macOS System Settings."
        case .microphonePermissionRestricted:
            return "Microphone access is restricted on this Mac."
        }
    }
}
