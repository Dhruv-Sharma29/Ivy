import Foundation

import os

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

/// Thread-safe key provider that checks a configured in-memory key first,
/// and falls back to the `ELEVENLABS_API_KEY` environment variable.
public final class ConfigurableElevenLabsKeyProvider: ElevenLabsKeyProvider, Sendable {
    private let state: OSAllocatedUnfairLock<String?>

    public init(initialKey: String? = nil) {
        let trimmed = initialKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.state = OSAllocatedUnfairLock(initialState: (trimmed?.isEmpty ?? true) ? nil : trimmed)
    }

    public func setAPIKey(_ key: String?) {
        let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        state.withLock { value in
            value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    public func getAPIKey() -> String? {
        let explicit = state.withLock { $0 }
        if let explicit, !explicit.isEmpty {
            return explicit
        }
        guard let envKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] else {
            return nil
        }
        let trimmed = envKey.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Default voice identifier. Defaulting to Sarah ("EXAVITQu4vr4xnSDxMaL"), a premade voice available on all tiers (Free and Paid).
    public static let defaultVoiceID = "EXAVITQu4vr4xnSDxMaL"

    /// Default low-latency, high-quality ElevenLabs model.
    public static let defaultModelID = "eleven_turbo_v2_5"

    /// Default audio encoding format.
    public static let defaultOutputFormat = "mp3_44100_128"

    public static var configuredVoiceID: String {
        if let envVoice = ProcessInfo.processInfo.environment["ELEVENLABS_VOICE_ID"] {
            let trimmed = envVoice.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return defaultVoiceID
    }

    public let baseURL: String
    public let voiceID: String
    public let modelID: String
    public let outputFormat: String

    public init(
        baseURL: String = defaultBaseURL,
        voiceID: String = configuredVoiceID,
        modelID: String = defaultModelID,
        outputFormat: String = defaultOutputFormat
    ) {
        self.baseURL = baseURL
        self.voiceID = voiceID
        self.modelID = modelID
        self.outputFormat = outputFormat
    }
}
