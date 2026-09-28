import Testing
import Foundation
import os
@testable import IvyCore

@Suite("Phase 4D Live Regression Tests")
@MainActor
struct Phase4DLiveRegressionTests {

    private static let testSandboxURL = URL(fileURLWithPath: "/Users/testuser/Sandbox")

    private func createTestCoordinator(
        session: MockGeminiLiveSession = MockGeminiLiveSession(),
        capture: MockAudioCapture = MockAudioCapture(isPermissionGranted: true),
        player: MockLiveAudioPlayer = MockLiveAudioPlayer(autoDrain: false),
        detector: MockWakeWordDetector = MockWakeWordDetector(),
        hotkey: MockGlobalHotkeyManager = MockGlobalHotkeyManager(),
        workspace: MockWorkspace = MockWorkspace(),
        shellExecutor: MockShellExecutor = MockShellExecutor(),
        appleScriptExecutor: MockAppleScriptExecutor = MockAppleScriptExecutor(),
        calendarExecutor: MockCalendarExecutor = MockCalendarExecutor(),
        fileExecutor: MockFileExecutor = MockFileExecutor()
    ) -> (
        coordinator: GeminiLiveVoiceCoordinator,
        session: MockGeminiLiveSession,
        capture: MockAudioCapture,
        player: MockLiveAudioPlayer,
        detector: MockWakeWordDetector,
        hotkey: MockGlobalHotkeyManager
    ) {
        let registry = ToolRegistry(tools: [
            OpenAppTool(workspace: workspace),
            RunAppleScriptTool(executor: appleScriptExecutor),
            CalendarEventTool(executor: calendarExecutor),
            FileOpTool(executor: fileExecutor, allowedRoot: Self.testSandboxURL),
            RunShellTool(executor: shellExecutor)
        ])

        let bridge = ConfirmationBridge()
        let safetyGate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: safetyGate)

        let coordinator = GeminiLiveVoiceCoordinator(
            session: session,
            audioCapture: capture,
            audioPlayer: player,
            wakeWordDetector: detector,
            hotkeyManager: hotkey,
            toolDispatcher: dispatcher
        )

