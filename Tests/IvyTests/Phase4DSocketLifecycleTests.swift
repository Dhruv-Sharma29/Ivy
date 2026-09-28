import Testing
import Foundation
import os
@testable import IvyCore

@Suite("Phase 4D Live Socket Lifecycle Tests")
@MainActor
struct Phase4DSocketLifecycleTests {

    private static let setupComplete = "{\"setupComplete\":{}}"
    private static let audioTurn = "{\"serverContent\":{\"modelTurn\":{\"parts\":[{\"inlineData\":{\"mimeType\":\"audio/pcm;rate=24000\",\"data\":\"AAEC\"}}]},\"turnComplete\":true}}"
    private static let socketLost = LiveError.connectionFailed("Socket is not connected")

    private func makeClient() -> (GeminiLiveClient, OSAllocatedUnfairLock<[MockWebSocketTransport]>) {
        let transports = OSAllocatedUnfairLock(initialState: [MockWebSocketTransport]())
        let client = GeminiLiveClient(apiKey: "test-key", webSocketFactory: { _ in
            let t = MockWebSocketTransport()
            transports.withLock { $0.append(t) }
            return t
        })
        return (client, transports)
    }

    private func makeCoordinator(
        client: GeminiLiveClient,
        capture: MockAudioCapture,
        player: MockLiveAudioPlayer = MockLiveAudioPlayer(autoDrain: false),
        hotkey: MockGlobalHotkeyManager? = nil
    ) -> GeminiLiveVoiceCoordinator {
        GeminiLiveVoiceCoordinator(
            session: client,
            audioCapture: capture,
            audioPlayer: player,
            wakeWordDetector: MockWakeWordDetector(),
            hotkeyManager: hotkey
        )
    }

    private func waitFor(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    private func collect(_ stream: AsyncThrowingStream<LiveEvent, Error>) -> (OSAllocatedUnfairLock<[LiveEvent]>, OSAllocatedUnfairLock<Error?>) {
        let events = OSAllocatedUnfairLock(initialState: [LiveEvent]())
        let failure = OSAllocatedUnfairLock<Error?>(initialState: nil)
        Task {
            do {
                for try await e in stream { events.withLock { $0.append(e) } }
            } catch {
                failure.withLock { $0 = error }
            }
        }
        return (events, failure)
    }

    private func sentStrings(_ t: MockWebSocketTransport) -> [String] {
        t.sentMessages.compactMap { if case .string(let s) = $0 { return s } else { return nil } }
    }

    // MARK: - Client socket lifecycle

    @Test("Receive loop survives setupComplete and keeps delivering serverContent on one loop")
    func testReceiveLoopSurvivesSetupComplete() async throws {
        let (client, transports) = makeClient()
        let (events, failure) = collect(client.receiveEvents())
        try await client.connect()
        let ws = try #require(transports.withLock { $0.first })

        ws.enqueueReceiveString(Self.setupComplete)
        #expect(await waitFor { client.isConnected })

        ws.enqueueReceiveString(Self.audioTurn)
        #expect(await waitFor { events.withLock { $0.contains(.turnComplete) } })

        let received = events.withLock { $0 }
        #expect(received.contains(.connected))
        #expect(received.contains(.audioChunk(Data([0x00, 0x01, 0x02]))))
        #expect(client.isConnected)
        #expect(!ws.isCancelled)
        #expect(failure.withLock { $0 } == nil)
        #expect(ws.maxConcurrentReceives == 1)
    }

    @Test("Current connection failure finishes the event stream with an error and invalidates the connection")
    func testCurrentFailureSurfacesError() async throws {
        let (client, transports) = makeClient()
        let (events, failure) = collect(client.receiveEvents())
        try await client.connect()
        let ws = try #require(transports.withLock { $0.first })
        ws.enqueueReceiveString(Self.setupComplete)
        #expect(await waitFor { client.isConnected })

        ws.enqueueReceiveError(Self.socketLost)

        #expect(await waitFor { failure.withLock { $0 } != nil })
        let message = failure.withLock { $0?.localizedDescription } ?? ""
        #expect(message.contains("Socket is not connected"))
        #expect(!events.withLock { $0.contains(.disconnected) })
        #expect(!client.isConnected)
        #expect(client.connectionId == nil)
        await #expect(throws: LiveError.sessionClosed) {
            try await client.sendAudio(Data([0x01]))
        }
    }

