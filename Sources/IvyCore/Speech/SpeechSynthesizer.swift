import Foundation
import os

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

        public init(text: String) {
            self.text = text
        }
    }

    private struct State {
        var recordedCalls: [SynthesizeCall] = []
        var dataToReturn: Data = Data([0xFF, 0xFB, 0x90, 0x64]) // Minimal fake MP3 frame
        var errorToThrow: (any Error)? = nil
        var delayDuration: TimeInterval = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public var recordedCalls: [SynthesizeCall] {
        get { state.withLock { $0.recordedCalls } }
        set { state.withLock { $0.recordedCalls = newValue } }
    }

    public var dataToReturn: Data {
        get { state.withLock { $0.dataToReturn } }
        set { state.withLock { $0.dataToReturn = newValue } }
    }

    public var errorToThrow: (any Error)? {
        get { state.withLock { $0.errorToThrow } }
        set { state.withLock { $0.errorToThrow = newValue } }
    }

    public var delayDuration: TimeInterval {
        get { state.withLock { $0.delayDuration } }
        set { state.withLock { $0.delayDuration = newValue } }
    }

    public init(
        dataToReturn: Data = Data([0xFF, 0xFB, 0x90, 0x64]),
        errorToThrow: (any Error)? = nil,
        delayDuration: TimeInterval = 0
    ) {
        state.withLock { s in
            s.dataToReturn = dataToReturn
            s.errorToThrow = errorToThrow
            s.delayDuration = delayDuration
        }
    }

    public func synthesize(text: String) async throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SpeechError.emptyText
        }

        let (duration, error, data) = state.withLock { s -> (TimeInterval, (any Error)?, Data) in
            s.recordedCalls.append(SynthesizeCall(text: text))
            return (s.delayDuration, s.errorToThrow, s.dataToReturn)
        }

        if duration > 0 {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        }

        if Task.isCancelled {
            throw SpeechError.cancelled
        }

        if let error {
            throw error
        }

        return data
    }
}
