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
        #expect(VoiceSessionState.interrupting.isLive)
        #expect(!VoiceSessionState.error("Failure").isLive)
    }

    @Test("7. Multi-chunk response waits for audio queue drain before returning to listening")
    func testMultiChunkQueueDraining() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockDetector = MockWakeWordDetector()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            wakeWordDetector: mockDetector
        )

        await coordinator.startSession()
        #expect(coordinator.state == .listening)

        // Model delivers 3 audio chunks
        let c1 = Data([0x01, 0x02])
        let c2 = Data([0x03, 0x04])
        let c3 = Data([0x05, 0x06])

        mockSession.simulateEvent(.audioChunk(c1))
        mockSession.simulateEvent(.audioChunk(c2))
        mockSession.simulateEvent(.audioChunk(c3))

        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)
        #expect(mockPlayer.playedChunks.count == 3)

        // Gemini Live finishes generating tokens and signals turnComplete
        mockSession.simulateEvent(.turnComplete)
        try await Task.sleep(nanoseconds: 50_000_000)

        // Playback has NOT finished yet: state must REMAIN .speaking
        #expect(coordinator.state == .speaking)

        // Now audio hardware finishes playing queued buffers
        mockPlayer.finishPlayback()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .listening)
        await coordinator.stopSession()
    }

    @Test("8. Normal user speech during playback is not forwarded to Gemini Live and does not interrupt")
    func testNormalSpeechRejectionDuringPlayback() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockDetector = MockWakeWordDetector(shouldTrigger: false)

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            wakeWordDetector: mockDetector
        )

        await coordinator.startSession()

        // Ivy starts speaking
        mockSession.simulateEvent(.audioChunk(Data([0xAA, 0xBB])))
        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)

        // Clear any sent audio chunks before speaking
        let initialSentCount = mockSession.sentAudioChunks.count

        // User speaks normal words (captured by mic)
        mockCapture.simulateAudioChunk(Data([0x11, 0x22]))
        mockCapture.simulateAudioChunk(Data([0x33, 0x44]))
        try await Task.sleep(nanoseconds: 50_000_000)

        // Audio must NOT be sent to Gemini Live (to prevent server VAD barge-in)
        #expect(mockSession.sentAudioChunks.count == initialSentCount)
        // Detector processed the chunks
        #expect(mockDetector.processedChunksCount == 2)
        // Ivy continues speaking uninterrupted
        #expect(coordinator.state == .speaking)
        #expect(!mockPlayer.isStopped)

        // Also test transcription fallback with non-wake words
        await coordinator.processTranscriptionForInterruption("Yeah I understand")
        #expect(coordinator.state == .speaking)
        #expect(!mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("9. Wake phrase 'Hey Ivy' halts playback immediately and resets detector")
    func testWakePhraseInterruption() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockDetector = MockWakeWordDetector(shouldTrigger: false)

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            wakeWordDetector: mockDetector
        )

        await coordinator.startSession()

        // Ivy starts speaking
        mockSession.simulateEvent(.audioChunk(Data([0x12, 0x34])))
        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)

        // User says "Hey Ivy" via mic
        mockDetector.setShouldTrigger(true)
        mockCapture.simulateAudioChunk(Data([0x56, 0x78]))

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .listening)
        #expect(mockPlayer.isStopped)
        #expect(mockDetector.isReset)

        await coordinator.stopSession()
    }

    @Test("10. After interruption, new request audio is forwarded and new response plays")
    func testNewRequestHandlingAfterInterruption() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: true)
        let mockDetector = MockWakeWordDetector(shouldTrigger: false)

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            wakeWordDetector: mockDetector
        )

        await coordinator.startSession()

        // 1. Initial answer
        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // 2. Interruption via transcript "Hey Ivy"
        await coordinator.processTranscriptionForInterruption("Hey Ivy")
        #expect(coordinator.state == .listening)
        #expect(mockPlayer.isStopped)

        // 3. User says new request
        let newRequestChunk = Data([0x99, 0x88])
        mockCapture.simulateAudioChunk(newRequestChunk)

        for _ in 0..<50 {
            if mockSession.sentAudioChunks.contains(newRequestChunk) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(mockSession.sentAudioChunks.contains(newRequestChunk))

        // 4. Gemini Live replies to new request
        let newResponseChunk = Data([0x77, 0x66])
        mockSession.simulateEvent(.audioChunk(newResponseChunk))

        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)
        #expect(mockPlayer.playedChunks.contains(newResponseChunk))

        await coordinator.stopSession()
    }

    @Test("11. Disconnecting or stopping while draining cancels drainTask cleanly")
    func testStopWhileDraining() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer
        )

        await coordinator.startSession()

        mockSession.simulateEvent(.audioChunk(Data([0x11, 0x22])))
        mockSession.simulateEvent(.turnComplete)

        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)

        // Stop while waiting for drain
        await coordinator.stopSession()

        #expect(coordinator.state == .idle)
        #expect(mockPlayer.isStopped)
    }
}

