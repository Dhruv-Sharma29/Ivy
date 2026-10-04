import Testing
import Foundation
import os
@testable import IvyCore

@Suite("Phase 4B - GeminiLiveClient Unit Tests")
struct GeminiLiveClientTests {

    @Test("screen image sends its identity and dimensions with the frame, and surfaces transport failure")
    func screenFrameContext() async throws {
        let transport = MockWebSocketTransport()
        let client = GeminiLiveClient(apiKey: "fixture", webSocketFactory: { _ in transport })
        await #expect(throws: LiveError.sessionClosed) {
            try await client.sendImage(Data([1]), context: "frame")
        }
        try await client.connect()
        transport.enqueueReceiveString("{\"setupComplete\": {}}")
        for _ in 0..<50 {
            if client.isConnected { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(client.isConnected)
        try await client.sendImage(Data([1, 2]), context: "screenshot_id=fixture; 800x600 pixels")
        guard case .string(let json) = transport.sentMessages.last else {
            Issue.record("Missing image message"); await client.disconnect(); return
        }
        let message = try JSONDecoder().decode(BidiClientMessage.self, from: Data(json.utf8))
        #expect(message.realtimeInput?.text == "screenshot_id=fixture; 800x600 pixels")
        #expect(message.realtimeInput?.video?.data == Data([1, 2]).base64EncodedString())
        try await client.sendImage(Data([3]))
        transport.setSendError(LiveError.sessionClosed)
        await #expect(throws: LiveError.self) { try await client.sendImage(Data([4]), context: "frame") }
        await client.disconnect()
    }

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
        #expect(decoded.setup?.generationConfig.responseModalities == ["AUDIO"])
        #expect(decoded.setup?.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName == "Kore")
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

    @Test("Voice Lock: Initial Live setup explicitly requests Kore")
    func testInitialSetupRequestsKore() async throws {
        let mockTransport = MockWebSocketTransport()
        let client = GeminiLiveClient(
            apiKey: "test-api-key",
            webSocketFactory: { _ in mockTransport }
        )

        try await client.connect()

        guard case .string(let setupStr) = mockTransport.sentMessages.first else {
            Issue.record("Expected string message for setup")
            return
        }

        let setupData = try #require(setupStr.data(using: .utf8))
        let decoded = try JSONDecoder().decode(BidiClientMessage.self, from: setupData)
        #expect(decoded.setup?.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName == "Kore")
        await client.disconnect()
    }

    @Test("Voice Lock: Reconnect after disconnect still explicitly requests Kore")
    func testReconnectRequestsKore() async throws {
        let transportsLock = OSAllocatedUnfairLock(initialState: [MockWebSocketTransport]())
        let client = GeminiLiveClient(
            apiKey: "test-api-key",
            webSocketFactory: { _ in
                let t = MockWebSocketTransport()
                transportsLock.withLock { $0.append(t) }
                return t
            }
        )

        // 1. Initial connect
        try await client.connect()
        #expect(transportsLock.withLock { $0.count } == 1)
        let firstTransport = transportsLock.withLock { $0[0] }
        guard case .string(let firstSetup) = firstTransport.sentMessages.first else {
            Issue.record("Expected setup message")
            return
        }
        let firstDecoded = try JSONDecoder().decode(BidiClientMessage.self, from: try #require(firstSetup.data(using: .utf8)))
        #expect(firstDecoded.setup?.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName == "Kore")

        await client.disconnect()

        // 2. Reconnect
        try await client.connect()
        #expect(transportsLock.withLock { $0.count } == 2)
        let secondTransport = transportsLock.withLock { $0[1] }
        guard case .string(let secondSetup) = secondTransport.sentMessages.first else {
            Issue.record("Expected setup message on reconnect")
            return
        }
        let secondDecoded = try JSONDecoder().decode(BidiClientMessage.self, from: try #require(secondSetup.data(using: .utf8)))
        #expect(secondDecoded.setup?.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName == "Kore")

        await client.disconnect()
    }

    @Test("Voice Lock: No setup path can omit voiceName or select another voice")
    func testVoiceLockEnforcement() {
        // Even if attempted to pass another voice or nil, Kore is locked
        let prebuilt = BidiPrebuiltVoiceConfig(voiceName: "Puck")
        #expect(prebuilt.voiceName == "Kore")

        let prebuiltDefault = BidiPrebuiltVoiceConfig()
        #expect(prebuiltDefault.voiceName == "Kore")

        let voiceConfig = BidiVoiceConfig(prebuiltVoiceConfig: nil)
        #expect(voiceConfig.prebuiltVoiceConfig.voiceName == "Kore")

        let speechConfig = BidiSpeechConfig(voiceConfig: nil)
        #expect(speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName == "Kore")

        let genConfig = BidiGenerationConfig(speechConfig: nil)
        #expect(genConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName == "Kore")

        let setup = BidiSetup(generationConfig: nil)
        #expect(setup.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName == "Kore")

        let client = GeminiLiveClient(apiKey: "key", voiceName: "Fenrir")
        #expect(client.voiceName == "Kore")
    }

    @Test("Raw setup payload strictly contains non-null generationConfig, speechConfig, voiceConfig, and Kore")
    func testRawSetupPayloadContainsFullVoiceHierarchyAndKore() async throws {
        let mockTransport = MockWebSocketTransport()
        let client = GeminiLiveClient(
            apiKey: "test-api-key",
            model: "models/gemini-2.0-flash-exp",
            systemInstruction: "You are Ivy.",
            webSocketFactory: { _ in mockTransport }
        )

        try await client.connect()

        guard case .string(let rawJson) = mockTransport.sentMessages.first else {
            Issue.record("Expected raw JSON string for setup message")
            return
        }

        // 1. Verify JSONSerialization structure
        let data = try #require(rawJson.data(using: .utf8))
        let jsonObject = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let setupDict = try #require(jsonObject["setup"] as? [String: Any])
        #expect(setupDict["model"] as? String == "models/gemini-2.0-flash-exp")

        let genConfig = try #require(setupDict["generationConfig"] as? [String: Any])
        let modalities = try #require(genConfig["responseModalities"] as? [String])
        #expect(modalities == ["AUDIO"])

        let speechConfig = try #require(genConfig["speechConfig"] as? [String: Any])
        let voiceConfig = try #require(speechConfig["voiceConfig"] as? [String: Any])
        let prebuiltVoiceConfig = try #require(voiceConfig["prebuiltVoiceConfig"] as? [String: Any])
        #expect(prebuiltVoiceConfig["voiceName"] as? String == "Kore")

        // 2. Verify no prohibited fallback or alternate voices exist in the payload
        let prohibitedVoices = ["Puck", "Fenrir", "Aoede", "Charon", "Zephyr", "Leda", "Orus"]
        for voice in prohibitedVoices {
            #expect(!rawJson.contains("\"\(voice)\""))
        }

        await client.disconnect()
    }

    @Test("Decoding arbitrary external JSON cannot override Kore voice")
    func testServerOrDecodedPayloadCannotOverrideKore() throws {
        let maliciousPayloads = [
            "{\"voiceName\": \"Puck\"}",
            "{\"voiceName\": \"Fenrir\"}",
            "{\"voiceName\": \"Aoede\"}",
            "{\"voiceName\": \"Charon\"}",
            "{\"voiceName\": null}",
            "{}"
        ]

        for payload in maliciousPayloads {
            let data = payload.data(using: .utf8)!
            let decoded = try JSONDecoder().decode(BidiPrebuiltVoiceConfig.self, from: data)
            #expect(decoded.voiceName == "Kore")
        }
    }

    @Test("Multiple rapid reconnects and restarts always send Kore voice configuration")
    func testMultipleReconnectsAlwaysSendKoreSetup() async throws {
        let transportsLock = OSAllocatedUnfairLock(initialState: [MockWebSocketTransport]())
        let client = GeminiLiveClient(
            apiKey: "test-api-key",
            webSocketFactory: { _ in
                let t = MockWebSocketTransport()
                transportsLock.withLock { $0.append(t) }
                return t
            }
        )

        for iteration in 1...5 {
            try await client.connect()
            let count = transportsLock.withLock { $0.count }
            #expect(count == iteration)

            let transport = transportsLock.withLock { $0[iteration - 1] }
            guard case .string(let setupStr) = transport.sentMessages.first else {
                Issue.record("Expected setup string for iteration \(iteration)")
                return
            }

            let data = try #require(setupStr.data(using: .utf8))
            let decoded = try JSONDecoder().decode(BidiClientMessage.self, from: data)
            #expect(decoded.setup?.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName == "Kore")

            await client.disconnect()
        }
    }
}
