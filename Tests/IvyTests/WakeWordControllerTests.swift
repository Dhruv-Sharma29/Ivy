import Testing
import Foundation
import os
@testable import IvyCore

/// Fake idle listener: records starts/stops and can fire the wake word. Never touches the microphone.
private final class MockWakeWordListener: WakeWordListening, @unchecked Sendable {
    private struct State {
        var listening = false
        var starts = 0
        var stops = 0
        var overlappingStarts = 0
        var failure: WakeWordListenerError? = nil
        var onWake: (@Sendable () -> Void)? = nil
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isListening: Bool { state.withLock { $0.listening } }
    var starts: Int { state.withLock { $0.starts } }
    var overlappingStarts: Int { state.withLock { $0.overlappingStarts } }
    func fail(with error: WakeWordListenerError?) { state.withLock { $0.failure = error } }

    func start(onWake: @escaping @Sendable () -> Void) async throws {
        try state.withLock { s in
            if let failure = s.failure { throw failure }
            if s.listening { s.overlappingStarts += 1 }
            s.listening = true
            s.starts += 1
            s.onWake = onWake
        }
    }

    func stop() async {
        state.withLock { s in
            if s.listening { s.stops += 1 }
            s.listening = false
            s.onWake = nil
        }
    }

    /// Like the real listener: stops itself (releasing the mic), then reports the wake word.
    func hearHeyIvy() {
        let onWake = state.withLock { s -> (@Sendable () -> Void)? in
            defer { s.listening = false; s.onWake = nil }
            return s.onWake
        }
        onWake?()
    }
}

@Suite("Hey Ivy idle wake-up")
@MainActor
struct WakeWordControllerTests {
    private func make() -> (WakeWordController, MockWakeWordListener, GeminiLiveVoiceCoordinator, MockAudioCapture) {
        let listener = MockWakeWordListener()
        let capture = MockAudioCapture()
        let coordinator = GeminiLiveVoiceCoordinator(
            session: MockGeminiLiveSession(), audioCapture: capture, audioPlayer: MockLiveAudioPlayer(autoDrain: true),
            wakeWordDetector: MockWakeWordDetector(), wakeSilenceTimeout: .seconds(30)
        )
        return (WakeWordController(listener: listener, coordinator: coordinator), listener, coordinator, capture)
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    @Test("off by default: the microphone is never opened")
    func offByDefault() async {
        let (controller, listener, _, capture) = make()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(listener.starts == 0)
        #expect(capture.startCaptureCallCount == 0)
        #expect(controller.status == .off)
    }

    @Test("enabling while idle starts listening once")
    func enableStarts() async {
        let (controller, listener, _, _) = make()
        controller.setEnabled(true)
        await until { controller.status == .listening }
        #expect(listener.isListening)
        #expect(listener.starts == 1)
    }

    @Test("\"Hey Ivy\" while idle hands the mic to a wake session, then listening resumes when it ends")
    func wakeStartsSessionAndResumes() async {
        let (controller, listener, coordinator, capture) = make()
        var chimes = 0
        controller.onWake = { chimes += 1 }
        controller.setEnabled(true)
        await until { controller.status == .listening }

        listener.hearHeyIvy()
        await until { coordinator.state == .listening }
        #expect(coordinator.wasSessionStartedByWakeWord)
        #expect(capture.isCapturing)
        #expect(!listener.isListening)
        #expect(controller.status == .paused)
        #expect(chimes == 1)

        await coordinator.stopSession()
        await until { listener.isListening && controller.status == .listening }
        #expect(controller.status == .listening)
        #expect(listener.overlappingStarts == 0)
    }

    @Test("a manually started session pauses the listener, which resumes afterwards")
    func manualSessionPauses() async {
        let (controller, listener, coordinator, _) = make()
        controller.setEnabled(true)
        await until { controller.status == .listening }

        await coordinator.startSession()
        await until { !listener.isListening }
        #expect(controller.status == .paused)

        await coordinator.stopSession()
        await until { listener.isListening }
        #expect(listener.starts == 2)
        #expect(listener.overlappingStarts == 0)
    }

    @Test("a start failure is reported once and not retried until re-enabled")
    func failureNoRetryStorm() async {
        let (controller, listener, coordinator, _) = make()
        listener.fail(with: .speechRecognitionDenied)
        controller.setEnabled(true)
        await until { if case .unavailable = controller.status { return true }; return false }
        #expect(controller.status == .unavailable(WakeWordListenerError.speechRecognitionDenied.localizedDescription))

        await coordinator.startSession()
        await coordinator.stopSession()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(listener.starts == 0)

        listener.fail(with: nil)
        controller.setEnabled(false)
        controller.setEnabled(true)
        await until { controller.status == .listening }
        #expect(listener.starts == 1)
    }

    @Test("disabling and shutdown release the microphone")
    func disableAndShutdown() async {
        let (controller, listener, _, _) = make()
        controller.setEnabled(true)
        await until { listener.isListening }
        controller.setEnabled(false)
        await until { !listener.isListening && controller.status == .off }
        #expect(controller.status == .off)

        controller.setEnabled(true)
        await until { listener.isListening }
        await controller.shutdown()
        #expect(!listener.isListening)
        #expect(controller.status == .off)
    }

    @Test("shutdown during an in-flight start still leaves the microphone closed")
    func shutdownDuringStart() async {
        let (controller, listener, _, _) = make()
        controller.setEnabled(true) // start is queued, not yet completed
        await controller.shutdown()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(!listener.isListening)
        #expect(controller.status == .off)
    }

    @Test("rapid session flips never run two taps at once")
    func rapidFlips() async {
        let (controller, listener, coordinator, _) = make()
        controller.setEnabled(true)
        await until { listener.isListening }
        for _ in 0..<5 {
            await coordinator.startSession()
            await coordinator.stopSession()
        }
        await until { listener.isListening }
        #expect(listener.overlappingStarts == 0)
        #expect(controller.status == .listening)
    }

    @Test("the app environment follows the persisted setting and the live toggle")
    func environmentFollowsSetting() async {
        let listener = MockWakeWordListener()
        var saved = IvySettings.defaults
        saved.wakeWordEnabled = true
        let env = IvyAppEnvironment(
            settingsStore: InMemorySettingsStore(saved),
            credentials: FixedCredentialProvider([:]),
            conversationStore: InMemoryConversationStore(),
            voiceManager: VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: MockAudioPlayer()),
            wakeWordListener: listener
        ) { _, _ in
            GeminiLiveVoiceCoordinator(session: MockGeminiLiveSession(), audioCapture: MockAudioCapture(),
                                       audioPlayer: MockLiveAudioPlayer(), wakeWordDetector: MockWakeWordDetector())
        }
        await until { listener.isListening && env.wakeWord.status == .listening }
        #expect(env.wakeWord.status == .listening)

        env.settings.settings.wakeWordEnabled = false
        await until { !listener.isListening && env.wakeWord.status == .off }
        #expect(!listener.isListening)
        #expect(env.wakeWord.status == .off)
        await env.shutdown()
    }

    @Test("the setting defaults to off and survives a round trip")
    func settingPersistence() throws {
        #expect(IvySettings.defaults.wakeWordEnabled == false)
        var s = IvySettings.defaults
        s.wakeWordEnabled = true
        let decoded = try JSONDecoder().decode(IvySettings.self, from: JSONEncoder().encode(s))
        #expect(decoded.wakeWordEnabled)
        let legacy = try JSONDecoder().decode(IvySettings.self, from: Data(#"{"echoCancellation": false}"#.utf8))
        #expect(legacy.wakeWordEnabled == false)
    }
}
