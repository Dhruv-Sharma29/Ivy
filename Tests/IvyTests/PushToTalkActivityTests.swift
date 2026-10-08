import Foundation
import os
import Testing
@testable import IvyCore

@Suite("Push-to-talk submits explicit Live audio activity")
@MainActor
struct PushToTalkActivityTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition())
    }

    private func messages(_ transport: MockWebSocketTransport) throws -> [BidiClientMessage] {
        try transport.sentMessages.compactMap { message in
            guard case .string(let json) = message else { return nil }
            return try JSONDecoder().decode(BidiClientMessage.self, from: Data(json.utf8))
        }
    }

    @Test("PTT sends start before speech, then one end; it never sends automatic-VAD flush")
    func manualActivityBoundaries() async throws {
        let transport = MockWebSocketTransport()
        let client = GeminiLiveClient(apiKey: "fixture", silenceDurationMs: 1500, webSocketFactory: { _ in transport })
        try client.configurePushToTalkInput(true)
        try await client.connect()
        transport.enqueueReceiveString("{\"setupComplete\":{}}")
        try await waitUntil { client.isConnected }
        let setup = try #require(messages(transport).first?.setup)
        #expect(setup.realtimeInputConfig?.automaticActivityDetection.disabled == true)
        #expect(setup.realtimeInputConfig?.automaticActivityDetection.silenceDurationMs == nil)
        try await client.endAudioInput() // No speech started: no fake turn.
        #expect(transport.sentMessages.count == 1)
        try await client.sendAudio(Data([1, 2]))
        try await client.sendAudio(Data([3, 4]))
        try await client.endAudioInput()
        try await client.endAudioInput()
        let inputs = try messages(transport).compactMap(\.realtimeInput)
        #expect(inputs.count == 4)
        #expect(inputs[0].activityStart != nil && inputs[0].audio == nil)
        #expect(inputs[1].audio?.data == Data([1, 2]).base64EncodedString())
        #expect(inputs[2].audio?.data == Data([3, 4]).base64EncodedString())
        #expect(inputs[3].activityEnd != nil && inputs[3].audio == nil)
        #expect(inputs.allSatisfy { $0.audioStreamEnd == nil })
        #expect(throws: LiveError.self) { try client.configurePushToTalkInput(false) }
        await client.disconnect()
    }

    @Test("Automatic input keeps its existing setup/flush and can follow a PTT connection")
    func automaticInputAfterManualSession() async throws {
        let previous = MockWebSocketTransport()
        let transport = MockWebSocketTransport()
        let index = OSAllocatedUnfairLock(initialState: 0)
        let client = GeminiLiveClient(apiKey: "fixture", silenceDurationMs: 800, webSocketFactory: { _ in
            index.withLock { number in
                defer { number += 1 }
                return number == 0 ? previous : transport
            }
        })
        try client.configurePushToTalkInput(true)
        try await client.connect()
        await client.disconnect()
        try client.configurePushToTalkInput(false)
        try await client.connect()
        transport.enqueueReceiveString("{\"setupComplete\":{}}")
        try await waitUntil { client.isConnected }
        let setup = try #require(messages(transport).compactMap(\.setup).last)
        #expect(setup.realtimeInputConfig?.automaticActivityDetection.disabled == nil)
        #expect(setup.realtimeInputConfig?.automaticActivityDetection.silenceDurationMs == 800)
        try await client.sendAudio(Data([1, 2]))
        try await client.endAudioInput()
        let inputs = try messages(transport).compactMap(\.realtimeInput)
        #expect(inputs.count == 2)
        #expect(inputs[0].audio != nil && inputs[0].activityStart == nil)
        #expect(inputs[1].audioStreamEnd == true && inputs[1].activityEnd == nil)
        await client.disconnect()
    }

    @Test("Reconnect retains manual mode and starts a fresh audio activity")
    func reconnectManualInput() async throws {
        let transports = [MockWebSocketTransport(), MockWebSocketTransport()]
        let index = OSAllocatedUnfairLock(initialState: 0)
        let client = GeminiLiveClient(apiKey: "fixture", webSocketFactory: { _ in
            index.withLock { number in
                defer { number += 1 }
                return transports[number]
            }
        })
        try client.configurePushToTalkInput(true)
        for transport in transports {
            try await client.connect()
            transport.enqueueReceiveString("{\"setupComplete\":{}}")
            try await waitUntil { client.isConnected }
            try await client.sendAudio(Data([1, 2]))
        }
        let sent = try transports.flatMap { try messages($0) }
        #expect(sent.compactMap(\.setup).count == 2)
        #expect(sent.compactMap(\.setup).allSatisfy { $0.realtimeInputConfig?.automaticActivityDetection.disabled == true })
        #expect(sent.compactMap(\.realtimeInput).filter { $0.activityStart != nil }.count == 2)
        await client.disconnect()
    }

    @Test("Marker transport errors surface without replay", arguments: [true, false])
    func markerFailure(start: Bool) async throws {
        let transport = MockWebSocketTransport()
        let client = GeminiLiveClient(apiKey: "fixture", webSocketFactory: { _ in transport })
        try client.configurePushToTalkInput(true)
        try await client.connect()
        transport.enqueueReceiveString("{\"setupComplete\":{}}")
        try await waitUntil { client.isConnected }
        if !start { try await client.sendAudio(Data([1, 2])) }
        transport.setSendError(LiveError.sessionClosed)
        await #expect(throws: LiveError.self) {
            if start { try await client.sendAudio(Data([3, 4])) }
            else { try await client.endAudioInput() }
        }
        #expect(transport.sentMessages.count == (start ? 1 : 3))
        await client.disconnect()
    }

    @Test("Coordinator selects PTT mode before setup and releases capture before submitting")
    func coordinatorUsesManualActivity() async throws {
        let transport = MockWebSocketTransport()
        let client = GeminiLiveClient(apiKey: "fixture", webSocketFactory: { _ in transport })
        let capture = MockAudioCapture()
        let coordinator = GeminiLiveVoiceCoordinator(session: client, audioCapture: capture,
            audioPlayer: MockLiveAudioPlayer(), wakeWordDetector: MockWakeWordDetector())
        await coordinator.beginPushToTalk()
        transport.enqueueReceiveString("{\"setupComplete\":{}}")
        try await waitUntil { client.isConnected && coordinator.state == .listening }
        let loud = Data(repeating: 0x30, count: 3200)
        capture.simulateAudioChunk(loud)
        try await waitUntil { transport.sentMessages.count == 3 }
        await coordinator.endPushToTalk()
        #expect(!capture.isCapturing && coordinator.state == .thinking)
        #expect(try messages(transport).last?.realtimeInput?.activityEnd != nil)
        #expect(try messages(transport).first?.setup?.realtimeInputConfig?.automaticActivityDetection.disabled == true)
        await coordinator.shutdown()
    }

    @Test("Input-mode setup failure cleans up without opening the microphone")
    func coordinatorInputModeFailure() async throws {
        let transport = MockWebSocketTransport()
        let client = GeminiLiveClient(apiKey: "fixture", webSocketFactory: { _ in transport })
        try await client.connect()
        let capture = MockAudioCapture()
        let coordinator = GeminiLiveVoiceCoordinator(session: client, audioCapture: capture,
            audioPlayer: MockLiveAudioPlayer(), wakeWordDetector: MockWakeWordDetector())
        await coordinator.beginPushToTalk()
        guard case .error(let message) = coordinator.state else {
            Issue.record("Input-mode failure must be visible")
            await coordinator.shutdown()
            return
        }
        #expect(message.contains("Couldn't configure voice input"))
        #expect(capture.startCaptureCallCount == 0 && !client.isConnected)
        await coordinator.shutdown()
    }
}
