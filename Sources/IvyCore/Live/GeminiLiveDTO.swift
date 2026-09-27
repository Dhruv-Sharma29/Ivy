import Foundation

// MARK: - Client-to-Server Messages

/// Top-level client message sent over the Gemini Live WebSocket.
public struct BidiClientMessage: Codable, Sendable, Equatable {
    public let setup: BidiSetup?
    public let realtimeInput: BidiRealtimeInput?
    public let clientContent: BidiClientContent?

    public init(
        setup: BidiSetup? = nil,
        realtimeInput: BidiRealtimeInput? = nil,
        clientContent: BidiClientContent? = nil
    ) {
        self.setup = setup
        self.realtimeInput = realtimeInput
        self.clientContent = clientContent
    }
}

public struct BidiSetup: Codable, Sendable, Equatable {
    public let model: String
    public let generationConfig: BidiGenerationConfig?
    public let systemInstruction: BidiSystemInstruction?

    public init(
        model: String = "models/gemini-3.1-flash-live-preview",
        generationConfig: BidiGenerationConfig? = BidiGenerationConfig(),
        systemInstruction: BidiSystemInstruction? = nil
    ) {
        self.model = model
        self.generationConfig = generationConfig
        self.systemInstruction = systemInstruction
    }
}

public struct BidiGenerationConfig: Codable, Sendable, Equatable {
    public let responseModalities: [String]?
    public let speechConfig: BidiSpeechConfig?

    public init(
        responseModalities: [String]? = ["AUDIO"],
        speechConfig: BidiSpeechConfig? = BidiSpeechConfig()
    ) {
        self.responseModalities = responseModalities
        self.speechConfig = speechConfig
    }
}

public struct BidiSpeechConfig: Codable, Sendable, Equatable {
    public let voiceConfig: BidiVoiceConfig?

    public init(voiceConfig: BidiVoiceConfig? = BidiVoiceConfig()) {
        self.voiceConfig = voiceConfig
    }
}

public struct BidiVoiceConfig: Codable, Sendable, Equatable {
    public let prebuiltVoiceConfig: BidiPrebuiltVoiceConfig?

    public init(prebuiltVoiceConfig: BidiPrebuiltVoiceConfig? = BidiPrebuiltVoiceConfig()) {
        self.prebuiltVoiceConfig = prebuiltVoiceConfig
    }
}

public struct BidiPrebuiltVoiceConfig: Codable, Sendable, Equatable {
    public let voiceName: String

    public init(voiceName: String = "Kore") {
        self.voiceName = voiceName
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

// MARK: - Server-to-Client Messages

/// Top-level server message received over the Gemini Live WebSocket.
public struct BidiServerMessage: Codable, Sendable, Equatable {
    public let setupComplete: BidiSetupComplete?
    public let serverContent: BidiServerContent?

    public init(setupComplete: BidiSetupComplete? = nil, serverContent: BidiServerContent? = nil) {
        self.setupComplete = setupComplete
        self.serverContent = serverContent
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

    public init(text: String? = nil, inlineData: BidiBlob? = nil) {
        self.text = text
        self.inlineData = inlineData
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
            return "Invalid Gemini Live WebSocket URL."
        case .connectionFailed(let msg):
            return "Failed to connect to Gemini Live: \(msg)"
        case .setupFailed(let msg):
            return "Gemini Live setup handshake failed: \(msg)"
        case .decodingError(let msg):
            return "Failed to decode Gemini Live message: \(msg)"
        case .serverError(let msg):
            return "Gemini Live server error: \(msg)"
        case .sessionClosed:
            return "Gemini Live session closed."
        case .audioEncodingFailed:
            return "Failed to encode audio for streaming."
        case .microphonePermissionDenied:
            return "Microphone access was denied. Please allow microphone access in macOS System Settings."
        case .microphonePermissionRestricted:
            return "Microphone access is restricted on this Mac."
        }
    }
}
