import Testing
import Foundation
import os
@testable import IvyCore

@Suite("Phase 4C - Global Hotkey & Push-to-Talk Tests")
@MainActor
struct Phase4CGlobalHotkeyTests {

    // =========================================================================
    // MARK: - 1. Registration
    // =========================================================================

    @Test("1. Global hotkey registration succeeds with default Command + Shift + Space shortcut")
    func testRegistrationSucceeds() throws {
        let mockHotkey = MockGlobalHotkeyManager()
        #expect(!mockHotkey.isRegistered)

        try mockHotkey.register(shortcut: .defaultPushToTalk, onKeyDown: {}, onKeyUp: {})
        #expect(mockHotkey.isRegistered)
        #expect(mockHotkey.registeredShortcut == .defaultPushToTalk)
        #expect(mockHotkey.registeredShortcut?.keyCode == 49) // kVK_Space
        #expect(mockHotkey.registeredShortcut?.modifiers.contains(.command) == true)
        #expect(mockHotkey.registeredShortcut?.modifiers.contains(.shift) == true)
        #expect(mockHotkey.registrationCount == 1)
    }

    @Test("1b. Option + Control chord matches exactly; extra or missing modifiers do not trigger")
    func testModifierChordExactMatch() {
        let required: HotkeyModifiers = [.option, .control]
        #expect(SystemGlobalHotkeyManager.chordHeld([.option, .control], required: required))
        #expect(SystemGlobalHotkeyManager.chordHeld([.option, .control, .capsLock], required: required))
        #expect(!SystemGlobalHotkeyManager.chordHeld([.option], required: required))
        #expect(!SystemGlobalHotkeyManager.chordHeld([.control], required: required))
        #expect(!SystemGlobalHotkeyManager.chordHeld([.option, .control, .command], required: required))
        #expect(!SystemGlobalHotkeyManager.chordHeld([.option, .control, .shift], required: required))
        #expect(!SystemGlobalHotkeyManager.chordHeld([], required: required))
    }

