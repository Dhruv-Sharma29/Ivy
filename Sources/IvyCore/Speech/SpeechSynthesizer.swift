import Foundation

/// Abstraction for text-to-speech synthesis.
/// Decouples voice synthesis from the UI and audio playback layers, enabling isolated unit testing.
public protocol SpeechSynthesizer: Sendable {
    /// Synthesizes the input text into audio binary data (e.g. MP3).
    /// - Parameter text: The natural language string to synthesize.
    /// - Returns: The encoded audio data.
    /// - Throws: `SpeechError` if synthesis fails, configuration is invalid, or the request is cancelled.
    func synthesize(text: String) async throws -> Data
}

/// In-memory mock implementation of `SpeechSynthesizer` for offline automated tests.
public final class MockSpeechSynthesizer: SpeechSynthesizer, @unchecked Sendable {
    public struct SynthesizeCall: Equatable, Sendable {
        public let text: String
    }

    public var recordedCalls: [SynthesizeCall] = []
    public var dataToReturn: Data = Data([0xFF, 0xFB, 0x90, 0x64]) // Minimal fake MP3 frame
    public var errorToThrow: (any Error)? = nil
    public var delayDuration: TimeInterval = 0

    public init(
        dataToReturn: Data = Data([0xFF, 0xFB, 0x90, 0x64]),
        errorToThrow: (any Error)? = nil,
        delayDuration: TimeInterval = 0
    ) {
        self.dataToReturn = dataToReturn
        self.errorToThrow = errorToThrow
        self.delayDuration = delayDuration
    }

    public func synthesize(text: String) async throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpeechError.emptyText
        }

        recordedCalls.append(SynthesizeCall(text: text))

        if delayDuration > 0 {
            try await Task.sleep(nanoseconds: UInt64(delayDuration * 1_000_000_000))
        }

        if Task.isCancelled {
            throw SpeechError.cancelled
        }

        if let errorToThrow {
            throw errorToThrow
        }

        return dataToReturn
    }
}
