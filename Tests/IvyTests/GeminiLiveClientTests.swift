import Testing
import Foundation
@testable import IvyCore

@Suite("Phase 4B - GeminiLiveClient Unit Tests")
struct GeminiLiveClientTests {

    @Test("GeminiLiveClient rejects empty API key")
    func testRejectsEmptyAPIKey() async {
        let client = GeminiLiveClient(apiKey: "")
        await #expect(throws: LiveError.missingAPIKey) {
            try await client.connect()
        }

        let wsClient = GeminiLiveClient(apiKey: "   \n\t  ")
        await #expect(throws: LiveError.missingAPIKey) {
            try await wsClient.connect()
        }
    }

    @Test("GeminiLiveClient resumes WebSocket and sends setup message")
    func testConnectSendsSetupMessage() async throws {
        let mockTransport = MockWebSocketTransport()
        let client = GeminiLiveClient(
            apiKey: "test-api-key",
            model: "models/gemini-2.0-flash-exp",
            systemInstruction: "You are Ivy.",
            webSocketFactory: { _ in mockTransport }
        )

        try await client.connect()

        #expect(mockTransport.isResumed)
        #expect(mockTransport.sentMessages.count == 1)

        guard case .string(let setupStr) = mockTransport.sentMessages.first else {
            Issue.record("Expected string message for setup")
            return
        }

        let setupData = try #require(setupStr.data(using: .utf8))
        let decoded = try JSONDecoder().decode(BidiClientMessage.self, from: setupData)
        #expect(decoded.setup?.model == "models/gemini-2.0-flash-exp")
        #expect(decoded.setup?.generationConfig?.responseModalities == ["AUDIO"])
        #expect(decoded.setup?.generationConfig?.speechConfig?.voiceConfig?.prebuiltVoiceConfig?.voiceName == "Kore")
        #expect(decoded.setup?.systemInstruction?.parts.first?.text == "You are Ivy.")
    }

    @Test("Receiving setupComplete marks client connected and yields .connected")
    func testReceiveSetupComplete() async throws {
        let mockTransport = MockWebSocketTransport()
        let client = GeminiLiveClient(
            apiKey: "test-key",
            webSocketFactory: { _ in mockTransport }
        )

        let events = client.receiveEvents()
        let receiveTask = Task { () -> [LiveEvent] in
            var list: [LiveEvent] = []
            for try await event in events {
                list.append(event)
                if event == .connected {
                    break
                }
            }
            return list
        }

        try await client.connect()

        // Simulate server sending setupComplete
        let setupCompleteJson = "{\"setupComplete\": {}}"
        mockTransport.enqueueReceiveString(setupCompleteJson)

        let received = try await receiveTask.value
        #expect(received.contains(.connected))
        #expect(client.isConnected)

        await client.disconnect()
    }

    @Test("sendAudio fails when not connected and succeeds when connected")
    func testSendAudio() async throws {
        let mockTransport = MockWebSocketTransport()
        let client = GeminiLiveClient(
            apiKey: "test-key",
            webSocketFactory: { _ in mockTransport }
        )

        // Before connect: throws sessionClosed
        await #expect(throws: LiveError.sessionClosed) {
            try await client.sendAudio(Data([1, 2, 3]))
        }

        try await client.connect()
        // Simulate setupComplete
        mockTransport.enqueueReceiveString("{\"setupComplete\": {}}")

        // Wait a tiny bit for setupComplete processing
        for _ in 0..<50 {
            if client.isConnected { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(client.isConnected)

        let pcmData = Data([0x12, 0x34, 0x56, 0x78])
        try await client.sendAudio(pcmData)

        #expect(mockTransport.sentMessages.count == 2) // setup + audio
        guard case .string(let audioJson) = mockTransport.sentMessages.last else {
            Issue.record("Expected string message for audio")
            return
        }

        let data = try #require(audioJson.data(using: .utf8))
        let clientMsg = try JSONDecoder().decode(BidiClientMessage.self, from: data)
        let chunk = try #require(clientMsg.realtimeInput?.audio)
        #expect(chunk.mimeType == "audio/pcm;rate=16000")
        #expect(chunk.data == pcmData.base64EncodedString())

        await client.disconnect()
    }

    @Test("Receives audio chunks, text turns, turnComplete, and interrupted")
    func testReceivesStreamingEvents() async throws {
        let mockTransport = MockWebSocketTransport()
        let client = GeminiLiveClient(
            apiKey: "test-key",
            webSocketFactory: { _ in mockTransport }
        )

        let events = client.receiveEvents()
        let receiveTask = Task { () -> [LiveEvent] in
            var list: [LiveEvent] = []
            for try await event in events {
                list.append(event)
                if event == .interrupted {
                    break
                }
            }
            return list
        }

        try await client.connect()
        mockTransport.enqueueReceiveString("{\"setupComplete\": {}}")

        let samplePCM = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let serverPayload = """
        {
            "serverContent": {
                "modelTurn": {
                    "parts": [
                        { "text": "Speaking now" },
                        {
                            "inlineData": {
                                "mimeType": "audio/pcm;rate=24000",
                                "data": "\(samplePCM.base64EncodedString())"
                            }
                        }
                    ]
                },
                "turnComplete": true
            }
        }
        """
        mockTransport.enqueueReceiveString(serverPayload)

        let interruptedPayload = """
        {
            "serverContent": {
                "interrupted": true
            }
        }
        """
        mockTransport.enqueueReceiveString(interruptedPayload)

        // Wait for all expected streamed events
        let received = try await receiveTask.value
        #expect(received.contains(.connected))
        #expect(received.contains(.textTurn("Speaking now")))
        #expect(received.contains(.audioChunk(samplePCM)))
        #expect(received.contains(.turnComplete))
        #expect(received.contains(.interrupted))

        // Disconnect to complete the session
        await client.disconnect()
        #expect(!client.isConnected)
    }

    @Test("Disconnect cleans up transport and state")
    func testDisconnect() async throws {
        let mockTransport = MockWebSocketTransport()
        let client = GeminiLiveClient(
            apiKey: "test-key",
            webSocketFactory: { _ in mockTransport }
        )

        try await client.connect()
        mockTransport.enqueueReceiveString("{\"setupComplete\": {}}")

        await client.disconnect()
        #expect(!client.isConnected)
        #expect(mockTransport.isCancelled)
        #expect(mockTransport.closeCode == .normalClosure)
    }
}
