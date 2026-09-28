import Foundation
import os

/// WebSocket-based client implementing bidirectional streaming with Gemini Multimodal Live API.
public final class GeminiLiveClient: GeminiLiveSession, @unchecked Sendable {
    public typealias WebSocketFactory = @Sendable (URLRequest) -> WebSocketTransport

    public static let liveVoiceName: String = BidiPrebuiltVoiceConfig.liveVoiceName

    public var apiKey: String {
        state.withLock { $0.apiKey }
    }
    public let model: String
    public let voiceName: String
    public let systemInstruction: String?
    public let tools: [ToolDeclarationWrapper]?
    public let session: URLSession
    private let webSocketFactory: WebSocketFactory

    private struct State {
        var apiKey: String
        var webSocket: WebSocketTransport? = nil
        var currentConnectionId: UUID? = nil
        var isConnected: Bool = false
        var isClosed: Bool = false
        var isSetupSent: Bool = false
        var continuation: AsyncThrowingStream<LiveEvent, Error>.Continuation? = nil
        var receiveTask: Task<Void, Never>? = nil
        var pendingSendContinuations: [CheckedContinuation<WebSocketTransport, Error>] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(
        apiKey: String,
        model: String = "models/gemini-3.1-flash-live-preview",
        voiceName: String = liveVoiceName,
        systemInstruction: String? = nil,
        tools: [ToolDeclarationWrapper]? = nil,
        session: URLSession = .shared,
        webSocketFactory: WebSocketFactory? = nil
    ) {
        self.state = OSAllocatedUnfairLock(initialState: State(apiKey: apiKey))
        self.model = model
        self.voiceName = Self.liveVoiceName
        self.systemInstruction = systemInstruction
        self.tools = tools
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
        print("[LIVE] connect requested")

        let currentKey = state.withLock { $0.apiKey }
        guard !currentKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("[LIVE] connection error: Missing API Key")
            throw LiveError.missingAPIKey
        }

        guard let encodedKey = currentKey.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key=\(encodedKey)") else {
            print("[LIVE] connection error: Invalid URL")
            throw LiveError.invalidURL
        }

        // Clean up any stale active connection before opening a new one
        let oldWsAndTask = state.withLock { s -> (WebSocketTransport?, Task<Void, Never>?, [CheckedContinuation<WebSocketTransport, Error>])? in
            guard s.isConnected || (s.webSocket != nil && !s.isClosed) else {
                s.isClosed = false
                return nil
            }
            s.isConnected = false
            s.isClosed = false
            s.isSetupSent = false
            let ws = s.webSocket
            let task = s.receiveTask
            let sends = s.pendingSendContinuations
            s.webSocket = nil
            s.receiveTask = nil
            s.pendingSendContinuations = []
            return (ws, task, sends)
        }

