import Foundation
import os

/// Abstraction over a WebSocket transport connection to enable testability without real network dependencies.
public protocol WebSocketTransport: Sendable {
    func resume()
    func send(_ message: URLSessionWebSocketTask.Message) async throws
    func receive() async throws -> URLSessionWebSocketTask.Message
    func cancel(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

// Conform URLSessionWebSocketTask to WebSocketTransport
extension URLSessionWebSocketTask: WebSocketTransport {
    public func cancel(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        self.cancel(with: closeCode, reason: reason)
    }
}

/// A thread-safe mock implementation of `WebSocketTransport` for unit tests.
public final class MockWebSocketTransport: WebSocketTransport, @unchecked Sendable {
    private struct State {
        var isResumed: Bool = false
        var sentMessages: [URLSessionWebSocketTask.Message] = []
        var receiveQueue: [Result<URLSessionWebSocketTask.Message, Error>] = []
        var receiveContinuation: CheckedContinuation<URLSessionWebSocketTask.Message, Error>? = nil
        var isCancelled: Bool = false
        var closeCode: URLSessionWebSocketTask.CloseCode? = nil
        var sendError: Error? = nil
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var isResumed: Bool {
        state.withLock { $0.isResumed }
    }

    public var sentMessages: [URLSessionWebSocketTask.Message] {
        state.withLock { $0.sentMessages }
    }

    public var isCancelled: Bool {
        state.withLock { $0.isCancelled }
    }

    public var closeCode: URLSessionWebSocketTask.CloseCode? {
        state.withLock { $0.closeCode }
    }

    public func setSendError(_ error: Error?) {
        state.withLock { $0.sendError = error }
    }

    public func resume() {
        state.withLock { $0.isResumed = true }
    }

    public func send(_ message: URLSessionWebSocketTask.Message) async throws {
        let errorToThrow = state.withLock { s -> Error? in
            guard !s.isCancelled else {
                return LiveError.sessionClosed
            }
            if let error = s.sendError {
                return error
            }
            s.sentMessages.append(message)
            return nil
        }
        if let error = errorToThrow {
            throw error
        }
    }

    public func receive() async throws -> URLSessionWebSocketTask.Message {
        // Fast path: if there is already a queued message or error, return immediately
        let queuedResult: Result<URLSessionWebSocketTask.Message, Error>? = state.withLock { s in
            if !s.receiveQueue.isEmpty {
                return s.receiveQueue.removeFirst()
            } else if s.isCancelled {
                return .failure(LiveError.sessionClosed)
            }
            return nil
        }

        if let queuedResult {
            return try queuedResult.get()
        }

        // Slow path: wait for next message
        return try await withCheckedThrowingContinuation { continuation in
            let racedResult: Result<URLSessionWebSocketTask.Message, Error>? = state.withLock { s in
                if !s.receiveQueue.isEmpty {
                    return s.receiveQueue.removeFirst()
                } else if s.isCancelled {
                    return .failure(LiveError.sessionClosed)
                } else {
                    s.receiveContinuation = continuation
                    return nil
                }
            }
            if let racedResult {
                continuation.resume(with: racedResult)
            }
        }
    }

    public func enqueueReceiveMessage(_ message: URLSessionWebSocketTask.Message) {
        let continuation = state.withLock { s -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
            if let cont = s.receiveContinuation {
                s.receiveContinuation = nil
                return cont
            } else {
                s.receiveQueue.append(.success(message))
                return nil
            }
        }
        continuation?.resume(returning: message)
    }

    public func enqueueReceiveString(_ string: String) {
        enqueueReceiveMessage(.string(string))
    }

    public func enqueueReceiveError(_ error: Error) {
        let continuation = state.withLock { s -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
            if let cont = s.receiveContinuation {
                s.receiveContinuation = nil
                return cont
            } else {
                s.receiveQueue.append(.failure(error))
                return nil
            }
        }
        continuation?.resume(throwing: error)
    }

    public func cancel(closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let continuation = state.withLock { s -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
            s.isCancelled = true
            s.closeCode = closeCode
            let cont = s.receiveContinuation
            s.receiveContinuation = nil
            return cont
        }
        continuation?.resume(throwing: LiveError.sessionClosed)
    }
}
