import Foundation
import os

/// WebSocket-based client implementing bidirectional streaming with Gemini Multimodal Live API.
public final class GeminiLiveClient: GeminiLiveSession, @unchecked Sendable {
    public typealias WebSocketFactory = @Sendable (URLRequest) -> WebSocketTransport

    public let apiKey: String
    public let model: String
    public let systemInstruction: String?
    public let session: URLSession
    private let webSocketFactory: WebSocketFactory

    private struct State {
        var webSocket: WebSocketTransport? = nil
        var isConnected: Bool = false
        var continuation: AsyncThrowingStream<LiveEvent, Error>.Continuation? = nil
        var receiveTask: Task<Void, Never>? = nil
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(
        apiKey: String,
        model: String = "models/gemini-2.0-flash-exp",
        systemInstruction: String? = nil,
        session: URLSession = .shared,
        webSocketFactory: WebSocketFactory? = nil
    ) {
        self.apiKey = apiKey
        self.model = model
        self.systemInstruction = systemInstruction
        self.session = session
        if let webSocketFactory {
            self.webSocketFactory = webSocketFactory
        } else {
            self.webSocketFactory = { [session] request in
                session.webSocketTask(with: request)
            }
        }
    }

    public var isConnected: Bool {
        state.withLock { $0.isConnected }
    }

    public func receiveEvents() -> AsyncThrowingStream<LiveEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<LiveEvent, Error>.makeStream()

        state.withLock { s in
            s.continuation = continuation
            if s.isConnected {
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

    public func connect() async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveError.missingAPIKey
        }

        guard let encodedKey = apiKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(encodedKey)") else {
            throw LiveError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        let ws = webSocketFactory(request)
        state.withLock { s in
            s.webSocket = ws
        }

        ws.resume()

        // Send Setup Message
        let setup = BidiSetup(
            model: model,
            generationConfig: BidiGenerationConfig(responseModalities: ["AUDIO"]),
            systemInstruction: systemInstruction.map { BidiSystemInstruction(text: $0) }
        )
        let setupMessage = BidiClientMessage(setup: setup)

        do {
            let data = try JSONEncoder().encode(setupMessage)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                throw LiveError.setupFailed("Failed to encode setup payload.")
            }
            try await ws.send(.string(jsonString))
        } catch {
            ws.cancel(closeCode: .normalClosure, reason: nil)
            throw LiveError.setupFailed(error.localizedDescription)
        }

        // Start background message receiver
        startReceiveLoop(transport: ws)
    }

    public func sendAudio(_ data: Data) async throws {
        let ws: WebSocketTransport? = state.withLock { s in
            guard s.isConnected, let ws = s.webSocket else {
                return nil
            }
            return ws
        }

        guard let ws else {
            throw LiveError.sessionClosed
        }

        let input = BidiRealtimeInput(pcmData: data, sampleRate: 16000)
        let message = BidiClientMessage(realtimeInput: input)

        do {
            let jsonData = try JSONEncoder().encode(message)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw LiveError.audioEncodingFailed
            }
            try await ws.send(.string(jsonString))
        } catch {
            throw LiveError.serverError("Failed to send audio chunk: \(error.localizedDescription)")
        }
    }

    public func disconnect() async {
        let (ws, task, continuation) = state.withLock { s -> (WebSocketTransport?, Task<Void, Never>?, AsyncThrowingStream<LiveEvent, Error>.Continuation?) in
            s.isConnected = false
            let ws = s.webSocket
            let task = s.receiveTask
            let cont = s.continuation
            s.webSocket = nil
            s.receiveTask = nil
            s.continuation = nil
            return (ws, task, cont)
        }

        task?.cancel()
        ws?.cancel(closeCode: .normalClosure, reason: nil)
        continuation?.yield(.disconnected)
        continuation?.finish()
    }

    // MARK: - Private Receive Loop

    private func startReceiveLoop(transport: WebSocketTransport) {
        let task = Task { [weak self, transport] in
            while !Task.isCancelled {
                do {
                    let message = try await transport.receive()
                    guard let self else { break }
                    self.handleIncomingWebSocketMessage(message)
                } catch {
                    guard let self else { break }
                    self.handleReceiveError(error)
                    break
                }
            }
        }

        state.withLock { s in
            s.receiveTask = task
        }
    }

    private func handleIncomingWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        let payloadData: Data
        switch message {
        case .string(let str):
            guard let data = str.data(using: .utf8) else { return }
            payloadData = data
        case .data(let data):
            payloadData = data
        @unknown default:
            return
        }

        guard let serverMessage = try? JSONDecoder().decode(BidiServerMessage.self, from: payloadData) else {
            return
        }

        if serverMessage.setupComplete != nil {
            let continuation = state.withLock { s -> AsyncThrowingStream<LiveEvent, Error>.Continuation? in
                s.isConnected = true
                return s.continuation
            }
            continuation?.yield(.connected)
        }

        if let content = serverMessage.serverContent {
            let continuation = state.withLock { $0.continuation }

            if content.interrupted == true {
                continuation?.yield(.interrupted)
            }

            if let modelTurn = content.modelTurn {
                for part in modelTurn.parts {
                    if let inlineData = part.inlineData,
                       let audioData = Data(base64Encoded: inlineData.data) {
                        continuation?.yield(.audioChunk(audioData))
                    }
                    if let text = part.text {
                        continuation?.yield(.textTurn(text))
                    }
                }
            }

            if content.turnComplete == true {
                continuation?.yield(.turnComplete)
            }
        }
    }

    private func handleReceiveError(_ error: Error) {
        let continuation = state.withLock { s -> AsyncThrowingStream<LiveEvent, Error>.Continuation? in
            s.isConnected = false
            s.webSocket = nil
            let cont = s.continuation
            s.continuation = nil
            return cont
        }

        continuation?.yield(.disconnected)
        continuation?.finish()
    }
}
