import Foundation

/// Protocol for retrieving the ElevenLabs API key.
/// Decouples credential storage from the synthesis client so it can be backed by
/// environment variables in Phase 4 and macOS Keychain in Phase 5.
public protocol ElevenLabsKeyProvider: Sendable {
    /// Returns the API key if configured, or nil if missing.
    func getAPIKey() -> String?
}

/// Key provider that reads from the `ELEVENLABS_API_KEY` process environment variable.
public struct EnvironmentElevenLabsKeyProvider: ElevenLabsKeyProvider, Sendable {
    public init() {}

    public func getAPIKey() -> String? {
        guard let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] else {
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Key provider that returns a fixed string, useful for tests and explicit injection.
public struct StaticElevenLabsKeyProvider: ElevenLabsKeyProvider, Sendable, Equatable {
    private let key: String

    public init(key: String) {
        self.key = key
    }

    public func getAPIKey() -> String? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Centralized configuration for the ElevenLabs Text-to-Speech API.
public struct ElevenLabsConfiguration: Sendable, Equatable {
    /// Default API endpoint for ElevenLabs text-to-speech.
    public static let defaultBaseURL = "https://api.elevenlabs.io/v1/text-to-speech"

    /// Default voice identifier. Defaulting to Rachel ("21m00Tcm4TlvDq8ikWAM").
    public static let defaultVoiceID = "21m00Tcm4TlvDq8ikWAM"

    /// Default low-latency, high-quality ElevenLabs model.
    public static let defaultModelID = "eleven_turbo_v2_5"

    /// Default audio encoding format.
    public static let defaultOutputFormat = "mp3_44100_128"

    public let baseURL: String
    public let voiceID: String
    public let modelID: String
    public let outputFormat: String

    public init(
        baseURL: String = defaultBaseURL,
        voiceID: String = defaultVoiceID,
        modelID: String = defaultModelID,
        outputFormat: String = defaultOutputFormat
    ) {
        self.baseURL = baseURL
        self.voiceID = voiceID
        self.modelID = modelID
        self.outputFormat = outputFormat
    }
}
