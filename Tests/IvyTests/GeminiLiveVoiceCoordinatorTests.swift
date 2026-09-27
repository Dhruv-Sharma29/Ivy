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

    @Test("Normal speech does not interrupt playback; only wake phrase interrupts")
    func testUserInterruption() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer()
        let mockDetector = MockWakeWordDetector(shouldTrigger: false)

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            wakeWordDetector: mockDetector
        )

        await coordinator.startSession()

        // Ivy begins speaking
        mockSession.simulateEvent(.audioChunk(Data([0x11, 0x22])))

        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)

        // Normal user speech (mic captures audio, but no wake phrase)
        mockCapture.simulateAudioChunk(Data([0x33, 0x44]))
        try await Task.sleep(nanoseconds: 50_000_000)

        // Ivy must still be speaking!
        #expect(coordinator.state == .speaking)
        #expect(!mockPlayer.isStopped)

        // User says "Hey Ivy" (wake detector triggers)
        mockDetector.setShouldTrigger(true)
        mockCapture.simulateAudioChunk(Data([0x55, 0x66]))

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

    @Test("detector receives audio continuously while .speaking")
    func testDetectorReceivesAudioWhileSpeaking() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer()
        let mockDetector = MockWakeWordDetector(shouldTrigger: false)

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            wakeWordDetector: mockDetector
        )

        await coordinator.startSession()
        #expect(coordinator.state == .listening)

        // Ivy begins speaking
        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)

        let initialCount = mockDetector.processedChunksCount
        mockCapture.simulateAudioChunk(Data([0xAA, 0xBB]))
        mockCapture.simulateAudioChunk(Data([0xCC, 0xDD]))

        for _ in 0..<50 {
            if mockDetector.processedChunksCount == initialCount + 2 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(mockDetector.processedChunksCount == initialCount + 2)
        #expect(coordinator.state == .speaking)

        await coordinator.stopSession()
    }

    @Test("Speech recognition producing 'Hey Ivy', 'Hey, Ivy', and 'hey ivy' triggers interruption")
    func testHeyIvyVariationsTriggerInterruption() async throws {
        let phrases = ["Hey Ivy", "Hey, Ivy", "hey ivy"]

        for phrase in phrases {
            let mockSession = MockGeminiLiveSession()
            let mockCapture = MockAudioCapture(isPermissionGranted: true)
            let mockPlayer = MockLiveAudioPlayer()
            let mockDetector = MockWakeWordDetector()

            let coordinator = GeminiLiveVoiceCoordinator(
                session: mockSession,
                audioCapture: mockCapture,
                audioPlayer: mockPlayer,
                wakeWordDetector: mockDetector
            )

            await coordinator.startSession()

            // Ivy begins speaking
            mockSession.simulateEvent(.audioChunk(Data([0x10, 0x20])))
            for _ in 0..<50 {
                if coordinator.state == .speaking { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(coordinator.state == .speaking)

            // Live speech recognizer emits transcription with wake phrase
            mockDetector.simulateTranscription(phrase)

            for _ in 0..<50 {
                if coordinator.state == .listening { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            #expect(coordinator.state == .listening)
            #expect(mockPlayer.isStopped)

            await coordinator.stopSession()
        }
    }

    @Test("Speech recognition producing 'Hey everyone' or 'Ivy is a good assistant' does NOT trigger")
    func testNonWakeSpeechDoesNotTrigger() async throws {
        let nonWakePhrases = ["Hey everyone", "Ivy is a good assistant", "Wait, that's not what I meant", "Yeah, okay"]

        for phrase in nonWakePhrases {
            let mockSession = MockGeminiLiveSession()
            let mockCapture = MockAudioCapture(isPermissionGranted: true)
            let mockPlayer = MockLiveAudioPlayer()
            let mockDetector = MockWakeWordDetector()

            let coordinator = GeminiLiveVoiceCoordinator(
                session: mockSession,
                audioCapture: mockCapture,
                audioPlayer: mockPlayer,
                wakeWordDetector: mockDetector
            )

            await coordinator.startSession()

            // Ivy begins speaking
            mockSession.simulateEvent(.audioChunk(Data([0x10, 0x20])))
            for _ in 0..<50 {
                if coordinator.state == .speaking { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(coordinator.state == .speaking)

            // Live speech recognizer emits non-wake transcript
            mockDetector.simulateTranscription(phrase)
            try await Task.sleep(nanoseconds: 40_000_000)

            #expect(coordinator.state == .speaking)
            #expect(!mockPlayer.isStopped)

            await coordinator.stopSession()
        }
    }

    @Test("Interruption stops playback, cancels drainTask, and returns to listening")
    func testInterruptionCancelsDrainTask() async throws {
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

        // Ivy receives audio chunk and model turn completes (entering audio drain)
        mockSession.simulateEvent(.audioChunk(Data([0x99, 0x88])))
        mockSession.simulateEvent(.turnComplete)

        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)

        // User says "Hey Ivy" during drain
        mockDetector.simulateTranscription("Hey Ivy")

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .listening)
        #expect(mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("New request works normally after interruption")
    func testNewRequestAfterInterruption() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: true)
        let mockDetector = MockWakeWordDetector()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            wakeWordDetector: mockDetector
        )

        await coordinator.startSession()

        // Ivy speaks
        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)

        // Interrupted by "Hey Ivy"
        mockDetector.simulateTranscription("Hey Ivy")
        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .listening)

        // User speaks new request
        let newChunk = Data([0xDE, 0xAD, 0xBE, 0xEF])
        mockCapture.simulateAudioChunk(newChunk)

        for _ in 0..<50 {
            if mockSession.sentAudioChunks.contains(newChunk) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(mockSession.sentAudioChunks.contains(newChunk))

        // Ivy answers new request
        let answerChunk = Data([0xCA, 0xFE])
        mockSession.simulateEvent(.audioChunk(answerChunk))
        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)
        #expect(mockPlayer.playedChunks.contains(answerChunk))

        await coordinator.stopSession()
    }
}