    @Test("Stale receive error cannot close, disconnect, or reconnect the current connection")
    func testStaleFailureCannotTouchCurrentConnection() async throws {
        let (client, transports) = makeClient()
        try await client.connect()
        let old = try #require(transports.withLock { $0.first })
        old.enqueueReceiveString(Self.setupComplete)
        #expect(await waitFor { client.isConnected })
        let oldId = client.connectionId

        try await client.connect()
        let current = try #require(transports.withLock { $0.last })
        let (events, failure) = collect(client.receiveEvents())
        current.enqueueReceiveString(Self.setupComplete)
        #expect(await waitFor { client.isConnected })
        let currentId = client.connectionId

        old.enqueueReceiveError(Self.socketLost)
        old.enqueueReceiveString(Self.audioTurn)
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(oldId != nil && currentId != nil && oldId != currentId)
        #expect(client.connectionId == currentId)
        #expect(client.isConnected)
        #expect(!current.isCancelled)
        #expect(transports.withLock { $0.count } == 2)
        #expect(failure.withLock { $0 } == nil)
        #expect(!events.withLock { $0.contains(.turnComplete) })

        current.enqueueReceiveString(Self.audioTurn)
        #expect(await waitFor { events.withLock { $0.contains(.turnComplete) } })
        #expect(current.maxConcurrentReceives == 1)
    }

    @Test("sendAudio after reconnect uses the current socket and sends the audio field only")
    func testSendAudioUsesCurrentSocket() async throws {
        let (client, transports) = makeClient()
        try await client.connect()
        let old = try #require(transports.withLock { $0.first })
        old.enqueueReceiveString(Self.setupComplete)
        #expect(await waitFor { client.isConnected })

        try await client.connect()
        let current = try #require(transports.withLock { $0.last })
        current.enqueueReceiveString(Self.setupComplete)
        #expect(await waitFor { client.isConnected })
        let oldSent = old.sentMessages.count

        try await client.sendAudio(Data([0x01, 0x02]))

        #expect(old.sentMessages.count == oldSent)
        let frame = try #require(sentStrings(current).last)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
        let input = try #require(json["realtimeInput"] as? [String: Any])
        #expect(Set(input.keys) == ["audio"])
    }

    @Test("Reconnect creates a new connection ID and disconnect clears it")
    func testReconnectCreatesNewConnectionId() async throws {
        let (client, _) = makeClient()
        try await client.connect()
        let first = client.connectionId
        try await client.connect()
        let second = client.connectionId
        #expect(first != nil && second != nil && first != second)
        await client.disconnect()
        #expect(client.connectionId == nil)
    }

    // MARK: - Coordinator cleanup on current-session failure

    @Test("Current socket failure stops the microphone, playback, and leaves a stable error state")
    func testSocketFailureStopsMicrophone() async throws {
        let (client, transports) = makeClient()
        let capture = MockAudioCapture(isPermissionGranted: true)
        let player = MockLiveAudioPlayer(autoDrain: false)
        let coordinator = makeCoordinator(client: client, capture: capture, player: player)

        await coordinator.startSession()
        let ws = try #require(transports.withLock { $0.first })
        ws.enqueueReceiveString(Self.setupComplete)
        #expect(await waitFor { client.isConnected && coordinator.state == .listening })
        #expect(capture.isCapturing)

        ws.enqueueReceiveError(Self.socketLost)

        #expect(await waitFor { !coordinator.state.isLive })
        #expect(await waitFor { !capture.isCapturing })
        guard case .error(let msg) = coordinator.state else {
            Issue.record("Expected error state after socket failure, got \(coordinator.state)")
            return
        }
        #expect(msg.contains("Socket is not connected"))
        #expect(capture.stopCaptureCallCount >= 1)
        #expect(player.isStopped)
        #expect(transports.withLock { $0.count } == 1)
    }

