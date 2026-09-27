import Foundation
import os

/// WebSocket-based client implementing bidirectional streaming with Gemini Multimodal Live API.
public final class GeminiLiveClient: GeminiLiveSession, @unchecked Sendable {
    public typealias WebSocketFactory = @Sendable (URLRequest) -> WebSocketTransport

    public var apiKey: String {
        state.withLock { $0.apiKey }
    }
    public let model: String
    public let voiceName: String
    public let systemInstruction: String?
    public let session: URLSession
    private let webSocketFactory: WebSocketFactory

    private struct State {
        var apiKey: String
        var webSocket: WebSocketTransport? = nil
        var isConnected: Bool = false
        var isClosed: Bool = false
        var continuation: AsyncThrowingStream<LiveEvent, Error>.Continuation? = nil
        var receiveTask: Task<Void, Never>? = nil
        var pendingSendContinuations: [CheckedContinuation<WebSocketTransport, Error>] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(
        apiKey: String,
        model: String = "models/gemini-3.1-flash-live-preview",
        voiceName: String = "Kore",
        systemInstruction: String? = nil,
        session: URLSession = .shared,
        webSocketFactory: WebSocketFactory? = nil
    ) {
        self.state = OSAllocatedUnfairLock(initialState: State(apiKey: apiKey))
        self.model = model
        self.voiceName = voiceName
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

    public func updateApiKey(_ newKey: String) {
        state.withLock { s in
            s.apiKey = newKey
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
        let currentKey = state.withLock { $0.apiKey }
        guard !currentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LiveError.missingAPIKey
        }

        guard let encodedKey = currentKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(encodedKey)") else {
            throw LiveError.invalidURL
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        let ws = webSocketFactory(request)
        state.withLock { s in
            s.webSocket = ws
            s.isClosed = false
            s.isConnected = false
        }

        ws.resume()

        // Send Setup Message
        let setup = BidiSetup(
            model: model,
            generationConfig: BidiGenerationConfig(
                responseModalities: ["AUDIO"],
                speechConfig: BidiSpeechConfig(
                    voiceConfig: BidiVoiceConfig(
                        prebuiltVoiceConfig: BidiPrebuiltVoiceConfig(voiceName: voiceName)
                    )
                )
            ),
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
        let ws = try await getConnectedWebSocket()

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

    private func getConnectedWebSocket() async throws -> WebSocketTransport {
        let (ws, isConn, isClosed) = state.withLock { s -> (WebSocketTransport?, Bool, Bool) in
            return (s.webSocket, s.isConnected, s.isClosed)
        }

        if isClosed || ws == nil {
            throw LiveError.sessionClosed
        }

        if isConn, let ws {
            return ws
        }

        return try await withCheckedThrowingContinuation { continuation in
            state.withLock { s in
                if s.isClosed || s.webSocket == nil {
                    continuation.resume(throwing: LiveError.sessionClosed)
                } else if s.isConnected, let ws = s.webSocket {
                    continuation.resume(returning: ws)
                } else {
                    s.pendingSendContinuations.append(continuation)
                }
            }
        }
    }

    public func disconnect() async {
        let (ws, task, continuation, pendingSends) = state.withLock { s -> (WebSocketTransport?, Task<Void, Never>?, AsyncThrowingStream<LiveEvent, Error>.Continuation?, [CheckedContinuation<WebSocketTransport, Error>]) in
            s.isConnected = false
            s.isClosed = true
            let ws = s.webSocket
            let task = s.receiveTask
            let cont = s.continuation
            let sends = s.pendingSendContinuations
            s.webSocket = nil
            s.receiveTask = nil
            s.continuation = nil
            s.pendingSendContinuations = []
            return (ws, task, cont, sends)
        }

        for cont in pendingSends {
            cont.resume(throwing: LiveError.sessionClosed)
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
            let (eventContinuation, pendingSends, ws) = state.withLock { s -> (AsyncThrowingStream<LiveEvent, Error>.Continuation?, [CheckedContinuation<WebSocketTransport, Error>], WebSocketTransport?) in
                s.isConnected = true
                let sends = s.pendingSendContinuations
                s.pendingSendContinuations = []
                return (s.continuation, sends, s.webSocket)
            }
            if let ws {
                for cont in pendingSends {
                    cont.resume(returning: ws)
                }
            } else {
                for cont in pendingSends {
                    cont.resume(throwing: LiveError.sessionClosed)
                }
            }
            eventContinuation?.yield(.connected)
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
        let (continuation, pendingSends) = state.withLock { s -> (AsyncThrowingStream<LiveEvent, Error>.Continuation?, [CheckedContinuation<WebSocketTransport, Error>]) in
            s.isConnected = false
            s.isClosed = true
            s.webSocket = nil
            let cont = s.continuation
            s.continuation = nil
            let sends = s.pendingSendContinuations
            s.pendingSendContinuations = []
            return (cont, sends)
        }

        for cont in pendingSends {
            cont.resume(throwing: LiveError.sessionClosed)
        }

        continuation?.yield(.disconnected)
        continuation?.finish()
    }
}