        if let (oldWs, oldTask, oldSends) = oldWsAndTask {
            for cont in oldSends {
                cont.resume(throwing: LiveError.sessionClosed)
            }
            oldTask?.cancel()
            oldWs?.cancel(closeCode: .normalClosure, reason: nil)
            print("[LIVE] connection closed")
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30

        let ws = webSocketFactory(request)
        let connectionId = UUID()
        state.withLock { s in
            s.webSocket = ws
            s.currentConnectionId = connectionId
            s.isClosed = false
            s.isConnected = false
            s.isSetupSent = false
        }

        ws.resume()
        print("[LIVE] websocket connected")

        // Send Setup Message exactly once
        let shouldSendSetup = state.withLock { s -> Bool in
            guard s.currentConnectionId == connectionId else { return false }
            if !s.isSetupSent {
                s.isSetupSent = true
                return true
            }
            return false
        }

        if shouldSendSetup {
            let filteredTools: [ToolDeclarationWrapper]? = (tools?.isEmpty == true) ? nil : tools
            let setup = BidiSetup(
                model: model,
                generationConfig: BidiGenerationConfig(
                    responseModalities: ["AUDIO"],
                    speechConfig: BidiSpeechConfig(
                        voiceConfig: BidiVoiceConfig(
                            prebuiltVoiceConfig: BidiPrebuiltVoiceConfig(voiceName: Self.liveVoiceName)
                        )
                    )
                ),
                systemInstruction: systemInstruction.map { BidiSystemInstruction(text: $0) },
                tools: filteredTools
            )
            let setupMessage = BidiClientMessage(setup: setup)

            do {
                let data = try JSONEncoder().encode(setupMessage)
                guard let jsonString = String(data: data, encoding: .utf8) else {
                    throw LiveError.setupFailed("Failed to encode setup payload.")
                }
                print("[LIVE VOICE] voice=Kore")
                print("[LIVE] setup sent")
                try await ws.send(.string(jsonString))
            } catch {
                print("[LIVE] connection error: \(error.localizedDescription)")
                ws.cancel(closeCode: .normalClosure, reason: nil)
                throw LiveError.setupFailed(error.localizedDescription)
            }
        }

        // Start background message receiver
        startReceiveLoop(transport: ws, connectionId: connectionId)
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

    public func sendToolResponses(_ responses: [FunctionResponse]) async throws {
        let ws = try await getConnectedWebSocket()

        let toolResponse = BidiToolResponse(functionResponses: responses.map { BidiFunctionResponse(from: $0) })
        let message = BidiClientMessage(toolResponse: toolResponse)

        do {
            let jsonData = try JSONEncoder().encode(message)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                throw LiveError.serverError("Failed to encode tool response payload.")
            }
            #if DEBUG
            print("[LIVE VOICE] tool response payload: \(jsonString)")
            #endif
            try await ws.send(.string(jsonString))
        } catch {
            throw LiveError.serverError("Failed to send tool response: \(error.localizedDescription)")
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
        let (ws, task, continuation, pendingSends, wasActive) = state.withLock { s -> (WebSocketTransport?, Task<Void, Never>?, AsyncThrowingStream<LiveEvent, Error>.Continuation?, [CheckedContinuation<WebSocketTransport, Error>], Bool) in
            let wasActive = s.isConnected || (s.webSocket != nil && !s.isClosed)
            s.isConnected = false
            s.isClosed = true
            s.isSetupSent = false
            s.currentConnectionId = nil
            let ws = s.webSocket
            let task = s.receiveTask
            let cont = s.continuation
            let sends = s.pendingSendContinuations
            s.webSocket = nil
            s.receiveTask = nil
            s.continuation = nil
            s.pendingSendContinuations = []
            return (ws, task, cont, sends, wasActive)
        }

        for cont in pendingSends {
            cont.resume(throwing: LiveError.sessionClosed)
        }

        task?.cancel()
        ws?.cancel(closeCode: .normalClosure, reason: nil)
        if wasActive {
            print("[LIVE] connection closed")
        }
        continuation?.yield(.disconnected)
        continuation?.finish()
    }

    // MARK: - Private Receive Loop

    private func startReceiveLoop(transport: WebSocketTransport, connectionId: UUID) {
        let task = Task { [weak self, transport] in
            while !Task.isCancelled {
                do {
                    let message = try await transport.receive()
                    guard let self else { break }
                    self.handleIncomingWebSocketMessage(message, connectionId: connectionId)
                } catch {
                    guard let self else { break }
                    self.handleReceiveError(error, connectionId: connectionId)
                    break
                }
            }
        }

        state.withLock { s in
            if s.currentConnectionId == connectionId {
                s.receiveTask = task
            }
        }
    }

    private func handleIncomingWebSocketMessage(_ message: URLSessionWebSocketTask.Message, connectionId: UUID) {
        let isCurrent = state.withLock { $0.currentConnectionId == connectionId }
        guard isCurrent else { return }

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
            #if DEBUG
            let preview = String(data: payloadData, encoding: .utf8) ?? ""
            print("[LIVE] server error: failed to decode message: \(preview.prefix(100))")
            #endif
            return
        }

        if let error = serverMessage.error {
            let msg = error.message ?? "Unknown server error (code: \(error.code ?? -1), status: \(error.status ?? "unknown"))"
            print("[LIVE] server message received type=error")
            print("[LIVE] server error: \(msg)")
            handleReceiveError(LiveError.serverError(msg), connectionId: connectionId)
            return
        }

        if serverMessage.setupComplete != nil {
            print("[LIVE] server message received type=setupComplete")
            print("[LIVE] setup acknowledged")
            print("[LIVE] receive loop started")
            let (eventContinuation, pendingSends, ws) = state.withLock { s -> (AsyncThrowingStream<LiveEvent, Error>.Continuation?, [CheckedContinuation<WebSocketTransport, Error>], WebSocketTransport?) in
                guard s.currentConnectionId == connectionId else {
                    return (nil, [], nil)
                }
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

        if let toolCall = serverMessage.toolCall {
            print("[LIVE] server message received type=toolCall")
            let continuation = state.withLock { s -> AsyncThrowingStream<LiveEvent, Error>.Continuation? in
                guard s.currentConnectionId == connectionId else { return nil }
                return s.continuation
            }
            for call in toolCall.functionCalls {
                continuation?.yield(.toolCall(call))
            }
        }

        if let content = serverMessage.serverContent {
            print("[LIVE] server message received type=serverContent")
            let continuation = state.withLock { s -> AsyncThrowingStream<LiveEvent, Error>.Continuation? in
                guard s.currentConnectionId == connectionId else { return nil }
                return s.continuation
            }

            if content.interrupted == true {
                continuation?.yield(.interrupted)
            }

            if let modelTurn = content.modelTurn {
                for part in modelTurn.parts {
                    if let inlineData = part.inlineData,
                       let audioData = Data(base64Encoded: inlineData.data) {
                        print("[LIVE] audio response received bytes=\(audioData.count)")
                        continuation?.yield(.audioChunk(audioData))
                    }
                    if let text = part.text {
                        continuation?.yield(.textTurn(text))
                    }
                    if let functionCall = part.functionCall {
                        print("[LIVE] tool call received")
                        continuation?.yield(.toolCall(functionCall))
                    }
                }
            }

            if content.turnComplete == true {
                print("[LIVE] turn complete")
                continuation?.yield(.turnComplete)
            }
        }
    }

    private func handleReceiveError(_ error: Error, connectionId: UUID) {
        print("[LIVE] connection error: \(error.localizedDescription)")
        let (continuation, pendingSends, wasActive) = state.withLock { s -> (AsyncThrowingStream<LiveEvent, Error>.Continuation?, [CheckedContinuation<WebSocketTransport, Error>], Bool) in
            guard s.currentConnectionId == connectionId else {
                return (nil, [], false)
            }
            let wasActive = s.isConnected || (s.webSocket != nil && !s.isClosed)
            s.isConnected = false
            s.isClosed = true
            s.isSetupSent = false
            s.webSocket = nil
            s.currentConnectionId = nil
            let cont = s.continuation
            s.continuation = nil
            let sends = s.pendingSendContinuations
            s.pendingSendContinuations = []
            return (cont, sends, wasActive)
        }

        for cont in pendingSends {
            cont.resume(throwing: LiveError.sessionClosed)
        }

        if wasActive {
            print("[LIVE] connection error: \(error.localizedDescription)")
            print("[LIVE] connection closed")
            continuation?.yield(.disconnected)
            continuation?.finish()
        }
    }
}
