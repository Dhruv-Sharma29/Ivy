import Foundation

/// Errors that can occur during text-to-speech synthesis and audio playback.
public enum SpeechError: Error, LocalizedError, Equatable, Sendable {
    case emptyText
    case missingAPIKey
    case invalidAPIKey(String)
    case rateLimited
    case voiceNotFound(String)
    case serverError(statusCode: Int, message: String)
    case networkError(String)
    case decodingError(String)
    case emptyAudioData
    case playbackFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            return "Cannot synthesize speech from empty text."
        case .missingAPIKey:
            return "ElevenLabs API key is missing. Set ELEVENLABS_API_KEY to enable voice output."
        case .invalidAPIKey(let msg):
            return "ElevenLabs authentication failed: \(msg)"
        case .rateLimited:
            return "ElevenLabs rate limit exceeded. Please wait a moment."
        case .voiceNotFound(let voice):
            return "ElevenLabs voice not found: '\(voice)'."
        case .serverError(let code, let msg):
            return "ElevenLabs server error (\(code)): \(msg)"
        case .networkError(let msg):
            return "Network connection failed during speech synthesis: \(msg)"
        case .decodingError(let msg):
            return "Failed to parse speech response: \(msg)"
        case .emptyAudioData:
            return "Received empty audio data from speech synthesizer."
        case .playbackFailed(let msg):
            return "Audio playback failed: \(msg)"
        case .cancelled:
            return "Speech synthesis or playback was cancelled."
        }
    }
}
