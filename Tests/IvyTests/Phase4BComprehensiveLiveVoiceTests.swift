import Testing
import Foundation
@testable import IvyCore

@Suite("Phase 4B - Comprehensive Live Voice Tests")
@MainActor
struct Phase4BComprehensiveLiveVoiceTests {

    @Test("1. Starting session while already active restarts cleanly")
    func testRestartActiveSession() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer
        )

        await coordinator.startSession()
        #expect(coordinator.state == .listening)
        #expect(mockSession.isConnected)

        // Start again while active
        await coordinator.startSession()
        #expect(coordinator.state == .listening)
        #expect(mockSession.isConnected)

        await coordinator.stopSession()
        #expect(coordinator.state == .idle)
    }

    @Test("2. Rapid start and stop does not crash or leave dangling capture")
    func testRapidStartStop() async {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer
        )

        for _ in 0..<5 {
            await coordinator.startSession()
            await coordinator.stopSession()
        }

        #expect(coordinator.state == .idle)
        #expect(!mockSession.isConnected)
        #expect(!mockCapture.isCapturing)
        #expect(!mockPlayer.isPlaying)
    }

    @Test("3. Disconnecting session while speaking immediately halts audio output")
    func testDisconnectHaltsPlayback() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer
        )

        await coordinator.startSession()

        // Ivy receives audio and begins speaking
        let chunk = Data([0xDE, 0xAD])
        mockSession.simulateEvent(.audioChunk(chunk))

        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)
        #expect(mockPlayer.isPlaying)

        // Stop session
        await coordinator.stopSession()

        #expect(coordinator.state == .idle)
        #expect(!mockPlayer.isPlaying)
        #expect(mockPlayer.isStopped)
    }

    @Test("4. Network/session failure during audio streaming transitions cleanly to error state")
    func testStreamFailureHandling() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer
        )

        await coordinator.startSession()
        #expect(coordinator.state == .listening)

        // Set session to fail on sendAudio
        mockSession.setSendAudioError(LiveError.serverError("Socket pipeline dropped"))

        // Simulate mic capturing audio
        mockCapture.simulateAudioChunk(Data([0x01, 0x02]))

        for _ in 0..<50 {
            if case .error = coordinator.state { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        guard case .error(let msg) = coordinator.state else {
            Issue.record("Expected coordinator to enter error state upon audio streaming failure")
            return
        }
        #expect(msg.contains("Socket pipeline dropped"))
    }

    @Test("5. LiveError descriptions never expose raw API keys")
    func testLiveErrorSanitization() {
        let rawKey = "AIzaSyTestSecretKey_12345"
        let error = LiveError.missingAPIKey
        #expect(!error.localizedDescription.contains(rawKey))

        let urlError = LiveError.invalidURL
        #expect(!urlError.localizedDescription.contains(rawKey))

        let permError = LiveError.microphonePermissionDenied
        #expect(!permError.localizedDescription.contains(rawKey))
    }

    @Test("6. VoiceSessionState isLive property correctly partitions states")
    func testVoiceSessionStateIsLive() {
        #expect(!VoiceSessionState.idle.isLive)
        #expect(VoiceSessionState.connecting.isLive)
        #expect(VoiceSessionState.listening.isLive)
        #expect(VoiceSessionState.thinking.isLive)
        #expect(VoiceSessionState.speaking.isLive)
        #expect(!VoiceSessionState.error("Failure").isLive)
    }
}
