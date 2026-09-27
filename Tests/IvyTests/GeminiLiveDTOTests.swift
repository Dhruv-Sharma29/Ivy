import Testing
import Foundation
@testable import IvyCore

@Suite("Phase 4B - Gemini Live DTO and Session Protocol Tests")
struct GeminiLiveDTOTests {

    @Test("BidiClientMessage setup encodes correctly")
    func testSetupSerialization() throws {
        let setup = BidiSetup(
            model: "models/gemini-2.0-flash-exp",
            generationConfig: BidiGenerationConfig(responseModalities: ["AUDIO"]),
            systemInstruction: BidiSystemInstruction(text: "You are Ivy.")
        )
        let clientMessage = BidiClientMessage(setup: setup)

        let encoder = JSONEncoder()
        let data = try encoder.encode(clientMessage)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let setupDict = try #require(json["setup"] as? [String: Any])
        #expect(setupDict["model"] as? String == "models/gemini-2.0-flash-exp")

        let genConfig = try #require(setupDict["generationConfig"] as? [String: Any])
        let modalities = try #require(genConfig["responseModalities"] as? [String])
        #expect(modalities == ["AUDIO"])

        let sysInstruction = try #require(setupDict["systemInstruction"] as? [String: Any])
        let parts = try #require(sysInstruction["parts"] as? [[String: Any]])
        #expect(parts.first?["text"] as? String == "You are Ivy.")
    }

    @Test("BidiRealtimeInput encodes 16kHz PCM audio chunk to base64")
    func testRealtimeInputAudioSerialization() throws {
        let pcmBytes = Data([0x01, 0x02, 0x03, 0x04])
        let realtimeInput = BidiRealtimeInput(pcmData: pcmBytes, sampleRate: 16000)
        let message = BidiClientMessage(realtimeInput: realtimeInput)

        let data = try JSONEncoder().encode(message)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let inputDict = try #require(json["realtimeInput"] as? [String: Any])
        let audioDict = try #require(inputDict["audio"] as? [String: Any])
        #expect(audioDict["mimeType"] as? String == "audio/pcm;rate=16000")
        #expect(audioDict["data"] as? String == pcmBytes.base64EncodedString())
    }

    @Test("BidiRealtimeInput supports legacy mediaChunks initialization")
    func testLegacyMediaChunksSerialization() throws {
        let pcmBytes = Data([0x0A, 0x0B])
        let blob = BidiBlob(mimeType: "audio/pcm;rate=16000", data: pcmBytes.base64EncodedString())
        let realtimeInput = BidiRealtimeInput(mediaChunks: [blob])
        let message = BidiClientMessage(realtimeInput: realtimeInput)

        let data = try JSONEncoder().encode(message)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let inputDict = try #require(json["realtimeInput"] as? [String: Any])
        let mediaChunks = try #require(inputDict["mediaChunks"] as? [[String: Any]])
        #expect(mediaChunks.count == 1)
        #expect(mediaChunks.first?["mimeType"] as? String == "audio/pcm;rate=16000")
    }