        return (coordinator, session, capture, player, detector, hotkey)
    }

    private func waitForCondition(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        intervalNanoseconds: UInt64 = 10_000_000,
        _ condition: () -> Bool
    ) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return condition()
    }

    // =========================================================================
    // MARK: - 1. One Live Connection & Setup Sent Exactly Once
    // =========================================================================

    @Test("1. Exactly one Live connection exists even if connect() is called repeatedly")
    func testOneLiveConnectionEnforced() async throws {
        let transportsLock = OSAllocatedUnfairLock(initialState: [MockWebSocketTransport]())
        let client = GeminiLiveClient(
            apiKey: "test-key",
            webSocketFactory: { _ in
                let t = MockWebSocketTransport()
                transportsLock.withLock { $0.append(t) }
                return t
            }
        )

        try await client.connect()
        let firstTransports = transportsLock.withLock { $0 }
        #expect(firstTransports.count == 1)
        #expect(firstTransports[0].isResumed)
        #expect(!firstTransports[0].isCancelled)

        // Reconnect without explicit disconnect must cleanly replace prior transport
        try await client.connect()
        let secondTransports = transportsLock.withLock { $0 }
        #expect(secondTransports.count == 2)
        #expect(secondTransports[0].isCancelled) // Old connection was torn down
        #expect(secondTransports[1].isResumed)
        #expect(!secondTransports[1].isCancelled)

        await client.disconnect()
        #expect(secondTransports[1].isCancelled)
    }

    @Test("2. Setup message is sent exactly once per connection")
    func testSetupSentExactlyOnce() async throws {
        let mockTransport = MockWebSocketTransport()
        let client = GeminiLiveClient(
            apiKey: "test-api-key",
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
        #expect(decoded.setup != nil)
        #expect(decoded.setup?.model == "models/gemini-3.1-flash-live-preview")

        await client.disconnect()
    }

    // =========================================================================
    // MARK: - 2. Setup Acknowledgement & Receive Loop Lifecycle
    // =========================================================================

    @Test("3. Setup acknowledgement marks client connected and yields .connected")
    func testSetupAcknowledgement() async throws {
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

        // Before setupComplete, client is not yet marked connected
        #expect(!client.isConnected)

        // Server sends setupComplete acknowledgment
        mockTransport.enqueueReceiveString("{\"setupComplete\": {}}")

        let received = try await receiveTask.value
        #expect(received.contains(.connected))
        #expect(client.isConnected)

        await client.disconnect()
    }

    @Test("4. Receive loop starts and processes streaming turns after setupComplete")
    func testReceiveLoopStarts() async throws {
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
                if event == .turnComplete {
                    break
                }
            }
            return list
        }

        try await client.connect()
        mockTransport.enqueueReceiveString("{\"setupComplete\": {}}")

        let textTurn = """
        {
            "serverContent": {
                "modelTurn": {
                    "parts": [{ "text": "Hello, world!" }]
                },
                "turnComplete": true
            }
        }
        """
        mockTransport.enqueueReceiveString(textTurn)

        let received = try await receiveTask.value
        #expect(received.contains(.connected))
        #expect(received.contains(.textTurn("Hello, world!")))
        #expect(received.contains(.turnComplete))

        await client.disconnect()
    }

    @Test("5. First audio response is received as structured .audioChunk event")
    func testFirstAudioResponseReceived() async throws {
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
                if case .audioChunk = event {
                    break
                }
            }
            return list
        }

        try await client.connect()
        mockTransport.enqueueReceiveString("{\"setupComplete\": {}}")

        let pcmData = Data([0x01, 0x02, 0x03, 0x04, 0x05])
        let audioTurn = """
        {
            "serverContent": {
                "modelTurn": {
                    "parts": [
                        {
                            "inlineData": {
                                "mimeType": "audio/pcm;rate=24000",
                                "data": "\(pcmData.base64EncodedString())"
                            }
                        }
                    ]
                }
            }
        }
        """
        mockTransport.enqueueReceiveString(audioTurn)

        let received = try await receiveTask.value
        #expect(received.contains(.audioChunk(pcmData)))

        await client.disconnect()
    }

    // =========================================================================
    // MARK: - 3. Reconnect & Stale Session Protection
    // =========================================================================

    @Test("6. Reconnect does not create duplicate Live sessions")
    func testReconnectDoesNotCreateDuplicateSessions() async throws {
        let (coordinator, session, capture, _, _, _) = createTestCoordinator()

        await coordinator.startSession()
        #expect(coordinator.state == .listening)
        #expect(capture.isCapturing)

        // Starting another session must stop and cleanly replace previous session
        await coordinator.startSession()
        #expect(coordinator.state == .listening)
        #expect(capture.isCapturing)

        await coordinator.stopSession()
        #expect(coordinator.state == .idle)
        #expect(!capture.isCapturing)
        #expect(!session.isConnected)
    }

    @Test("7. Stale session events and errors are ignored and do not mutate state")
    func testStaleSessionIgnored() async throws {
        let (coordinator, _, _, _, _, _) = createTestCoordinator()

        await coordinator.startSession()
        #expect(coordinator.state == .listening)

        // Simulate an old session event firing with a stale token directly
        await coordinator.handleWakePhraseDetected(token: UUID()) // Mismatched token
        #expect(coordinator.state == .listening) // Not changed to .interrupting

        await coordinator.processTranscriptionForInterruption("Hey Ivy", token: UUID())
        #expect(coordinator.state == .listening) // Not interrupted

        await coordinator.stopSession()
        #expect(coordinator.state == .idle)
    }

    @Test("8. Shutdown performs clean cleanup of hotkey, capture, player, and session")
    func testShutdownCleanup() async throws {
        let (coordinator, session, capture, player, _, hotkey) = createTestCoordinator()
        try coordinator.registerHotkey()
        #expect(hotkey.isRegistered)

        await coordinator.startSession()
        #expect(coordinator.state == .listening)
        #expect(capture.isCapturing)

        await coordinator.shutdown()
        #expect(!hotkey.isRegistered)
        #expect(coordinator.state == .idle)
        #expect(!capture.isCapturing)
        #expect(!player.isPlaying)
        #expect(!session.isConnected)
    }

    // =========================================================================
    // MARK: - 4. Voice-Only vs Tool Declarations
    // =========================================================================

    @Test("9. Voice-only Live works and omits 'tools' from setup payload")
    func testVoiceOnlyLiveOmitsToolsInSetup() async throws {
        let mockTransport = MockWebSocketTransport()
        let client = GeminiLiveClient(
            apiKey: "test-key",
            tools: nil, // Voice only
            webSocketFactory: { _ in mockTransport }
        )

        try await client.connect()

        guard case .string(let setupStr) = mockTransport.sentMessages.first else {
            Issue.record("Expected string message for setup")
            return
        }

        let setupData = try #require(setupStr.data(using: .utf8))
        let json = try JSONSerialization.jsonObject(with: setupData) as? [String: Any]
        let setupDict = json?["setup"] as? [String: Any]
        #expect(setupDict?["tools"] == nil, "Voice-only Live must not encode 'tools' in setup")

        await client.disconnect()
    }

    @Test("10. Live with tool declarations includes 'tools' in setup message")
    func testLiveWithToolsIncludesDeclarationsInSetup() async throws {
        let mockTransport = MockWebSocketTransport()
        let decl = FunctionDeclaration(name: "open_app", description: "Opens an application")
        let wrapper = ToolDeclarationWrapper(functionDeclarations: [decl])
        let client = GeminiLiveClient(
            apiKey: "test-key",
            tools: [wrapper],
            webSocketFactory: { _ in mockTransport }
        )

        try await client.connect()

        guard case .string(let setupStr) = mockTransport.sentMessages.first else {
            Issue.record("Expected string message for setup")
            return
        }

        let setupData = try #require(setupStr.data(using: .utf8))
        let decoded = try JSONDecoder().decode(BidiClientMessage.self, from: setupData)
        let tools = try #require(decoded.setup?.tools)
        #expect(tools.count == 1)
        #expect(tools.first?.functionDeclarations.first?.name == "open_app")

        await client.disconnect()
    }

    // =========================================================================
    // MARK: - 5. Phase 4B / 4C / Voice Regressions
    // =========================================================================

    @Test("11. Phase 4B Hey Ivy regression: wake phrase during speaking halts playback")
    func testHeyIvyInterruptionRegression() async throws {
        let (coordinator, session, _, player, _, _) = createTestCoordinator()

        await coordinator.startSession()
        #expect(coordinator.state == .listening)

        // Simulate Ivy speaking audio
        session.simulateEvent(.audioChunk(Data([0x01, 0x02])))

        let reachedSpeaking = await waitForCondition {
            coordinator.state == .speaking
        }
        #expect(reachedSpeaking)
        #expect(player.isPlaying)

        // Wake phrase detected
        await coordinator.handleWakePhraseDetected()
        #expect(coordinator.state == .listening)
        #expect(!player.isPlaying)

        await coordinator.stopSession()
    }

    @Test("12. Phase 4C PTT regression: key-down starts PTT and key-up stops PTT idempotently")
    func testPushToTalkRegression() async throws {
        let (coordinator, session, capture, _, _, _) = createTestCoordinator()

        // Key down starts PTT
        await coordinator.beginPushToTalk()
        #expect(coordinator.state == .listening)
        #expect(coordinator.isPushToTalkActive)
        #expect(capture.isCapturing)

        // Duplicate key down is idempotent
        await coordinator.beginPushToTalk()
        #expect(coordinator.state == .listening)
        #expect(coordinator.isPushToTalkActive)

        // Key up ends PTT and terminates PTT-started session
        await coordinator.endPushToTalk()
        #expect(!coordinator.isPushToTalkActive)
        #expect(coordinator.state == .idle)
        #expect(!capture.isCapturing)
        #expect(!session.isConnected)

        // Duplicate key up is safe
        await coordinator.endPushToTalk()
        #expect(!coordinator.isPushToTalkActive)
        #expect(coordinator.state == .idle)
    }

    @Test("13. Kore regression: Live voice name remains strictly configured as Kore")
    func testLiveVoiceNameIsKore() {
        #expect(GeminiLiveClient.liveVoiceName == "Kore")
        #expect(GeminiLiveVoiceCoordinator.liveVoiceName == "Kore")

        let client = GeminiLiveClient(apiKey: "key")
        #expect(client.voiceName == "Kore")
    }

    @Test("14. TCC safety: SystemWakeWordDetector returns false safely without crashing outside .app bundle")
    func testSystemWakeWordDetectorUnbundledPermissionSafety() async {
        let detector = SystemWakeWordDetector()
        let result = await detector.requestPermission()
        #expect(result == false)
    }

    @Test("15. Coordinator startup with SystemWakeWordDetector does not crash and reaches listening state")
    func testCoordinatorStartupWithSystemWakeWordDetector() async {
        let session = MockGeminiLiveSession()
        let capture = MockAudioCapture(isPermissionGranted: true)
        let player = MockLiveAudioPlayer()
        let detector = SystemWakeWordDetector()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: session,
            audioCapture: capture,
            audioPlayer: player,
            wakeWordDetector: detector
        )

        await coordinator.startSession()
        #expect(coordinator.state == .listening)
        #expect(session.isConnected)
        #expect(capture.isCapturing)

        await coordinator.stopSession()
        #expect(coordinator.state == .idle)
    }

    @Test("16. Gemini Live API schema: BidiRealtimeInput serializes 16kHz PCM as audio only, never alongside mediaChunks")
    func testBidiRealtimeInputAudioOnlySchema() throws {
        let pcmData = Data([0x01, 0x02, 0x03, 0x04])
        let input = BidiRealtimeInput(pcmData: pcmData, sampleRate: 16000)
        let clientMessage = BidiClientMessage(realtimeInput: input)

        let encoded = try JSONEncoder().encode(clientMessage)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let realtimeDict = try #require(json["realtimeInput"] as? [String: Any])

        #expect(Set(realtimeDict.keys) == ["audio"])
        let audio = try #require(realtimeDict["audio"] as? [String: Any])
        #expect(audio["mimeType"] as? String == "audio/pcm;rate=16000")
        #expect(audio["data"] as? String == pcmData.base64EncodedString())
    }

    @Test("17. Audio pipeline: coordinator in .listening streams audio chunks to Gemini Live")
    func testCoordinatorStreamsAudioChunksInListening() async throws {
        let (coordinator, session, capture, _, _, _) = createTestCoordinator()

        await coordinator.startSession()
        #expect(coordinator.state == .listening)

        let chunk = Data([0xDE, 0xAD, 0xBE, 0xEF])
        capture.simulateAudioChunk(chunk)

        let streamed = await waitForCondition {
            session.sentAudioChunks.contains(chunk)
        }
        #expect(streamed)
        #expect(session.sentAudioChunks == [chunk])

        await coordinator.stopSession()
    }

    @Test("18. Playback pipeline: coordinator plays 24kHz audio chunks and handles turnComplete")
    func testCoordinatorPlaysAudioAndDrainsQueue() async throws {
        let (coordinator, session, _, player, _, _) = createTestCoordinator(player: MockLiveAudioPlayer(autoDrain: true))

        await coordinator.startSession()
        #expect(coordinator.state == .listening)

        let responseAudio = Data([0xCA, 0xFE, 0xBA, 0xBE])
        session.simulateEvent(.audioChunk(responseAudio))

        let isSpeaking = await waitForCondition {
            coordinator.state == .speaking
        }
        #expect(isSpeaking)
        #expect(player.playedChunks == [responseAudio])

        session.simulateEvent(.turnComplete)
        let returnedToListening = await waitForCondition {
            coordinator.state == .listening
        }
        #expect(returnedToListening)

        await coordinator.stopSession()
    }
}