    @Test("Unexpected .disconnected event for the current session stops the microphone")
    func testUnexpectedDisconnectStopsMicrophone() async {
        let session = MockGeminiLiveSession()
        let capture = MockAudioCapture(isPermissionGranted: true)
        let coordinator = GeminiLiveVoiceCoordinator(
            session: session,
            audioCapture: capture,
            audioPlayer: MockLiveAudioPlayer(autoDrain: false),
            wakeWordDetector: MockWakeWordDetector()
        )
        await coordinator.startSession()
        #expect(await waitFor { coordinator.state == .listening })

        session.simulateEvent(.disconnected)

        #expect(await waitFor { !coordinator.state.isLive && !capture.isCapturing })
        capture.simulateAudioChunk(Data([0x09]))
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(session.sentAudioChunks.isEmpty)
    }

    @Test("Restart after failure creates exactly one new connection, streams each chunk once, and keeps Kore")
    func testRestartAfterFailure() async throws {
        let (client, transports) = makeClient()
        let capture = MockAudioCapture(isPermissionGranted: true)
        let coordinator = makeCoordinator(client: client, capture: capture)

        await coordinator.startSession()
        let first = try #require(transports.withLock { $0.first })
        first.enqueueReceiveString(Self.setupComplete)
        #expect(await waitFor { client.isConnected })
        first.enqueueReceiveError(Self.socketLost)
        #expect(await waitFor { !coordinator.state.isLive && !capture.isCapturing })

        await coordinator.startSession()
        #expect(transports.withLock { $0.count } == 2)
        let second = try #require(transports.withLock { $0.last })
        second.enqueueReceiveString(Self.setupComplete)
        #expect(await waitFor { client.isConnected && coordinator.state == .listening })
        #expect(capture.startCaptureCallCount == 2)

        let firstSent = first.sentMessages.count
        capture.simulateAudioChunk(Data([0x0A, 0x0B]))
        #expect(await waitFor { sentStrings(second).count == 2 })
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(sentStrings(second).count == 2)
        #expect(first.sentMessages.count == firstSent)
        #expect(sentStrings(second).first?.contains("\"Kore\"") == true)

        await coordinator.stopSession()
        #expect(!capture.isCapturing)
    }

    @Test("PTT key repeat around a socket failure never creates duplicate connections")
    func testPTTRepeatAroundFailureIsIdempotent() async throws {
        let (client, transports) = makeClient()
        let capture = MockAudioCapture(isPermissionGranted: true)
        let hotkey = MockGlobalHotkeyManager()
        let coordinator = makeCoordinator(client: client, capture: capture, hotkey: hotkey)
        try coordinator.registerHotkey()

        for _ in 0..<5 { hotkey.simulateKeyDown() }
        #expect(await waitFor { transports.withLock { $0.count } == 1 })
        let first = try #require(transports.withLock { $0.first })
        first.enqueueReceiveString(Self.setupComplete)
        #expect(await waitFor { client.isConnected && coordinator.state == .listening })

        first.enqueueReceiveError(Self.socketLost)
        #expect(await waitFor { !coordinator.state.isLive && !capture.isCapturing })
        for _ in 0..<5 { hotkey.simulateKeyDown() }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(transports.withLock { $0.count } == 1)

        hotkey.simulateKeyUp()
        #expect(await waitFor { !coordinator.isPushToTalkActive })
        for _ in 0..<5 { hotkey.simulateKeyDown() }
        #expect(await waitFor { transports.withLock { $0.count } == 2 })
        let second = try #require(transports.withLock { $0.last })
        second.enqueueReceiveString(Self.setupComplete)
        #expect(await waitFor { client.isConnected && coordinator.state == .listening })
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(transports.withLock { $0.count } == 2)

        await coordinator.shutdown()
        #expect(!capture.isCapturing)
    }
}
