import Foundation
import os

/// Protocol representing an active bidirectional Gemini Multimodal Live session.
public protocol GeminiLiveSession: Sendable {
    /// Connects to the Gemini Live endpoint and performs the initial setup handshake.
    func connect() async throws

    /// Streams raw PCM audio data (16kHz 16-bit mono) to Gemini Live.
    func sendAudio(_ data: Data) async throws

    /// Sends tool execution results back to Gemini Live.
    func sendToolResponses(_ responses: [FunctionResponse]) async throws

    /// Yields streaming events from the Gemini Live session.
    func receiveEvents() -> AsyncThrowingStream<LiveEvent, Error>

    /// Cleanly disconnects the session and releases network resources.
    func disconnect() async
}

extension GeminiLiveSession {
    /// Convenience helper for sending a single tool response.
    public func sendToolResponse(_ response: FunctionResponse) async throws {
        try await sendToolResponses([response])
    }
}

/// A mock implementation of `GeminiLiveSession` for unit testing without live network connections.
public final class MockGeminiLiveSession: GeminiLiveSession, @unchecked Sendable {
    private struct State {
        var isConnected: Bool = false
        var sentAudioChunks: [Data] = []
        var sentToolResponses: [FunctionResponse] = []
        var connectError: Error? = nil
        var sendAudioError: Error? = nil
        var sendToolResponsesError: Error? = nil
        var suppressSetupAck: Bool = false
        var continuation: AsyncThrowingStream<LiveEvent, Error>.Continuation? = nil
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(connectError: Error? = nil, sendAudioError: Error? = nil, sendToolResponsesError: Error? = nil) {
        state.withLock {
            $0.connectError = connectError
            $0.sendAudioError = sendAudioError
            $0.sendToolResponsesError = sendToolResponsesError
        }
    }

    public var isConnected: Bool {
        state.withLock { $0.isConnected }
    }

    public var sentAudioChunks: [Data] {
        state.withLock { $0.sentAudioChunks }
    }

    public var sentToolResponses: [FunctionResponse] {
        state.withLock { $0.sentToolResponses }
    }

    public func setConnectError(_ error: Error?) {
        state.withLock { $0.connectError = error }
    }

    public func setSendAudioError(_ error: Error?) {
        state.withLock { $0.sendAudioError = error }
    }

    /// Simulates a server that accepts the socket but never sends `setupComplete`.
    public func setSuppressSetupAck(_ suppress: Bool) {
        state.withLock { $0.suppressSetupAck = suppress }
    }

    public func connect() async throws {
        let (error, continuation) = state.withLock { s -> (Error?, AsyncThrowingStream<LiveEvent, Error>.Continuation?) in
            if let error = s.connectError {
                return (error, nil)
            }
            s.isConnected = true
            return (nil, s.suppressSetupAck ? nil : s.continuation)
        }

        if let error {
            throw error
        }
        continuation?.yield(.connected)
    }

    public func sendAudio(_ data: Data) async throws {
        let errorToThrow = state.withLock { s -> Error? in
            guard s.isConnected else {
                return LiveError.sessionClosed
            }
            if let error = s.sendAudioError {
                return error
            }
            s.sentAudioChunks.append(data)
            return nil
        }

        if let errorToThrow {
            throw errorToThrow
        }
    }

    public func receiveEvents() -> AsyncThrowingStream<LiveEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<LiveEvent, Error>.makeStream()

        state.withLock { s in
            s.continuation = continuation
            if s.isConnected && !s.suppressSetupAck {
                continuation.yield(.connected)
            }
        }

        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { s in
                s.continuation = nil
            }
        }

        return stream
    }

    public func simulateEvent(_ event: LiveEvent) {
        let continuation = state.withLock { $0.continuation }
        continuation?.yield(event)
    }

    public func simulateError(_ error: Error) {
        let continuation = state.withLock { $0.continuation }
        continuation?.finish(throwing: error)
    }

    public func setSendToolResponsesError(_ error: Error?) {
        state.withLock { $0.sendToolResponsesError = error }
    }

    public func sendToolResponses(_ responses: [FunctionResponse]) async throws {
        let errorToThrow = state.withLock { s -> Error? in
            guard s.isConnected else {
                return LiveError.sessionClosed
            }
            if let error = s.sendToolResponsesError {
                return error
            }
            s.sentToolResponses.append(contentsOf: responses)
            return nil
        }

        if let errorToThrow {
            throw errorToThrow
        }
    }

    public func simulateToolCall(_ call: FunctionCall) {
        simulateEvent(.toolCall(call))
    }

    public func disconnect() async {
        let continuation = state.withLock { s -> AsyncThrowingStream<LiveEvent, Error>.Continuation? in
            s.isConnected = false
            let cont = s.continuation
            s.continuation = nil
            return cont
        }

        continuation?.yield(.disconnected)
        continuation?.finish()
    }
}
