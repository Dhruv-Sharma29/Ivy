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
    /// Present (as `{}`) when the server should send text transcripts of what the user said / what Ivy said.
    public let inputAudioTranscription: BidiTranscriptionConfig?
    public let outputAudioTranscription: BidiTranscriptionConfig?
    /// Turn-taking tuning. Absent = the server's own activity detection defaults.
    public let realtimeInputConfig: BidiRealtimeInputConfig?

    public init(
        model: String = "models/gemini-3.1-flash-live-preview",
        generationConfig: BidiGenerationConfig? = nil,
        systemInstruction: BidiSystemInstruction? = nil,
        tools: [ToolDeclarationWrapper]? = nil,
        transcribesAudio: Bool = false,
        silenceDurationMs: Int? = nil
    ) {
        self.realtimeInputConfig = silenceDurationMs.map {
            BidiRealtimeInputConfig(automaticActivityDetection: BidiActivityDetection(silenceDurationMs: $0))
        }
        self.model = model
        self.generationConfig = generationConfig ?? BidiGenerationConfig()
        self.systemInstruction = systemInstruction
        self.tools = tools
        self.inputAudioTranscription = transcribesAudio ? BidiTranscriptionConfig() : nil
        self.outputAudioTranscription = transcribesAudio ? BidiTranscriptionConfig() : nil
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case generationConfig
        case systemInstruction
        case tools
        case inputAudioTranscription
        case outputAudioTranscription
        case realtimeInputConfig
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.model = try container.decode(String.self, forKey: .model)
        self.generationConfig = (try? container.decode(BidiGenerationConfig.self, forKey: .generationConfig)) ?? BidiGenerationConfig()
        self.systemInstruction = try? container.decode(BidiSystemInstruction.self, forKey: .systemInstruction)
        self.tools = try? container.decode([ToolDeclarationWrapper].self, forKey: .tools)
        self.inputAudioTranscription = try container.decodeIfPresent(BidiTranscriptionConfig.self, forKey: .inputAudioTranscription)
        self.outputAudioTranscription = try container.decodeIfPresent(BidiTranscriptionConfig.self, forKey: .outputAudioTranscription)
        self.realtimeInputConfig = try container.decodeIfPresent(BidiRealtimeInputConfig.self, forKey: .realtimeInputConfig)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(generationConfig, forKey: .generationConfig)
        try container.encodeIfPresent(systemInstruction, forKey: .systemInstruction)
        try container.encodeIfPresent(tools, forKey: .tools)
        try container.encodeIfPresent(inputAudioTranscription, forKey: .inputAudioTranscription)
        try container.encodeIfPresent(outputAudioTranscription, forKey: .outputAudioTranscription)
        try container.encodeIfPresent(realtimeInputConfig, forKey: .realtimeInputConfig)
    }
}

public struct BidiRealtimeInputConfig: Codable, Sendable, Equatable {
    public let automaticActivityDetection: BidiActivityDetection

    public init(automaticActivityDetection: BidiActivityDetection) {
        self.automaticActivityDetection = automaticActivityDetection
    }
}

/// Server-side voice activity detection. Only the fields Ivy tunes are modelled.
public struct BidiActivityDetection: Codable, Sendable, Equatable {
    /// How long the user must be silent before the server treats the turn as finished.
    public let silenceDurationMs: Int?

    public init(silenceDurationMs: Int? = nil) {
        self.silenceDurationMs = silenceDurationMs
    }
}

public struct BidiTranscriptionConfig: Codable, Sendable, Equatable {
    public init() {}
}

/// A fragment of transcript; the server sends these incrementally alongside the audio.
public struct BidiTranscription: Codable, Sendable, Equatable {
    public let text: String?

    public init(text: String? = nil) {
        self.text = text
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

/// Exactly one of `audio` / `mediaChunks` is set: the Live server closes the socket when a frame carries both.
public struct BidiRealtimeInput: Codable, Sendable, Equatable {
    public let mediaChunks: [BidiBlob]?
    public let audio: BidiBlob?

    public init(audio: BidiBlob) {
        self.audio = audio
        self.mediaChunks = nil
    }

    public init(mediaChunks: [BidiBlob]) {
        self.mediaChunks = mediaChunks
        self.audio = nil
    }

    public init(pcmData: Data, sampleRate: Int = 16000) {
        self.init(audio: BidiBlob(mimeType: "audio/pcm;rate=\(sampleRate)", data: pcmData.base64EncodedString()))
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

public struct BidiServerErrorMessage: Codable, Sendable, Equatable {
    public let code: Int?
    public let message: String?
    public let status: String?

    public init(code: Int? = nil, message: String? = nil, status: String? = nil) {
        self.code = code
        self.message = message
        self.status = status
    }
}

/// Top-level server message received over the Gemini Live WebSocket.
public struct BidiServerMessage: Codable, Sendable, Equatable {
    public let setupComplete: BidiSetupComplete?
    public let serverContent: BidiServerContent?
    public let toolCall: BidiToolCall?
    public let toolCallCancellation: BidiToolCallCancellation?
    public let error: BidiServerErrorMessage?

    public init(
        setupComplete: BidiSetupComplete? = nil,
        serverContent: BidiServerContent? = nil,
        toolCall: BidiToolCall? = nil,
        toolCallCancellation: BidiToolCallCancellation? = nil,
        error: BidiServerErrorMessage? = nil
    ) {
        self.setupComplete = setupComplete
        self.serverContent = serverContent
        self.toolCall = toolCall
        self.toolCallCancellation = toolCallCancellation
        self.error = error
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
    public let inputTranscription: BidiTranscription?
    public let outputTranscription: BidiTranscription?

    public init(
        modelTurn: BidiModelTurn? = nil, turnComplete: Bool? = nil, interrupted: Bool? = nil,
        inputTranscription: BidiTranscription? = nil, outputTranscription: BidiTranscription? = nil
    ) {
        self.modelTurn = modelTurn
        self.turnComplete = turnComplete
        self.interrupted = interrupted
        self.inputTranscription = inputTranscription
        self.outputTranscription = outputTranscription
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
    /// The server withdrew these tool calls (by id), e.g. because the user interrupted the turn.
    case toolCallCancelled([String])
    /// A fragment of what the user said (server-side transcription of the mic audio).
    case inputTranscript(String)
    /// A fragment of what Ivy is saying.
    case outputTranscript(String)
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
    case timeout(String)

    /// Whether reconnecting could help. Transport drops are; authentication, quota and policy rejections are not
    /// (retrying those only burns requests).
    public var isRecoverable: Bool {
        let message: String
        switch self {
        case .sessionClosed, .timeout: return true
        case .connectionFailed(let m), .serverError(let m): message = m.lowercased()
        case .missingAPIKey, .invalidURL, .setupFailed, .decodingError, .audioEncodingFailed,
             .microphonePermissionDenied, .microphonePermissionRestricted: return false
        }
        let permanent = ["api key", "quota", "resource_exhausted", "permission", "billing", "unauthenticated",
                         "invalid argument", "close code 1007", "close code 1008"]
        return !permanent.contains { message.contains($0) }
    }

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
        case .timeout(let msg):
            return "Ivy Live timed out: \(msg)"
        }
    }
}
