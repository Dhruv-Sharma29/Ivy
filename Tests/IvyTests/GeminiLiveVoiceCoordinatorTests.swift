import Testing
import Foundation
@testable import IvyCore

@Suite("Phase 4B - GeminiLiveVoiceCoordinator Tests")
@MainActor
struct GeminiLiveVoiceCoordinatorTests {

    @Test("Voice coordinator initializes in idle state")
    func testInitialState() {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture()
        let mockPlayer = MockLiveAudioPlayer()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer
        )

        #expect(coordinator.state == .idle)
        #expect(!coordinator.state.isLive)
        #expect(coordinator.latestTranscript.isEmpty)
    }

    @Test("startSession connects session, starts capture, and reaches listening state")
    func testStartSessionSuccess() async throws {
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
        #expect(coordinator.state.isLive)
        #expect(mockSession.isConnected)
        #expect(mockCapture.isCapturing)

        await coordinator.stopSession()
        #expect(coordinator.state == .idle)
        #expect(!mockSession.isConnected)
        #expect(!mockCapture.isCapturing)
    }

    @Test("startSession fails when microphone permission is denied")
    func testPermissionDenied() async {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: false)
        let mockPlayer = MockLiveAudioPlayer()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer
        )

        await coordinator.startSession()

        guard case .error(let msg) = coordinator.state else {
            Issue.record("Expected error state on permission denial")
            return
        }
        #expect(msg.contains("Microphone"))
        #expect(!mockSession.isConnected)
        #expect(!mockCapture.isCapturing)
    }

    @Test("startSession handles connection error cleanly")
    func testConnectionError() async {
        let mockSession = MockGeminiLiveSession(connectError: LiveError.connectionFailed("Host unreachable"))
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer
        )

        await coordinator.startSession()

        guard case .error(let msg) = coordinator.state else {
            Issue.record("Expected error state on connection failure")
            return
        }
        #expect(msg.contains("Host unreachable"))
        #expect(!mockSession.isConnected)
        #expect(!mockCapture.isCapturing)
    }

    @Test("Captured audio chunks are forwarded to session")
    func testAudioStreamingForwarding() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer
        )

        await coordinator.startSession()

        let chunk1 = Data([0x01, 0x02, 0x03])
        let chunk2 = Data([0x04, 0x05, 0x06])
        mockCapture.simulateAudioChunk(chunk1)
        mockCapture.simulateAudioChunk(chunk2)

        // Wait briefly for async capture task to forward
        for _ in 0..<50 {
            if mockSession.sentAudioChunks.count == 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(mockSession.sentAudioChunks == [chunk1, chunk2])

        await coordinator.stopSession()
    }

    @Test("Incoming audio chunk transitions to speaking and plays audio")
    func testIncomingAudioPlayback() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer
        )

        await coordinator.startSession()

        let audio = Data([0xAA, 0xBB, 0xCC])
        mockSession.simulateEvent(.audioChunk(audio))

        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .speaking)
        #expect(mockPlayer.playedChunks == [audio])

        // When turn completes, returns to listening
        mockSession.simulateEvent(.turnComplete)

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .listening)

        await coordinator.stopSession()
    }

    @Test("Text turns update latestTranscript")
    func testTranscriptUpdates() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer
        )

        await coordinator.startSession()

        mockSession.simulateEvent(.textTurn("I hear you loud and clear."))

        for _ in 0..<50 {
            if coordinator.latestTranscript == "I hear you loud and clear." { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.latestTranscript == "I hear you loud and clear.")

        await coordinator.stopSession()
    }

    @Test("User speaking during playback interrupts playback immediately")
    func testUserInterruption() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer
        )

        await coordinator.startSession()

        // Ivy begins speaking
        mockSession.simulateEvent(.audioChunk(Data([0x11, 0x22])))

        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)

        // User speaks (mic captures audio)
        mockCapture.simulateAudioChunk(Data([0x33, 0x44]))

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .listening)
        #expect(mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("Server-side interrupted event stops playback and resumes listening")
    func testServerInterruption() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer
        )

        await coordinator.startSession()

        // Ivy begins speaking
        mockSession.simulateEvent(.audioChunk(Data([0x11, 0x22])))

        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)

        // Server sends interrupted event
        mockSession.simulateEvent(.interrupted)

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .listening)
        #expect(mockPlayer.isStopped)

        await coordinator.stopSession()
    }
}
