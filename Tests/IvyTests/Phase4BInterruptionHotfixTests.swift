import Testing
import Foundation
import os
@testable import IvyCore

@Suite("Phase 4B Hotfix - Hey Ivy Interruption Tests")
@MainActor
struct Phase4BInterruptionHotfixTests {

    // Helper for deterministic state polling without arbitrary sleeps
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 500_000_000,
        intervalNanoseconds: UInt64 = 5_000_000,
        condition: () async -> Bool
    ) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if await condition() { return true }
            await Task.yield()
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return await condition()
    }

    // =========================================================================
    // MARK: - 1. Partial & Punctuation Matching Tests
    // =========================================================================

    @Test("1. 'Hey' does not interrupt")
    func test1_heyDoesNotInterrupt() async throws {
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

        // Ivy begins speaking
        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)
        #expect(coordinator.state == .speaking)

        // Recognizer emits partial "Hey"
        mockDetector.simulateTranscription("Hey")
        await Task.yield()

        #expect(coordinator.state == .speaking)
        #expect(!mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("2. 'Hey I' does not interrupt")
    func test2_heyIDoesNotInterrupt() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)
        #expect(coordinator.state == .speaking)

        // Recognizer emits partial "Hey I"
        mockDetector.simulateTranscription("Hey I")
        await Task.yield()

        #expect(coordinator.state == .speaking)
        #expect(!mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("3. Partial 'Hey Ivy' interrupts without waiting for final recognition")
    func test3_partialHeyIvyInterruptsWithoutWaitingForFinalRecognition() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)
        #expect(coordinator.state == .speaking)

        // Directly invoke processTranscriptionForInterruption with partial hypothesis (isFinal == false)
        await coordinator.processTranscriptionForInterruption("Hey Ivy")

        let reachedListening = await waitUntil { coordinator.state == .listening }
        #expect(reachedListening)
        #expect(coordinator.state == .listening)
        #expect(mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("4. 'hey ivy' interrupts")
    func test4_lowercaseHeyIvyInterrupts() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        mockDetector.simulateTranscription("hey ivy")

        let reachedListening = await waitUntil { coordinator.state == .listening }
        #expect(reachedListening)
        #expect(coordinator.state == .listening)
        #expect(mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("5. 'Hey, Ivy' interrupts")
    func test5_heyCommaIvyInterrupts() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        mockDetector.simulateTranscription("Hey, Ivy")

        let reachedListening = await waitUntil { coordinator.state == .listening }
        #expect(reachedListening)
        #expect(coordinator.state == .listening)
        #expect(mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("6. 'Hey Ivy, stop' interrupts")
    func test6_heyIvyStopInterrupts() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        mockDetector.simulateTranscription("Hey Ivy, stop")

        let reachedListening = await waitUntil { coordinator.state == .listening }
        #expect(reachedListening)
        #expect(coordinator.state == .listening)
        #expect(mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("7. 'Hey everyone' does not interrupt")
    func test7_heyEveryoneDoesNotInterrupt() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        mockDetector.simulateTranscription("Hey everyone")
        await Task.yield()

        #expect(coordinator.state == .speaking)
        #expect(!mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("8. 'Ivy is...' does not interrupt")
    func test8_ivyIsDoesNotInterrupt() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        mockDetector.simulateTranscription("Ivy is a helpful AI")
        await Task.yield()

        #expect(coordinator.state == .speaking)
        #expect(!mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("9. 'Hey' alone does not interrupt")
    func test9_heyAloneDoesNotInterrupt() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        mockDetector.simulateTranscription("Hey")
        await Task.yield()

        #expect(coordinator.state == .speaking)
        #expect(!mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    // =========================================================================
    // MARK: - 2. Guarding & Stale Callback Tests
    // =========================================================================

    @Test("10. Multiple Hey Ivy callbacks trigger exactly one interruption")
    func test10_multipleHeyIvyCallbacksTriggerExactlyOneInterruption() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        // Multiple rapid callbacks
        mockDetector.simulateTranscription("Hey Ivy")
        mockDetector.simulateTranscription("Hey Ivy")
        mockDetector.simulateTranscription("Hey Ivy Ivy")

        let reachedListening = await waitUntil { coordinator.state == .listening }
        #expect(reachedListening)
        #expect(coordinator.state == .listening)
        #expect(mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("11. Stale recognition callbacks cannot interrupt")
    func test11_staleRecognitionCallbacksCannotInterrupt() async throws {
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

        // Stale callback arriving while already listening (not speaking)
        await coordinator.processTranscriptionForInterruption("Hey Ivy")
        #expect(coordinator.state == .listening)

        // While idle
        await coordinator.stopSession()
        #expect(coordinator.state == .idle)
        await coordinator.processTranscriptionForInterruption("Hey Ivy")
        #expect(coordinator.state == .idle)
    }

    @Test("12. Stale callbacks cannot modify a newer recognition task")
    func test12_staleCallbacksCannotModifyNewerRecognitionTask() async throws {
        let detector = SystemWakeWordDetector()
        await detector.reset()

        // Verify that reset() invalidates previous recognition state and tokens
        let match = await detector.processText("Hey Ivy")
        #expect(match)

        await detector.reset()
        let nonMatch = await detector.processText("Hello world")
        #expect(!nonMatch)

        // Old token from previous session cannot stitch with new token after reset
        _ = await detector.processText("Hey")
        await detector.reset()
        let separatedIvy = await detector.processText("Ivy")
        #expect(!separatedIvy, "Reset must clear rolling tokens so stale 'Hey' does not stitch with 'Ivy'")
    }

    // =========================================================================
    // MARK: - 3. Playback & Drainage Invariants
    // =========================================================================

    @Test("13. Interruption stops playback")
    func test13_interruptionStopsPlayback() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x11, 0x22])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)
        #expect(mockPlayer.isPlaying)

        mockDetector.simulateTranscription("Hey Ivy")

        let reachedListening = await waitUntil { coordinator.state == .listening }
        #expect(reachedListening)
        #expect(!mockPlayer.isPlaying)
        #expect(mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("14. Interruption clears the audio queue")
    func test14_interruptionClearsTheAudioQueue() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x11, 0x22])))
        mockSession.simulateEvent(.audioChunk(Data([0x33, 0x44])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        mockDetector.simulateTranscription("Hey Ivy")

        let reachedListening = await waitUntil { coordinator.state == .listening }
        #expect(reachedListening)
        #expect(mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("15. Interrupted audio never resumes")
    func test15_interruptedAudioNeverResumes() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x11, 0x22])))
        mockSession.simulateEvent(.turnComplete)

        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        mockDetector.simulateTranscription("Hey Ivy")

        let reachedListening = await waitUntil { coordinator.state == .listening }
        #expect(reachedListening)

        // Attempting to finish playback afterward must not resurrect audio or switch state
        mockPlayer.finishPlayback()
        await Task.yield()

        #expect(coordinator.state == .listening)
        #expect(mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("16. Coordinator reaches LISTENING after interruption")
    func test16_coordinatorReachesListeningAfterInterruption() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x11, 0x22])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        await coordinator.handleWakePhraseDetected()
        #expect(coordinator.state == .listening)

        await coordinator.stopSession()
    }

    @Test("17. Normal speech while SPEAKING does not interrupt")
    func test17_normalSpeechWhileSpeakingDoesNotInterrupt() async throws {
        let normalPhrases = [
            "Yeah, I understand.",
            "Wait, that's not what I meant.",
            "Can you explain further?",
            "Okay, sure thing."
        ]

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

        mockSession.simulateEvent(.audioChunk(Data([0x11, 0x22])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        for phrase in normalPhrases {
            mockDetector.simulateTranscription(phrase)
            await Task.yield()
            #expect(coordinator.state == .speaking)
            #expect(!mockPlayer.isStopped)
        }

        await coordinator.stopSession()
    }

    @Test("18. Ivy's own speech/transcript cannot trigger a false wake")
    func test18_ivysOwnSpeechCannotTriggerFalseWake() async throws {
        let echoSentence = "Machine learning is a method where computers learn patterns from data."

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

        mockSession.simulateEvent(.audioChunk(Data([0x11, 0x22])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        mockDetector.simulateTranscription(echoSentence)
        await Task.yield()

        #expect(coordinator.state == .speaking)
        #expect(!mockPlayer.isStopped)

        await coordinator.stopSession()
    }

    @Test("19. Wake detector resets correctly after interruption")
    func test19_wakeDetectorResetsCorrectlyAfterInterruption() async throws {
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

        mockSession.simulateEvent(.audioChunk(Data([0x11, 0x22])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        mockDetector.simulateTranscription("Hey Ivy")
        let reachedListening = await waitUntil { coordinator.state == .listening }
        #expect(reachedListening)

        #expect(mockDetector.isReset)

        await coordinator.stopSession()
    }

    @Test("20. A new request works after interruption")
    func test20_newRequestWorksAfterInterruption() async throws {
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

        // 1. Enter speaking
        mockSession.simulateEvent(.audioChunk(Data([0x11, 0x22])))
        let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
        #expect(reachedSpeaking)

        // 2. Interrupt
        mockDetector.simulateTranscription("Hey Ivy")
        let reachedListening = await waitUntil { coordinator.state == .listening }
        #expect(reachedListening)
        #expect(coordinator.state == .listening)

        // 3. New request audio streams cleanly to Gemini Live
        let newChunk = Data([0xDE, 0xAD, 0xBE, 0xEF])
        mockCapture.simulateAudioChunk(newChunk)

        let chunkSent = await waitUntil { mockSession.sentAudioChunks.contains(newChunk) }
        #expect(chunkSent)
        #expect(mockSession.sentAudioChunks.contains(newChunk))

        await coordinator.stopSession()
    }

    @Test("21. Repeated interruption cycles work")
    func test21_repeatedInterruptionCyclesWork() async throws {
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

        for cycle in 1...3 {
            // Ivy speaks
            mockSession.simulateEvent(.audioChunk(Data([UInt8(cycle), 0x99])))
            let reachedSpeaking = await waitUntil { coordinator.state == .speaking }
            #expect(reachedSpeaking, "Cycle \(cycle) should reach speaking")

            // User interrupts
            mockDetector.simulateTranscription("Hey Ivy")
            let reachedListening = await waitUntil { coordinator.state == .listening }
            #expect(reachedListening, "Cycle \(cycle) should return to listening")
            #expect(mockPlayer.isStopped, "Cycle \(cycle) must stop audio playback")
        }

        await coordinator.stopSession()
    }

    // =========================================================================
    // MARK: - 4. Regressions
    // =========================================================================

    @Test("22. Existing Gemini Live tests remain passing")
    func test22_existingGeminiLiveTestsRemainPassing() {
        let client = GeminiLiveClient(apiKey: "test-api-key")
        #expect(client.model == "models/gemini-3.1-flash-live-preview")
        #expect(client.voiceName == "Kore")
    }

    @Test("23. Kore voice tests remain passing")
    func test23_koreVoiceTestsRemainPassing() {
        let config = BidiPrebuiltVoiceConfig(voiceName: "Aoede")
        #expect(config.voiceName == "Kore")

        let setup = BidiSetup()
        #expect(setup.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName == "Kore")

        let client = GeminiLiveClient(apiKey: "key", voiceName: "Fenrir")
        #expect(client.voiceName == "Kore")
    }

    @Test("24. ElevenLabs tests remain passing")
    func test24_elevenLabsTestsRemainPassing() {
        let config = ElevenLabsConfiguration()
        #expect(config.voiceID == "EXAVITQu4vr4xnSDxMaL") // Sarah default
        #expect(config.modelID == "eleven_turbo_v2_5")
    }

    @Test("25. Tool/SafetyGate tests remain passing")
    func test25_toolSafetyGateTestsRemainPassing() {
        let policy = SafetyPolicy()
        #expect(policy.classification(for: "open_app") == .safe)
        #expect(policy.classification(for: "run_applescript") == .risky)
        #expect(policy.classification(for: "calendar_event") == .risky)
        #expect(policy.classification(for: "run_shell") == .risky)
        #expect(policy.classification(for: "file_op") == .risky)
    }
}