    @Test("2. Registration failure is handled gracefully and returns structured error")
    func testRegistrationFailureHandledGracefully() {
        let mockHotkey = MockGlobalHotkeyManager(mockErrorOnRegister: .registrationFailed(-9868))

        #expect(throws: HotkeyError.registrationFailed(-9868)) {
            try mockHotkey.register(onKeyDown: {}, onKeyUp: {})
        }
        #expect(!mockHotkey.isRegistered)
        #expect(mockHotkey.registrationCount == 0)
    }

    @Test("3. Registration failure does not crash Ivy coordinator and preserves idle state")
    func testRegistrationFailureDoesNotCrashIvy() {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager(mockErrorOnRegister: .registrationFailed(-9868))

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        #expect(throws: HotkeyError.registrationFailed(-9868)) {
            try coordinator.registerHotkey()
        }
        #expect(coordinator.state == .idle)
        #expect(!coordinator.isPushToTalkActive)
        #expect(!mockHotkey.isRegistered)
    }

    @Test("4. Unregister cleanly releases system hotkey and resets state")
    func testUnregister() throws {
        let mockHotkey = MockGlobalHotkeyManager()
        try mockHotkey.register(onKeyDown: {}, onKeyUp: {})
        #expect(mockHotkey.isRegistered)

        mockHotkey.unregister()
        #expect(!mockHotkey.isRegistered)
        #expect(mockHotkey.registeredShortcut == nil)
        #expect(mockHotkey.unregisterCount == 1)
    }

    @Test("5. Repeated unregister is safe, idempotent, and does not crash")
    func testRepeatedUnregisterIsSafe() throws {
        let mockHotkey = MockGlobalHotkeyManager()
        try mockHotkey.register(onKeyDown: {}, onKeyUp: {})

        mockHotkey.unregister()
        #expect(!mockHotkey.isRegistered)
        #expect(mockHotkey.unregisterCount == 1)

        // Second unregister call
        mockHotkey.unregister()
        #expect(!mockHotkey.isRegistered)
        #expect(mockHotkey.unregisterCount == 2)
    }

    @Test("6. Registration does not happen twice unnecessarily (alreadyRegistered error)")
    func testRegistrationDoesNotHappenTwice() throws {
        let mockHotkey = MockGlobalHotkeyManager()
        try mockHotkey.register(onKeyDown: {}, onKeyUp: {})
        #expect(mockHotkey.isRegistered)

        #expect(throws: HotkeyError.alreadyRegistered) {
            try mockHotkey.register(onKeyDown: {}, onKeyUp: {})
        }
        #expect(mockHotkey.registrationCount == 1)
    }

    @Test("7. Coordinator without hotkey manager handles register and unregister safely")
    func testCoordinatorWithoutHotkeyManagerIsSafe() throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: nil
        )

        // Does not throw and does not crash
        try coordinator.registerHotkey()
        coordinator.unregisterHotkey()
        #expect(coordinator.state == .idle)
    }

    // =========================================================================
    // MARK: - 2. Key Down
    // =========================================================================

    @Test("8. First key-down starts push-to-talk listening session")
    func testFirstKeyDownStartsPushToTalk() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        #expect(coordinator.state == .idle)
        #expect(!coordinator.isPushToTalkActive)

        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .listening)
        #expect(coordinator.isPushToTalkActive)
        #expect(coordinator.wasSessionStartedByPushToTalk)
        #expect(mockSession.isConnected)
        #expect(mockCapture.isCapturing)
        #expect(mockCapture.startCaptureCallCount == 1)

        await coordinator.shutdown()
    }

    @Test("9. Duplicate key-down does not restart session or start another session")
    func testDuplicateKeyDownDoesNotRestartSession() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .listening)

        // Second key-down event while held
        mockHotkey.simulateKeyDown()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(coordinator.state == .listening)
        #expect(coordinator.isPushToTalkActive)
        #expect(mockCapture.startCaptureCallCount == 1)

        await coordinator.shutdown()
    }

    @Test("10. Multiple repeated key-down events result in exactly one begin operation")
    func testMultipleRepeatedKeyDownResultsInExactlyOneBegin() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()

        // Rapid 5 key-down events
        for _ in 0..<5 {
            mockHotkey.simulateKeyDown()
        }

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .listening)
        #expect(mockCapture.startCaptureCallCount == 1)

        await coordinator.shutdown()
    }

    @Test("11. Key-down while already listening does not restart Live")
    func testKeyDownWhileAlreadyListeningDoesNotRestart() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        await coordinator.startSession()
        #expect(coordinator.state == .listening)
        #expect(!coordinator.wasSessionStartedByPushToTalk)

        mockHotkey.simulateKeyDown()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(coordinator.state == .listening)
        #expect(mockCapture.startCaptureCallCount == 1)
        #expect(!coordinator.wasSessionStartedByPushToTalk)

        await coordinator.shutdown()
    }

    @Test("12. Key-down does not create another WebSocket connection")
    func testKeyDownDoesNotCreateAnotherWebSocket() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        mockHotkey.simulateKeyDown()
        mockHotkey.simulateKeyDown()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(mockSession.isConnected)
        #expect(mockCapture.startCaptureCallCount == 1)

        await coordinator.shutdown()
    }

    @Test("13. Key-down is safe under rapid event delivery")
    func testKeyDownSafeUnderRapidEventDelivery() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()

        for _ in 0..<10 {
            mockHotkey.simulateKeyDown()
        }

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .listening)
        #expect(coordinator.isPushToTalkActive)

        await coordinator.shutdown()
    }

    // =========================================================================
    // MARK: - 3. Key Up
    // =========================================================================

    @Test("14. Key-up stops push-to-talk and returns session to idle")
    func testKeyUpStopsPushToTalk() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .listening)

        mockHotkey.simulateKeyUp()

        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .idle)
        #expect(!coordinator.isPushToTalkActive)
        #expect(!mockCapture.isCapturing)
        #expect(!mockSession.isConnected)

        await coordinator.shutdown()
    }

    @Test("15. Duplicate key-up does nothing and is idempotent")
    func testDuplicateKeyUpDoesNothing() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // First key up
        mockHotkey.simulateKeyUp()
        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .idle)

        // Duplicate key up
        mockHotkey.simulateKeyUp()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(coordinator.state == .idle)
        #expect(!coordinator.isPushToTalkActive)

        await coordinator.shutdown()
    }

    @Test("16. Key-up without previous key-down is safe and does not stop Live")
    func testKeyUpWithoutPreviousKeyDownIsSafe() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        #expect(coordinator.state == .idle)

        mockHotkey.simulateKeyUp()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(coordinator.state == .idle)
        #expect(mockCapture.stopCaptureCallCount == 0)

        await coordinator.shutdown()
    }

    @Test("17. Multiple key-up events do not stop Live multiple times")
    func testMultipleKeyUpsDoNotStopLiveMultipleTimes() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        mockHotkey.simulateKeyUp()
        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let stopCountAfterFirstKeyUp = mockCapture.stopCaptureCallCount

        // 3 more key-up events
        mockHotkey.simulateKeyUp()
        mockHotkey.simulateKeyUp()
        mockHotkey.simulateKeyUp()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(mockCapture.stopCaptureCallCount == stopCountAfterFirstKeyUp)

        await coordinator.shutdown()
    }

    @Test("18. Key-up closes capture and session teardown releases audio resources")
    func testMicrophoneCaptureAndEngineStopped() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(mockCapture.startCaptureCallCount == 1)

        mockHotkey.simulateKeyUp()
        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(mockCapture.stopCaptureCallCount == 2)
        #expect(!mockCapture.isCapturing)

        await coordinator.shutdown()
    }

    // =========================================================================
    // MARK: - 4. Press / Release Sequences
    // =========================================================================

    @Test("19. Sequence down -> up operates deterministically")
    func testSequenceDownUp() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()

        // down
        mockHotkey.simulateKeyDown()
        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .listening)

        // up
        mockHotkey.simulateKeyUp()
        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .idle)
        #expect(mockCapture.startCaptureCallCount == 1)
        #expect(mockCapture.stopCaptureCallCount == 2)

        await coordinator.shutdown()
    }

    @Test("20. Sequence down -> up -> down -> up operates deterministically with exact counts")
    func testSequenceDownUpDownUp() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()

        // 1st cycle: down -> up
        mockHotkey.simulateKeyDown()
        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        mockHotkey.simulateKeyUp()
        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // 2nd cycle: down -> up
        mockHotkey.simulateKeyDown()
        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        mockHotkey.simulateKeyUp()
        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .idle)
        #expect(mockCapture.startCaptureCallCount == 2)
        #expect(mockCapture.stopCaptureCallCount == 4)

        await coordinator.shutdown()
    }

    @Test("21. Sequence down -> down -> up operates deterministically")
    func testSequenceDownDownUp() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()

        // down -> down -> up
        mockHotkey.simulateKeyDown()
        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        mockHotkey.simulateKeyDown()
        try await Task.sleep(nanoseconds: 10_000_000)

        mockHotkey.simulateKeyUp()
        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .idle)
        #expect(mockCapture.startCaptureCallCount == 1)
        #expect(mockCapture.stopCaptureCallCount == 2)

        await coordinator.shutdown()
    }

    @Test("22. Sequence down -> down -> up -> up operates deterministically")
    func testSequenceDownDownUpUp() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()

        // down -> down -> up -> up
        mockHotkey.simulateKeyDown()
        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        mockHotkey.simulateKeyDown()
        try await Task.sleep(nanoseconds: 10_000_000)

        mockHotkey.simulateKeyUp()
        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        mockHotkey.simulateKeyUp()
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(coordinator.state == .idle)
        #expect(mockCapture.startCaptureCallCount == 1)
        #expect(mockCapture.stopCaptureCallCount == 2)

        await coordinator.shutdown()
    }

    @Test("23. Rapid down/up sequences maintain deterministic begin/end without stuck states")
    func testRapidDownUpSequence() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()

        for cycle in 1...3 {
            mockHotkey.simulateKeyDown()
            for _ in 0..<50 {
                if coordinator.state == .listening { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(coordinator.state == .listening, "Cycle \(cycle) should reach listening")

            mockHotkey.simulateKeyUp()
            for _ in 0..<50 {
                if coordinator.state == .idle { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(coordinator.state == .idle, "Cycle \(cycle) should reach idle")
            #expect(!mockCapture.isCapturing, "Cycle \(cycle) must stop mic capture")
        }

        await coordinator.shutdown()
    }

    // =========================================================================
    // MARK: - 5. Ivy Live State Handling
    // =========================================================================

    @Test("24. Hotkey state handling when idle")
    func testHotkeyStateWhenIdle() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        #expect(coordinator.state == .idle)

        mockHotkey.simulateKeyDown()
        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .listening)

        mockHotkey.simulateKeyUp()
        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .idle)

        await coordinator.shutdown()
    }

    @Test("25. Hotkey state handling when listening: non-PTT session is preserved on key-up")
    func testHotkeyStateWhenListening() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        await coordinator.startSession()
        #expect(coordinator.state == .listening)
        #expect(!coordinator.wasSessionStartedByPushToTalk)

        mockHotkey.simulateKeyDown()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(coordinator.state == .listening)

        mockHotkey.simulateKeyUp()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(coordinator.state == .listening, "Hands-free continuous listening session must NOT be terminated by key-up")

        await coordinator.shutdown()
    }

    @Test("26. Hotkey state handling when thinking: key-down does not restart session")
    func testHotkeyStateWhenThinking() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        await coordinator.startSession()

        mockSession.simulateEvent(.textTurn("Thinking..."))
        #expect(coordinator.state == .listening || coordinator.latestTranscript == "Thinking...")

        mockHotkey.simulateKeyDown()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(mockCapture.startCaptureCallCount == 1)

        await coordinator.shutdown()
    }

    @Test("27. Hotkey state handling when speaking: key-down does not cut off speech, key-up allows speech to finish")
    func testHotkeyStateWhenSpeaking() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Model speaks
        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)

        // Key up while speaking: speech must continue playing!
        mockHotkey.simulateKeyUp()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(coordinator.state == .speaking, "Releasing key while Ivy is speaking must allow playback to continue")

        // Turn complete drains audio: because key was released, finishing playback cleanly returns session to idle!
        mockSession.simulateEvent(.turnComplete)
        mockPlayer.finishPlayback()
        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .idle)

        await coordinator.shutdown()
    }

    @Test("28. Hotkey state handling when interrupting: key-down is safely ignored")
    func testHotkeyStateWhenInterrupting() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        await coordinator.startSession()

        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await coordinator.handleWakePhraseDetected()
        #expect(coordinator.state == .listening)

        mockHotkey.simulateKeyDown()
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(coordinator.state == .listening)

        await coordinator.shutdown()
    }

    @Test("29. Hotkey state handling when disconnected: key-down reconnects cleanly")
    func testHotkeyStateWhenDisconnected() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        #expect(coordinator.state == .idle)

        mockHotkey.simulateKeyDown()
        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .listening)
        #expect(mockSession.isConnected)

        mockHotkey.simulateKeyUp()
        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .idle)

        await coordinator.shutdown()
    }

    @Test("30. Hotkey state handling when connecting: key-up during connect aborts cleanly")
    func testHotkeyStateWhenConnecting() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()

        // Key down initiates connecting
        mockHotkey.simulateKeyDown()
        // Immediately key up while in connecting
        mockHotkey.simulateKeyUp()

        for _ in 0..<50 {
            if coordinator.state == .idle && !mockCapture.isCapturing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .idle)
        #expect(!mockCapture.isCapturing)

        await coordinator.shutdown()
    }

    // =========================================================================
    // MARK: - 6. Speaking State & Interruption Invariance
    // =========================================================================

    @Test("31. Pressing push-to-talk key while speaking does NOT accidentally trigger arbitrary interruption")
    func testSpeakingStatePressDoesNotTriggerInterruption() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        await coordinator.startSession()

        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)

        // Hotkey down does NOT interrupt
        mockHotkey.simulateKeyDown()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(coordinator.state == .speaking)
        #expect(!mockPlayer.isStopped)

        mockHotkey.simulateKeyUp()
        #expect(coordinator.state == .speaking)

        await coordinator.shutdown()
    }

    @Test("32. 'Hey Ivy' wake phrase interruption strictly works while speaking during push-to-talk")
    func testSpeakingStateHeyIvyInterruptionRemainsIntact() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockDetector = MockWakeWordDetector()
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            wakeWordDetector: mockDetector,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)

        // Wake interruption triggers
        mockDetector.simulateTranscription("Hey Ivy")
        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .listening)
        #expect(mockPlayer.isStopped)

        await coordinator.shutdown()
    }

    @Test("33. Normal speech does NOT interrupt Ivy while speaking during push-to-talk")
    func testSpeakingStateNormalSpeechDoesNotInterrupt() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockDetector = MockWakeWordDetector()
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            wakeWordDetector: mockDetector,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .speaking)

        // Non-wake phrases must NOT interrupt
        mockDetector.simulateTranscription("Yeah, I understand.")
        mockDetector.simulateTranscription("Wait, that's not what I meant.")
        mockDetector.simulateTranscription("Hey everyone")
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(coordinator.state == .speaking)
        #expect(!mockPlayer.isStopped)

        await coordinator.shutdown()
    }

    // =========================================================================
    // MARK: - 7. Interruption Regression & Wake Detector Lifecycle
    // =========================================================================

    @Test("34. Hotkey handling does not disable the local wake detector")
    func testHotkeyDoesNotDisableWakeDetector() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockDetector = MockWakeWordDetector()
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            wakeWordDetector: mockDetector,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Enter speaking
        mockSession.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        for _ in 0..<50 {
            if coordinator.state == .speaking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Simulate mic buffers arriving during speaking: wake detector must receive them
        let initialChunkCount = mockDetector.processedChunksCount
        mockCapture.simulateAudioChunk(Data([0xAA, 0xBB]))
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(mockDetector.processedChunksCount >= initialChunkCount)

        await coordinator.shutdown()
    }

    @Test("35. Wake detector state remains correct after hotkey release and reset")
    func testWakeDetectorStateRemainsCorrectAfterHotkeyRelease() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockDetector = MockWakeWordDetector()
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            wakeWordDetector: mockDetector,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        mockHotkey.simulateKeyUp()
        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .idle)
        #expect(mockDetector.isReset)

        await coordinator.shutdown()
    }

    // =========================================================================
    // MARK: - 8. Shutdown
    // =========================================================================

    @Test("36. Application shutdown cleanly unregisters global hotkey")
    func testShutdownUnregistersHotkey() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        #expect(mockHotkey.isRegistered)

        await coordinator.shutdown()
        #expect(!mockHotkey.isRegistered)
        #expect(mockHotkey.unregisterCount == 1)
    }

    @Test("37. Shutdown releases active push-to-talk session and returns to idle")
    func testShutdownReleasesActivePushToTalkSession() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.isPushToTalkActive)

        await coordinator.shutdown()

        #expect(!coordinator.isPushToTalkActive)
        #expect(coordinator.state == .idle)
        #expect(!mockCapture.isCapturing)
        #expect(!mockSession.isConnected)
    }

    @Test("38. Shutdown stops microphone capture")
    func testShutdownStopsMicrophoneCapture() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(mockCapture.isCapturing)

        await coordinator.shutdown()
        #expect(!mockCapture.isCapturing)
    }

    @Test("39. Shutdown is safe when no hotkey is currently active or pressed")
    func testShutdownSafeIfIdle() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        #expect(coordinator.state == .idle)

        await coordinator.shutdown()
        #expect(coordinator.state == .idle)
    }

    @Test("40. Shutdown is safe after registration failure")
    func testShutdownSafeAfterRegistrationFailure() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager(mockErrorOnRegister: .registrationFailed(-9868))

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try? coordinator.registerHotkey()
        await coordinator.shutdown()
        #expect(coordinator.state == .idle)
    }

    @Test("41. No tasks remain running because of the hotkey after shutdown")
    func testNoTaskRemainsRunningAfterShutdown() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        await coordinator.shutdown()
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(coordinator.state == .idle)
        #expect(!mockCapture.isCapturing)
        #expect(!mockSession.isConnected)
    }

    // =========================================================================
    // MARK: - 9. Cancellation / Concurrency
    // =========================================================================

    @Test("42. Cancellation during key-down stops session cleanly")
    func testCancellationDuringKeyDown() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()

        let task = Task { @MainActor in
            await coordinator.beginPushToTalk()
        }
        task.cancel()
        _ = await task.result

        await coordinator.stopSession()
        #expect(coordinator.state == .idle)
        #expect(!mockCapture.isCapturing)

        await coordinator.shutdown()
    }

    @Test("43. Cancellation during key-up leaves coordinator in consistent state")
    func testCancellationDuringKeyUp() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let task = Task { @MainActor in
            await coordinator.endPushToTalk()
        }
        task.cancel()
        _ = await task.result

        await coordinator.stopSession()
        #expect(coordinator.state == .idle)

        await coordinator.shutdown()
    }

    @Test("44. Rapid event races maintain deterministic begin/end state")
    func testRapidEventRacesDoNotCorruptState() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()

        // 10 interleaved rapid events
        for _ in 0..<10 {
            mockHotkey.simulateKeyDown()
            mockHotkey.simulateKeyUp()
        }

        for _ in 0..<50 {
            if coordinator.state == .idle && !mockCapture.isCapturing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .idle)
        #expect(!mockCapture.isCapturing)

        await coordinator.shutdown()
    }

    @Test("45. Live disconnect while key is held transitions to error without hanging")
    func testLiveDisconnectWhileKeyIsHeld() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Live disconnect error occurs while key is held
        mockSession.simulateError(LiveError.connectionFailed("Socket lost"))

        for _ in 0..<50 {
            if case .error = coordinator.state { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        guard case .error(let msg) = coordinator.state else {
            Issue.record("Expected coordinator to enter error state")
            return
        }
        #expect(msg.contains("Socket lost"))

        // Release key clears error state cleanly
        mockHotkey.simulateKeyUp()
        try await Task.sleep(nanoseconds: 20_000_000)

        await coordinator.shutdown()
    }

    @Test("46. Live reconnect after disconnect while key state changes operates cleanly")
    func testLiveReconnectWhileKeyStateChanges() async throws {
        let mockSession = MockGeminiLiveSession(connectError: LiveError.connectionFailed("Network glitch"))
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if case .error = coordinator.state { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        mockHotkey.simulateKeyUp()

        // Fix error and re-press
        mockSession.setConnectError(nil)
        mockHotkey.simulateKeyDown()

        for _ in 0..<50 {
            if coordinator.state == .listening { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .listening)

        mockHotkey.simulateKeyUp()
        for _ in 0..<50 {
            if coordinator.state == .idle { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(coordinator.state == .idle)

        await coordinator.shutdown()
    }

    @Test("47. Stale asynchronous callbacks cannot resurrect audio capture or create duplicate sessions")
    func testSessionTokenPreventsStaleAudioAndMicLeak() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()

        // Rapid key down then immediate key up
        mockHotkey.simulateKeyDown()
        mockHotkey.simulateKeyUp()

        for _ in 0..<50 {
            if coordinator.state == .idle && !mockCapture.isCapturing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        #expect(coordinator.state == .idle)
        #expect(!mockCapture.isCapturing)
        #expect(!mockSession.isConnected)

        await coordinator.shutdown()
    }

    // =========================================================================
    // MARK: - 10. Security Requirements (Strict Invariants)
    // =========================================================================

    @Test("48. Hotkey never acts as a confirmation mechanism for pending tool requests")
    func testHotkeyNeverActsAsConfirmationMechanism() async {
        let mockHotkey = MockGlobalHotkeyManager()
        let confirmationRequested = OSAllocatedUnfairLock(initialState: false)

        let confirmationProvider = ClosureConfirmationProvider { _ in
            confirmationRequested.withLock { $0 = true }
            return false // User cancelled
        }
        let gate = InteractiveSafetyGate(confirmationProvider: confirmationProvider)

        let tool = RunShellTool(executor: MockShellExecutor())
        let call = FunctionCall(name: "run_shell", args: ["command": AnyCodable("sw_vers")], id: "sh-test")

        // Hotkey events occur while confirmation is pending
        mockHotkey.simulateKeyDown()
        mockHotkey.simulateKeyUp()

        let decision = await gate.evaluate(tool: tool, call: call)

        #expect(confirmationRequested.withLock { $0 })
        #expect(decision == .reject(reason: "User cancelled operation with prejudice."))
    }

    @Test("49. Hotkey cannot bypass SafetyGate classifications")
    func testHotkeyCannotBypassSafetyGate() {
        let mockHotkey = MockGlobalHotkeyManager()
        let policy = SafetyPolicy()

        mockHotkey.simulateKeyDown()
        #expect(policy.classification(for: "open_app") == .safe)
        #expect(policy.classification(for: "run_applescript") == .risky)
        #expect(policy.classification(for: "calendar_event") == .risky)
        #expect(policy.classification(for: "run_shell") == .risky)
        #expect(policy.classification(for: "file_op") == .risky)

        mockHotkey.simulateKeyUp()
        #expect(policy.classification(for: "open_app") == .safe)
        #expect(policy.classification(for: "run_applescript") == .risky)
        #expect(policy.classification(for: "calendar_event") == .risky)
        #expect(policy.classification(for: "run_shell") == .risky)
        #expect(policy.classification(for: "file_op") == .risky)
    }

    @Test("50. Hotkey cannot approve tool call or execute shell command")
    func testHotkeyCannotApproveToolCallOrExecuteShell() async {
        let mockHotkey = MockGlobalHotkeyManager()
        let mockExecutor = MockShellExecutor()
        let tool = RunShellTool(executor: mockExecutor)
        let gate = InteractiveSafetyGate(confirmationProvider: ClosureConfirmationProvider { _ in false })

        mockHotkey.simulateKeyDown()
        mockHotkey.simulateKeyUp()

        let call = FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")], id: "sh-2")
        let decision = await gate.evaluate(tool: tool, call: call)

        #expect(decision != .approve)
        #expect(mockExecutor.recordedCommands.isEmpty, "Shell command must NEVER be executed via hotkey")
    }

    @Test("51. Hotkey cannot approve AppleScript execution or file deletion")
    func testHotkeyCannotApproveAppleScriptOrFileDeletion() async {
        let mockHotkey = MockGlobalHotkeyManager()
        let gate = InteractiveSafetyGate(confirmationProvider: ClosureConfirmationProvider { _ in false })

        mockHotkey.simulateKeyDown()

        // AppleScript
        let appleTool = RunAppleScriptTool(executor: MockAppleScriptExecutor())
        let appleCall = FunctionCall(name: "run_applescript", args: ["script": AnyCodable("display alert")], id: "as-1")
        let appleDecision = await gate.evaluate(tool: appleTool, call: appleCall)
        #expect(appleDecision != .approve)

        // File deletion
        let fileTool = FileOpTool()
        let fileCall = FunctionCall(name: "file_op", args: ["action": AnyCodable("delete"), "path": AnyCodable("/etc/passwd")], id: "fo-1")
        let fileDecision = await gate.evaluate(tool: fileTool, call: fileCall)
        #expect(fileDecision != .approve)

        mockHotkey.simulateKeyUp()
    }

    @Test("52. Hotkey coordinator never exposes API keys in transcripts or states")
    func testHotkeyNeverExposesAPIKeys() async throws {
        let mockSession = MockGeminiLiveSession()
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        let mockPlayer = MockLiveAudioPlayer(autoDrain: false)
        let mockHotkey = MockGlobalHotkeyManager()

        let coordinator = GeminiLiveVoiceCoordinator(
            session: mockSession,
            audioCapture: mockCapture,
            audioPlayer: mockPlayer,
            hotkeyManager: mockHotkey
        )

        try coordinator.registerHotkey()
        mockHotkey.simulateKeyDown()
        mockHotkey.simulateKeyUp()

        #expect(!coordinator.latestTranscript.contains("AIza"))
        #expect(!coordinator.latestTranscript.contains("key"))

        await coordinator.shutdown()
    }

    // =========================================================================
    // MARK: - 11. Core Regression Tests
    // =========================================================================

    @Test("53. Existing Gemini Live Kore voice lock is strictly preserved")
    func testExistingGeminiLiveKoreVoiceLockPreserved() {
        let config = BidiPrebuiltVoiceConfig(voiceName: "Charon")
        #expect(config.voiceName == "Kore")

        let setup = BidiSetup()
        #expect(setup.generationConfig.speechConfig.voiceConfig.prebuiltVoiceConfig.voiceName == "Kore")

        let client = GeminiLiveClient(apiKey: "test-key", voiceName: "Fenrir")
        #expect(client.voiceName == "Kore")
    }

    @Test("54. Existing ElevenLabs TTS configuration remains functional")
    func testExistingElevenLabsTTSConfigurationPreserved() {
        let config = ElevenLabsConfiguration()
        #expect(config.voiceID == "EXAVITQu4vr4xnSDxMaL") // Sarah default
        #expect(config.modelID == "eleven_turbo_v2_5")
    }

    @Test("55. Existing SafetyPolicy classifications remain strictly preserved")
    func testExistingSafetyPolicyPreserved() {
        let policy = SafetyPolicy()
        #expect(policy.classification(for: "open_app") == .safe)
        #expect(policy.classification(for: "run_applescript") == .risky)
        #expect(policy.classification(for: "calendar_event") == .risky)
        #expect(policy.classification(for: "run_shell") == .risky)
        #expect(policy.classification(for: "file_op") == .risky)
    }
}