    @Test("BidiServerMessage decodes setupComplete")
    func testServerSetupCompleteDecoding() throws {
        let json = """
        {
            "setupComplete": {}
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(BidiServerMessage.self, from: json)
        #expect(message.setupComplete != nil)
        #expect(message.serverContent == nil)
    }

    @Test("BidiClientContent and BidiTurn encode correctly")
    func testClientContentSerialization() throws {
        let turn = BidiTurn(role: "user", parts: [BidiPart(text: "Hello from turn")])
        let content = BidiClientContent(turns: [turn], turnComplete: true)
        let clientMsg = BidiClientMessage(clientContent: content)

        let data = try JSONEncoder().encode(clientMsg)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contentDict = try #require(json["clientContent"] as? [String: Any])
        #expect(contentDict["turnComplete"] as? Bool == true)
        let turns = try #require(contentDict["turns"] as? [[String: Any]])
        #expect(turns.first?["role"] as? String == "user")
    }

    @Test("LiveError localized descriptions are distinct and descriptive")
    func testLiveErrorDescriptions() {
        let errors: [LiveError] = [
            .missingAPIKey,
            .invalidURL,
            .connectionFailed("unreachable"),
            .setupFailed("handshake"),
            .decodingError("corrupt"),
            .serverError("500"),
            .sessionClosed,
            .audioEncodingFailed,
            .microphonePermissionDenied,
            .microphonePermissionRestricted
        ]

        for err in errors {
            let desc = err.localizedDescription
            #expect(!desc.isEmpty)
        }
    }

    @Test("BidiServerMessage decodes serverContent with audio and text turns")
    func testServerContentWithAudioAndText() throws {
        let audioBytes = Data([0x10, 0x20, 0x30, 0x40])
        let base64Audio = audioBytes.base64EncodedString()
        let json = """
        {
            "serverContent": {
                "modelTurn": {
                    "parts": [
                        {
                            "text": "Hello there!"
                        },
                        {
                            "inlineData": {
                                "mimeType": "audio/pcm;rate=24000",
                                "data": "\(base64Audio)"
                            }
                        }
                    ]
                },
                "turnComplete": true,
                "interrupted": false
            }
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(BidiServerMessage.self, from: json)
        let content = try #require(message.serverContent)
        #expect(content.turnComplete == true)
        #expect(content.interrupted == false)

        let modelTurn = try #require(content.modelTurn)
        #expect(modelTurn.parts.count == 2)
        #expect(modelTurn.parts[0].text == "Hello there!")

        let inlineData = try #require(modelTurn.parts[1].inlineData)
        #expect(inlineData.mimeType == "audio/pcm;rate=24000")
        let decodedAudio = try #require(Data(base64Encoded: inlineData.data))
        #expect(decodedAudio == audioBytes)
    }

    @Test("BidiServerMessage decodes interrupted turn")
    func testServerInterruptedDecoding() throws {
        let json = """
        {
            "serverContent": {
                "interrupted": true
            }
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(BidiServerMessage.self, from: json)
        let content = try #require(message.serverContent)
        #expect(content.interrupted == true)
    }

    @Test("Test exact serverPayload decoding")
    func testExactServerPayloadDecoding() throws {
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
        let data = serverPayload.data(using: .utf8)!
        let msg = try JSONDecoder().decode(BidiServerMessage.self, from: data)
        #expect(msg.serverContent != nil)
    }

    @Test("MockGeminiLiveSession lifecycle and event streaming")
    func testMockGeminiLiveSession() async throws {
        let mock = MockGeminiLiveSession()
        #expect(!mock.isConnected)

        let eventsStream = mock.receiveEvents()

        let receiveTask = Task { () -> [LiveEvent] in
            var events: [LiveEvent] = []
            for try await event in eventsStream {
                events.append(event)
            }
            return events
        }

        try await mock.connect()
        #expect(mock.isConnected)

        let pcmData = Data([0x01, 0x02, 0x03])
        try await mock.sendAudio(pcmData)
        #expect(mock.sentAudioChunks == [pcmData])

        let responseAudio = Data([0xAA, 0xBB])
        mock.simulateEvent(.audioChunk(responseAudio))
        mock.simulateEvent(.textTurn("Ivy says hello"))
        mock.simulateEvent(.turnComplete)
        mock.simulateEvent(.interrupted)

        await mock.disconnect()
        #expect(!mock.isConnected)

        let receivedEvents = try await receiveTask.value
        #expect(receivedEvents.contains(.connected))
        #expect(receivedEvents.contains(.audioChunk(responseAudio)))
        #expect(receivedEvents.contains(.textTurn("Ivy says hello")))
        #expect(receivedEvents.contains(.turnComplete))
        #expect(receivedEvents.contains(.interrupted))
        #expect(receivedEvents.contains(.disconnected))
    }

    @Test("MockGeminiLiveSession handles connect and send errors")
    func testMockGeminiLiveSessionErrors() async {
        let mock = MockGeminiLiveSession(connectError: LiveError.connectionFailed("Host unreachable"))
        await #expect(throws: LiveError.connectionFailed("Host unreachable")) {
            try await mock.connect()
        }

        let sendMock = MockGeminiLiveSession()
        await #expect(throws: LiveError.sessionClosed) {
            try await sendMock.sendAudio(Data([1, 2]))
        }
    }
}
