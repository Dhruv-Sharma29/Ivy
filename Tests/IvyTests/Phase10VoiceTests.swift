import Testing
import Foundation
import os
@testable import IvyCore

// MARK: - Fixtures and fakes

/// 16 kHz 16-bit mono PCM of a 220 Hz tone at the given peak amplitude.
private func tone(amplitude: Double, milliseconds: Int) -> Data {
    var data = Data(capacity: milliseconds * 32)
    for i in 0..<(milliseconds * 16) {
        let sample = Int16(amplitude * sin(2 * .pi * 220 * Double(i) / 16000))
        withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

private let loud = tone(amplitude: 12000, milliseconds: 40)
private let quiet = Data(repeating: 0, count: 1280)

/// A Live session whose `connect()` waits until the test opens the gate (a slow network).
private final class GatedLiveSession: GeminiLiveSession, @unchecked Sendable {
    let inner = MockGeminiLiveSession()
    private struct Gate {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private let gate = OSAllocatedUnfairLock(initialState: Gate())
    var isWaitingToConnect: Bool { gate.withLock { !$0.waiters.isEmpty } }

    func open() {
        let waiters = gate.withLock { g -> [CheckedContinuation<Void, Never>] in
            g.isOpen = true
            defer { g.waiters = [] }
            return g.waiters
        }
        waiters.forEach { $0.resume() }
    }

    func connect() async throws {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let ready = gate.withLock { g -> Bool in
                if g.isOpen { return true }
                g.waiters.append(c)
                return false
            }
            if ready { c.resume() }
        }
        try await inner.connect()
    }

    func sendAudio(_ data: Data) async throws { try await inner.sendAudio(data) }
    func endAudioInput() async throws { try await inner.endAudioInput() }
    func sendToolResponses(_ responses: [FunctionResponse]) async throws { try await inner.sendToolResponses(responses) }
    func receiveEvents() -> AsyncThrowingStream<LiveEvent, Error> { inner.receiveEvents() }
    func disconnect() async { await inner.disconnect() }
}

/// Holds the return from capture startup after audio can already be queued, exposing the release race.
private actor GatedAudioCapture: AudioCaptureProtocol {
    nonisolated let inner = MockAudioCapture()
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func resumeStart() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }

    func requestPermission() async -> Bool { await inner.requestPermission() }
    func startCapture() async throws -> AsyncThrowingStream<Data, Error> {
        let stream = try await inner.startCapture()
        if !isOpen { await withCheckedContinuation { waiter = $0 } }
        return stream
    }
    func stopCapture() async { await inner.stopCapture() }
}

/// Idle listener fake with a pre-roll to hand over.
private final class PreRollWakeListener: WakeWordListening, @unchecked Sendable {
    private struct State {
        var listening = false
        var starts = 0
        var onWake: (@Sendable () -> Void)?
        var preRoll = Data()
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isListening: Bool { state.withLock { $0.listening } }
    var starts: Int { state.withLock { $0.starts } }
    func setPreRoll(_ data: Data) { state.withLock { $0.preRoll = data } }

    func start(onWake: @escaping @Sendable () -> Void) async throws {
        state.withLock { s in
            s.listening = true
            s.starts += 1
            s.onWake = onWake
        }
    }

    func stop() async {
        state.withLock { s in
            s.listening = false
            s.onWake = nil
        }
    }

    func takePreRoll() -> Data {
        state.withLock { s in
            defer { s.preRoll = Data() }
            return s.preRoll
        }
    }

    /// Like the real listener: stops itself, then reports the wake.
    func fireWake() {
        let onWake = state.withLock { s -> (@Sendable () -> Void)? in
            defer { s.onWake = nil }
            s.listening = false
            return s.onWake
        }
        onWake?()
    }
}

private final class Phase10URLProtocol: URLProtocol, @unchecked Sendable {
    static let bodies = OSAllocatedUnfairLock(initialState: [Data]())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.bodies.withLock { $0.append(request.extractBodyData() ?? Data()) }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x49, 0x44, 0x33]))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
private func makeCoordinator(
    dispatcher: ToolDispatcher? = nil, autoDrain: Bool = true, wakeSilenceTimeout: Duration = .seconds(30)
) -> (GeminiLiveVoiceCoordinator, MockGeminiLiveSession, MockAudioCapture, MockLiveAudioPlayer, MockWakeWordDetector) {
    let session = MockGeminiLiveSession()
    let capture = MockAudioCapture()
    let player = MockLiveAudioPlayer(autoDrain: autoDrain)
    let detector = MockWakeWordDetector()
    let c = GeminiLiveVoiceCoordinator(session: session, audioCapture: capture, audioPlayer: player, wakeWordDetector: detector,
                                       toolDispatcher: dispatcher, wakeSilenceTimeout: wakeSilenceTimeout)
    return (c, session, capture, player, detector)
}

// MARK: - 10.1 Turn-taking

@Suite("Phase 10.1 - Turn-taking")
@MainActor
struct Phase10TurnTakingTests {
    @Test("silence is not speech, a voice is, and speech holds through the gaps between words")
    func vadBasics() {
        var vad = VoiceActivityDetector()
        let heard1 = vad.process(quiet)
        #expect(!heard1)
        #expect(!vad.isSpeech)
        #expect(vad.level == 0)

        let heard2 = vad.process(loud)
        #expect(heard2)
        #expect(vad.isSpeech)
        #expect(vad.level > 0.3)

        // 100 ms gap between words: still speaking. 400 ms of silence: done.
        vad.process(Data(repeating: 0, count: 3200))
        #expect(vad.isSpeech)
        vad.process(Data(repeating: 0, count: 12800))
        #expect(!vad.isSpeech)
        let heard3 = vad.process(Data([0xFF]))
        #expect(!heard3) // malformed odd byte
    }

    @Test("the noise floor adapts: a steady loud room stops counting as speech, a voice over it still does")
    func vadAdaptsToNoise() {
        var vad = VoiceActivityDetector()
        let fan = tone(amplitude: 1400, milliseconds: 1000) // RMS ≈ 1000
        let heard4 = vad.process(fan)
        #expect(heard4) // at first it stands out
        for _ in 0..<15 { vad.process(fan) }
        let heard5 = vad.process(fan)
        #expect(!heard5)
        #expect(!vad.isSpeech)
        #expect(vad.noiseFloor > 300)
        let heard6 = vad.process(tone(amplitude: 12000, milliseconds: 40))
        #expect(heard6)

        // A quiet room brings the floor back down.
        for _ in 0..<10 { vad.process(Data(repeating: 0, count: 32000)) }
        #expect(vad.noiseFloor < 50)
    }

    @Test("patience maps to the server's end-of-speech silence; normal sends nothing")
    func patienceInSetup() throws {
        #expect(VoicePatience.short.silenceDurationMs == 300)
        #expect(VoicePatience.normal.silenceDurationMs == nil)
        #expect(VoicePatience.long.silenceDurationMs == 1500)

        let long = String(decoding: try JSONEncoder().encode(BidiSetup(silenceDurationMs: 1500)), as: UTF8.self)
        #expect(long.contains("\"realtimeInputConfig\":{\"automaticActivityDetection\":{\"silenceDurationMs\":1500}}"))
        let normal = String(decoding: try JSONEncoder().encode(BidiSetup()), as: UTF8.self)
        #expect(!normal.contains("realtimeInputConfig"))

        let client = GeminiLiveClient(apiKey: "k", silenceDurationMs: VoicePatience.short.silenceDurationMs)
        #expect(client.silenceDurationMs == 300)
    }

    @Test("the coordinator reports when it hears the user, only while listening")
    func hearingUser() async {
        let (c, session, capture, _, _) = makeCoordinator()
        await c.startSession()
        #expect(!c.isHearingUser)

        capture.simulateAudioChunk(loud)
        #expect(await waitUntil { c.isHearingUser })
        capture.simulateAudioChunk(Data(repeating: 0, count: 16000))
        #expect(await waitUntil { !c.isHearingUser })

        // While Ivy is speaking the user's voice is a possible barge-in, not "hearing you".
        session.simulateEvent(.audioChunk(Data([1, 0, 1, 0])))
        await waitUntil { c.state == .speaking }
        capture.simulateAudioChunk(loud)
        await waitUntil { c.levelMeter.inputLevel > 0 }
        #expect(!c.isHearingUser)
        await c.stopSession()
        #expect(!c.isHearingUser)
    }
}

// MARK: - 10.2 Barge-in

@Suite("Phase 10.2 - Barge-in")
@MainActor
struct Phase10BargeInTests {
    @Test("a lone \"Ivy\" interrupts only when the setting is on and the user is audibly speaking")
    func loneIvy() async {
        #expect(WakePhraseMatcher.containsIvy("no, Ivy, wait"))
        #expect(!WakePhraseMatcher.containsIvy("ivyberry is a plant"))

        let (c, session, capture, player, _) = makeCoordinator(autoDrain: false)
        await c.startSession()
        session.simulateEvent(.audioChunk(Data([1, 0, 1, 0])))
        await waitUntil { c.state == .speaking }

        // Setting off (the default): nothing.
        capture.simulateAudioChunk(loud)
        await waitUntil { c.levelMeter.inputLevel > 0 }
        await c.processTranscriptionForInterruption("ivy wait")
        #expect(c.state == .speaking)

        // Setting on, but the room is quiet (the recognizer heard Ivy's own voice): nothing.
        c.loneIvyInterrupts = true
        capture.simulateAudioChunk(Data(repeating: 0, count: 16000))
        await waitUntil { c.levelMeter.inputLevel == 0 }
        await c.processTranscriptionForInterruption("ivy wait")
        #expect(c.state == .speaking)

        // Setting on and the user is speaking: interrupts.
        capture.simulateAudioChunk(loud)
        await waitUntil { c.levelMeter.inputLevel > 0 }
        await c.processTranscriptionForInterruption("ivy wait")
        #expect(c.state == .listening)
        #expect(player.isStopped)
        await c.stopSession()
    }
}

// MARK: - 10.3 Pre-roll

@Suite("Phase 10.3 - Wake pre-roll")
@MainActor
struct Phase10PreRollTests {
    @Test("the ring buffer keeps only the most recent audio and empties when drained")
    func ringBuffer() {
        var ring = PCMRingBuffer(seconds: 0.5)
        #expect(ring.capacity == 16000 && ring.isEmpty)
        ring.append(Data(repeating: 1, count: 10000))
        ring.append(Data(repeating: 2, count: 10000))
        #expect(ring.count == 16000)
        let held = ring.drain()
        #expect(held.prefix(6000).allSatisfy { $0 == 1 } && held.suffix(10000).allSatisfy { $0 == 2 })
        #expect(ring.isEmpty && ring.drain().isEmpty)
    }

    @Test("what the user says while the socket is still connecting is sent first, in order")
    func speechDuringConnect() async {
        let session = GatedLiveSession()
        let capture = MockAudioCapture()
        let c = GeminiLiveVoiceCoordinator(session: session, audioCapture: capture, audioPlayer: MockLiveAudioPlayer(),
                                           wakeWordDetector: MockWakeWordDetector())
        let start = Task { await c.startSession() }
        #expect(await waitUntil { capture.isCapturing })
        #expect(c.state == .connecting)

        let early = Data(repeating: 7, count: 640), later = Data(repeating: 9, count: 640)
        capture.simulateAudioChunk(early)
        await waitUntil { capture.capturedChunksCount == 1 }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(session.inner.sentAudioChunks.isEmpty) // nothing leaves before the socket is up

        session.open()
        await start.value
        #expect(c.state == .listening)
        capture.simulateAudioChunk(later)
        #expect(await waitUntil { session.inner.sentAudioChunks.count == 2 })
        #expect(session.inner.sentAudioChunks == [early, later])
        await c.stopSession()
    }

    @Test("a failed connect releases the microphone opened for pre-roll")
    func failedConnectReleasesMic() async {
        let session = MockGeminiLiveSession(connectError: LiveError.connectionFailed("offline"))
        let capture = MockAudioCapture()
        let c = GeminiLiveVoiceCoordinator(session: session, audioCapture: capture, audioPlayer: MockLiveAudioPlayer(),
                                           wakeWordDetector: MockWakeWordDetector())
        await c.startSession()
        guard case .error = c.state else {
            Issue.record("expected an error state, got \(c.state)")
            return
        }
        #expect(!capture.isCapturing)
        #expect(c.activeTaskCount == 0)
    }

    @Test("\"Hey Ivy, <request>\" in one breath: the listener's pre-roll reaches the wake session before live audio")
    func listenerPreRollIsForwarded() async {
        let (c, session, capture, _, _) = makeCoordinator()
        let listener = PreRollWakeListener()
        let controller = WakeWordController(listener: listener, coordinator: c)
        controller.setEnabled(true)
        #expect(await waitUntil { listener.isListening })

        let breath = Data(repeating: 5, count: 20000) // 0.625 s, sent in quarter-second frames
        listener.setPreRoll(breath)
        listener.fireWake()
        #expect(await waitUntil { c.state == .listening })
        #expect(controller.wakeCount == 1)

        let live = Data(repeating: 6, count: 640)
        capture.simulateAudioChunk(live)
        #expect(await waitUntil { session.sentAudioChunks.count == 4 })
        #expect(session.sentAudioChunks.map(\.count) == [8000, 8000, 4000, 640])
        #expect(session.sentAudioChunks.dropLast().reduce(Data(), +) == breath)
        #expect(listener.takePreRoll().isEmpty) // handed over once, not kept
        await c.stopSession()
        await controller.shutdown()
    }

    @Test("a wake that hears no request is counted as a likely false trigger and shows in diagnostics")
    func unansweredWakeCounted() async {
        let (c, _, _, _, _) = makeCoordinator(wakeSilenceTimeout: .milliseconds(30))
        let listener = PreRollWakeListener()
        let controller = WakeWordController(listener: listener, coordinator: c)
        controller.setEnabled(true)
        await waitUntil { listener.isListening }
        listener.fireWake()
        #expect(await waitUntil(timeout: .seconds(5)) { controller.unansweredWakeCount == 1 })
        #expect(await waitUntil { c.state == .idle })

        let report = DiagnosticsReport.build(
            settings: .defaults, credentials: FixedCredentialProvider([:]), permissions: MockPermissionManager(),
            logTail: nil, crashReportCount: 0, wakeStats: (controller.wakeCount, controller.unansweredWakeCount))
        #expect(report.contains("fired 1, no request heard after 1"))
        await controller.shutdown()
    }
}

// MARK: - 10.4 Levels

@Suite("Phase 10.4 - Audio levels")
@MainActor
struct Phase10LevelTests {
    @Test("levels are 0…1 and louder audio reads higher")
    func levelScale() {
        #expect(VoiceActivityDetector.level(of: quiet) == 0)
        #expect(VoiceActivityDetector.level(of: Data()) == 0)
        let soft = VoiceActivityDetector.level(of: tone(amplitude: 800, milliseconds: 40))
        let strong = VoiceActivityDetector.level(of: tone(amplitude: 20000, milliseconds: 40))
        #expect(soft > 0.05 && soft < strong && strong <= 1)
    }

    @Test("a flood of reports publishes at most ~30 times a second and the last value lands")
    func meterThrottles() async {
        let meter = AudioLevelMeter()
        var publishes = 0
        let watch = meter.$inputLevel.dropFirst().sink { _ in publishes += 1 }
        let clock = ContinuousClock()
        let started = clock.now
        // 500 reports over ~250 ms, from a background thread like the audio tap.
        await Task.detached {
            for i in 0..<500 {
                meter.reportInput(Float(i % 100) / 100)
                try? await Task.sleep(for: .microseconds(500))
            }
            meter.reportInput(0.42)
        }.value
        #expect(await waitUntil { meter.inputLevel == 0.42 })
        let seconds = Double((clock.now - started).components.attoseconds) / 1e18 + Double((clock.now - started).components.seconds)
        #expect(publishes >= 1)
        #expect(Double(publishes) <= seconds * 30 + 3, "\(publishes) publishes in \(seconds)s")

        meter.reportOutput(0.9)
        #expect(await waitUntil { meter.outputLevel == 0.9 })
        meter.reset()
        #expect(await waitUntil { meter.inputLevel == 0 && meter.outputLevel == 0 })
        watch.cancel()
    }

    @Test("Ivy's level follows the reply as it plays and drops to zero when playback stops")
    func outputLevelFollowsPlayback() async {
        let (c, session, _, _, _) = makeCoordinator(autoDrain: false)
        await c.startSession()
        session.simulateEvent(.audioChunk(tone(amplitude: 15000, milliseconds: 300)))
        #expect(await waitUntil { c.levelMeter.outputLevel > 0.3 })
        await c.handleWakePhraseDetected()
        #expect(await waitUntil { c.levelMeter.outputLevel == 0 })
        await c.stopSession()
        #expect(c.activeTaskCount == 0)
    }
}

// MARK: - 10.5 Voice settings

@Suite("Phase 10.5 - Voice settings", .serialized)
@MainActor
struct Phase10VoiceSettingsTests {
    private func synthesizer(_ settings: @escaping @Sendable () -> ElevenLabsVoiceSettings) -> ElevenLabsSpeechSynthesizer {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Phase10URLProtocol.self]
        return ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: "test-key"),
                                           session: URLSession(configuration: config), voiceSettings: settings)
    }

    @Test("untouched settings send no voice_settings; changed ones are sent, clamped, and picked up per request")
    func ttsPayload() async throws {
        Phase10URLProtocol.bodies.withLock { $0 = [] }
        let box = OSAllocatedUnfairLock(initialState: ElevenLabsVoiceSettings())
        let tts = synthesizer { box.withLock { $0 } }

        _ = try await tts.synthesize(text: "one")
        box.withLock { $0 = ElevenLabsVoiceSettings(speed: 5, stability: 0.8, style: -1) }
        _ = try await tts.synthesize(text: "two")

        let bodies = try Phase10URLProtocol.bodies.withLock { $0 }.map { try #require(try JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
        #expect(bodies.count == 2)
        #expect(bodies[0]["voice_settings"] == nil)
        #expect(bodies[0]["text"] as? String == "one")
        #expect(bodies[0]["model_id"] as? String == "eleven_turbo_v2_5")
        let sent = try #require(bodies[1]["voice_settings"] as? [String: Double])
        #expect(sent == ["speed": 1.2, "stability": 0.8, "style": 0])
    }

    @Test("new settings persist, and an older or damaged blob falls back field by field")
    func settingsPersist() throws {
        var s = IvySettings.defaults
        #expect(s.voicePatience == .normal && s.ttsVoiceSettings.isDefault && s.pauseWakeWordWhenLocked && !s.loneIvyBargeIn)
        s.voicePatience = .long
        s.voiceResponseLength = .brief
        s.voiceSpeakingPace = .fast
        s.ttsSpeed = 0.9
        s.ttsStability = 0.3
        s.ttsStyle = 0.4
        s.pauseWakeWordWhenLocked = false
        let suite = "ivy-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try UserDefaultsSettingsStore(defaults: defaults).save(s)
        #expect(UserDefaultsSettingsStore(defaults: defaults).load() == s)

        let damaged = #"{"voicePatience":"forever","ttsSpeed":"fast","voiceSpeakingPace":"slow","wakeWordEnabled":true}"#
        let decoded = try JSONDecoder().decode(IvySettings.self, from: Data(damaged.utf8))
        #expect(decoded.voicePatience == .normal && decoded.ttsSpeed == 1.0)
        #expect(decoded.voiceSpeakingPace == .slow && decoded.wakeWordEnabled)
    }

    @Test("length and pace only add text to the instruction; the Live voice is still Kore")
    func liveStyleKeepsKore() throws {
        #expect(LiveVoiceStyle.instruction(base: "BASE", length: .normal, pace: .normal) == "BASE")
        let styled = LiveVoiceStyle.instruction(base: "BASE", length: .brief, pace: .slow)
        #expect(styled.hasPrefix("BASE\n\nSpeaking style: "))
        #expect(styled.contains("one or two short sentences") && styled.contains("slowly"))

        let client = GeminiLiveClient(apiKey: "k", voiceName: "Puck", systemInstruction: styled, silenceDurationMs: 300)
        #expect(client.voiceName == "Kore")
        let setup = BidiSetup(generationConfig: BidiGenerationConfig(speechConfig: BidiSpeechConfig(
            voiceConfig: BidiVoiceConfig(prebuiltVoiceConfig: BidiPrebuiltVoiceConfig(voiceName: "Puck")))),
                              systemInstruction: BidiSystemInstruction(text: styled), transcribesAudio: true, silenceDurationMs: 300)
        let json = String(decoding: try JSONEncoder().encode(setup), as: UTF8.self)
        #expect(json.contains("\"voiceName\":\"Kore\"") && !json.contains("Puck"))
        #expect(json.contains("models\\/gemini-3.1-flash-live-preview") || json.contains("models/gemini-3.1-flash-live-preview"))
    }
}

// MARK: - 10.7 Sleep, wake, lock

@Suite("Phase 10.7 - Sleep, wake and lock")
@MainActor
struct Phase10PowerTests {
    private func make(_ settings: IvySettings, dispatcher: ToolDispatcher? = nil)
        -> (IvyAppEnvironment, MockGeminiLiveSession, PreRollWakeListener) {
        let session = MockGeminiLiveSession()
        let listener = PreRollWakeListener()
        let env = IvyAppEnvironment(settingsStore: InMemorySettingsStore(settings), credentials: FixedCredentialProvider([.geminiAPIKey: "k"]),
                                    conversationStore: InMemoryConversationStore(), geminiClient: RecordingGeminiClient(),
                                    wakeWordListener: listener) { _, _ in
            GeminiLiveVoiceCoordinator(session: session, audioCapture: MockAudioCapture(), audioPlayer: MockLiveAudioPlayer(),
                                       wakeWordDetector: MockWakeWordDetector(), toolDispatcher: dispatcher)
        }
        return (env, session, listener)
    }

    private var wakeOn: IvySettings {
        var s = IvySettings.defaults
        s.wakeWordEnabled = true
        s.pushToTalkEnabled = false
        return s
    }

    @Test("sleep during Live ends the session, denies a pending approval and releases the mic; waking resumes only \"Hey Ivy\"")
    func sleepDuringLive() async throws {
        let shell = MockShellExecutor()
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [RunShellTool(executor: shell)]),
                                        safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))
        let (env, session, listener) = make(wakeOn, dispatcher: dispatcher)
        #expect(await waitUntil { listener.isListening })

        await env.liveCoordinator.startSession()
        #expect(await waitUntil { !listener.isListening }) // Live owns the mic
        session.simulateEvent(.toolCall(FunctionCall(name: "run_shell", args: ["command": "rm -rf ~/x"], id: "s1")))
        try #require(await waitUntil { env.liveCoordinator.pendingConfirmation != nil })

        await env.handle(.willSleep)
        #expect(env.liveCoordinator.state == .idle)
        #expect(env.liveCoordinator.pendingConfirmation == nil)
        #expect(shell.recordedCommands.isEmpty)
        #expect(env.liveCoordinator.activeTaskCount == 0)
        await env.wakeWord.waitUntilSettled()
        #expect(!listener.isListening) // asleep: no microphone at all

        let startsBefore = listener.starts
        await env.handle(.didWake)
        #expect(await waitUntil { listener.isListening })
        #expect(listener.starts == startsBefore + 1)
        #expect(env.liveCoordinator.state == .idle) // a Live session is never restarted by itself
        await env.shutdown()
    }

    @Test("a locked screen pauses \"Hey Ivy\" and unlocking resumes it; the setting turns that off")
    func screenLock() async {
        let (env, _, listener) = make(wakeOn)
        #expect(await waitUntil { listener.isListening })
        await env.handle(.screenLocked)
        #expect(await waitUntil { !listener.isListening })
        #expect(await waitUntil { env.wakeWord.status == .paused })
        await env.handle(.screenUnlocked)
        #expect(await waitUntil { listener.isListening })

        // Sleep and lock are independent reasons: both must clear.
        await env.handle(.screenLocked)
        await env.handle(.willSleep)
        await env.handle(.didWake)
        await env.wakeWord.waitUntilSettled()
        #expect(!listener.isListening)
        await env.handle(.screenUnlocked)
        #expect(await waitUntil { listener.isListening })
        await env.shutdown()

        var keepListening = wakeOn
        keepListening.pauseWakeWordWhenLocked = false
        let (env2, _, listener2) = make(keepListening)
        #expect(await waitUntil { listener2.isListening })
        await env2.handle(.screenLocked)
        await env2.wakeWord.waitUntilSettled()
        #expect(listener2.isListening)
        await env2.shutdown()
    }

    @Test("with \"Hey Ivy\" off, waking the Mac opens no microphone")
    func wakeWithSettingOff() async {
        var off = IvySettings.defaults
        off.pushToTalkEnabled = false
        let (env, _, listener) = make(off)
        await env.handle(.willSleep)
        await env.handle(.didWake)
        await env.wakeWord.waitUntilSettled()
        #expect(listener.starts == 0)
        await env.shutdown()
    }
}

// MARK: - 10.8 Local voice commands

@Suite("Phase 10.8 - Local voice commands")
@MainActor
struct Phase10CommandTests {
    @Test("the allow-list: what is and is not a command")
    func parsing() {
        #expect(VoiceCommand.parse("Hey Ivy, stop.") == .stop)
        #expect(VoiceCommand.parse("hey ivy cancel") == .cancel)
        #expect(VoiceCommand.parse("Hey Ivy, never mind") == .cancel)
        #expect(VoiceCommand.parse("hey ivy end") == .endSession)
        #expect(VoiceCommand.parse("Hey, Ivy — goodbye!") == .endSession)
        #expect(VoiceCommand.parse("A Ivy mute") == .mute) // "hey" as the recognizer often hears it
        #expect(VoiceCommand.parse("hey ivy unmute") == .unmute)
        #expect(VoiceCommand.parse("hey ivy repeat that") == .repeatLast)

        // Right after a barge-in the wake phrase was already said.
        #expect(VoiceCommand.parse("stop", afterWake: true) == .stop)
        #expect(VoiceCommand.parse("Repeat that.", afterWake: true) == .repeatLast)

        // Without "Hey Ivy" only a goodbye counts; ordinary speech is left to Gemini.
        #expect(VoiceCommand.parse("Goodbye.") == .endSession)
        #expect(VoiceCommand.parse("bye") == .endSession)
        #expect(VoiceCommand.parse("stop") == nil)
        #expect(VoiceCommand.parse("end") == nil)
        #expect(VoiceCommand.parse("cancel") == nil)
        #expect(VoiceCommand.parse("mute") == nil)
        #expect(VoiceCommand.parse("hey ivy stop the music") == nil)
        #expect(VoiceCommand.parse("hey ivy cancel my meeting", afterWake: true) == nil)
        #expect(VoiceCommand.parse("say goodbye to her for me") == nil)
        #expect(VoiceCommand.parse("") == nil)
    }

    @Test("no phrase approves: yes, confirm, do it, approve are never commands")
    func nothingApproves() {
        for phrase in ["yes", "yeah", "confirm", "do it", "approve", "go ahead", "ok", "allow", "run it"] {
            #expect(VoiceCommand.parse(phrase) == nil)
            #expect(VoiceCommand.parse("hey ivy \(phrase)") == nil)
            #expect(VoiceCommand.parse(phrase, afterWake: true) == nil)
        }
    }

    @Test("after a barge-in, \"stop\" is handled locally: Ivy does not answer it, and the next request is normal")
    func stopAfterBargeIn() async {
        let (c, session, _, player, _) = makeCoordinator()
        var transcripts: [String] = []
        c.onTranscript = { text, _, _ in transcripts.append(text) }
        await c.startSession()

        session.simulateEvent(.audioChunk(Data([1, 0])))
        await waitUntil { c.state == .speaking }
        await c.handleWakePhraseDetected()
        #expect(c.state == .listening)
        session.simulateEvent(.turnComplete) // the interrupted turn closes

        session.simulateEvent(.inputTranscript("Stop."))
        session.simulateEvent(.audioChunk(Data([2, 0]))) // Gemini answering the word "stop"
        session.simulateEvent(.outputTranscript("Okay, stopping."))
        session.simulateEvent(.turnComplete)

        session.simulateEvent(.inputTranscript("what time is it"))
        session.simulateEvent(.audioChunk(Data([3, 0])))
        session.simulateEvent(.outputTranscript("Noon."))
        session.simulateEvent(.turnComplete)
        #expect(await waitUntil { transcripts.contains("Noon.") })

        #expect(player.playedChunks == [Data([1, 0]), Data([3, 0])])
        #expect(transcripts == ["what time is it", "Noon."])
        await c.stopSession()
    }

    @Test("\"stop\" without \"Hey Ivy\" is ordinary speech and is answered")
    func bareStopIsNotACommand() async {
        let (c, session, _, player, _) = makeCoordinator()
        await c.startSession()
        session.simulateEvent(.inputTranscript("stop"))
        session.simulateEvent(.audioChunk(Data([4, 0])))
        #expect(await waitUntil { player.playedChunks == [Data([4, 0])] })
        await c.stopSession()
    }

    @Test("\"Hey Ivy, goodbye\" and a plain \"goodbye\" end the session without a spoken reply")
    func goodbyeEndsSession() async {
        for phrase in ["Hey Ivy, goodbye", "Goodbye."] {
            let (c, session, capture, player, _) = makeCoordinator()
            await c.startSession()
            session.simulateEvent(.inputTranscript(phrase))
            session.simulateEvent(.audioChunk(Data([5, 0])))
            #expect(await waitUntil { c.state == .idle })
            #expect(player.playedChunks.isEmpty)
            #expect(!capture.isCapturing)
            #expect(c.activeTaskCount == 0)
        }
    }

    @Test("\"Hey Ivy\" while a tool turn is in progress abandons it: its speech is dropped and its further tools never run")
    func cancelDuringToolTurn() async throws {
        let shell = MockShellExecutor()
        let gate = OSAllocatedUnfairLock(initialState: [CheckedContinuation<Bool, Never>]())
        let dispatcher = ToolDispatcher(
            registry: ToolRegistry(tools: [RunShellTool(executor: shell)]),
            safetyGate: InteractiveSafetyGate(confirmationProvider: ClosureConfirmationProvider { _ in
                await withCheckedContinuation { c in gate.withLock { $0.append(c) } }
            }))
        let (c, session, capture, player, detector) = makeCoordinator(dispatcher: dispatcher)
        await c.startSession()

        session.simulateEvent(.toolCall(FunctionCall(name: "run_shell", args: ["command": "sleep 1"], id: "a")))
        let asked = await waitUntil { gate.withLock { $0.count } == 1 }
        try #require(asked)
        #expect(c.state == .thinking)

        // The mic is monitored for "Hey Ivy" here, not streamed.
        detector.setShouldTrigger(true)
        capture.simulateAudioChunk(loud)
        #expect(await waitUntil { c.state == .listening })
        #expect(session.sentAudioChunks.isEmpty)

        // The turn's later tool call is refused without running; its speech is never played.
        session.simulateEvent(.toolCall(FunctionCall(name: "run_shell", args: ["command": "rm -rf ~/y"], id: "b")))
        #expect(await waitUntil { session.sentToolResponses.contains { $0.id == "b" } })
        #expect(session.sentToolResponses.first { $0.id == "b" }?.response["error"]?.stringValue == "Cancelled by the user.")
        session.simulateEvent(.inputTranscript("cancel"))
        session.simulateEvent(.audioChunk(Data([6, 0])))
        session.simulateEvent(.turnComplete)

        // Releasing the first tool's gate as a denial: nothing was ever executed.
        gate.withLock { $0 }.forEach { $0.resume(returning: false) }
        session.simulateEvent(.inputTranscript("what time is it"))
        session.simulateEvent(.audioChunk(Data([7, 0])))
        #expect(await waitUntil { player.playedChunks == [Data([7, 0])] })
        #expect(shell.recordedCommands.isEmpty)
        await c.stopSession()
    }

    @Test("during a confirmation, spoken words never approve: \"Hey Ivy, cancel\" denies and nothing runs")
    func cancelDuringConfirmationDenies() async throws {
        let shell = MockShellExecutor()
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [RunShellTool(executor: shell)]),
                                        safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))
        let (c, session, capture, _, detector) = makeCoordinator(dispatcher: dispatcher)
        await c.startSession()
        session.simulateEvent(.toolCall(FunctionCall(name: "run_shell", args: ["command": "rm -rf ~/z"], id: "c")))
        try #require(await waitUntil { c.state == .toolConfirmation })

        // Anything the transcript says while the card is up changes nothing.
        for phrase in ["yes", "hey ivy yes do it", "confirm", "approve"] {
            session.simulateEvent(.inputTranscript(phrase))
            session.simulateEvent(.outputTranscript("…"))
        }
        capture.simulateAudioChunk(loud)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(c.pendingConfirmation != nil)
        #expect(shell.recordedCommands.isEmpty)
        #expect(session.sentAudioChunks.isEmpty) // the mic is not streamed during a confirmation

        detector.setShouldTrigger(true)
        capture.simulateAudioChunk(loud)
        #expect(await waitUntil { c.pendingConfirmation == nil })
        #expect(await waitUntil { c.state == .listening })
        #expect(shell.recordedCommands.isEmpty)
        await c.stopSession()
    }

    @Test("mute stops streaming the microphone until \"Hey Ivy\"")
    func muteAndUnmute() async {
        let (c, session, capture, _, detector) = makeCoordinator()
        await c.startSession()
        session.simulateEvent(.inputTranscript("Hey Ivy, mute"))
        session.simulateEvent(.audioChunk(Data([8, 0])))
        session.simulateEvent(.turnComplete)
        #expect(await waitUntil { c.isMuted })
        #expect(c.state == .listening)

        capture.simulateAudioChunk(loud)
        #expect(await waitUntil { detector.processedChunksCount == 1 })
        #expect(session.sentAudioChunks.isEmpty)
        #expect(!c.isHearingUser)

        detector.setShouldTrigger(true)
        capture.simulateAudioChunk(loud)
        #expect(await waitUntil { !c.isMuted })
        capture.simulateAudioChunk(loud)
        #expect(await waitUntil { session.sentAudioChunks.count == 1 })

        // The word "unmute" that follows is not answered either.
        session.simulateEvent(.inputTranscript("unmute"))
        session.simulateEvent(.audioChunk(Data([9, 0])))
        session.simulateEvent(.turnComplete)
        session.simulateEvent(.inputTranscript("hello"))
        session.simulateEvent(.outputTranscript("Hi."))
        session.simulateEvent(.turnComplete)
        await c.stopSession()
        #expect(!c.isMuted)
    }

    @Test("\"repeat that\" replays the last reply from memory instead of a new answer")
    func repeatThat() async {
        let (c, session, _, player, _) = makeCoordinator()
        await c.startSession()
        let a = Data([10, 0]), b = Data([11, 0])
        session.simulateEvent(.inputTranscript("what's the plan"))
        session.simulateEvent(.audioChunk(a))
        session.simulateEvent(.audioChunk(b))
        session.simulateEvent(.turnComplete)
        #expect(await waitUntil { c.state == .listening })

        session.simulateEvent(.inputTranscript("Hey Ivy, repeat that"))
        session.simulateEvent(.audioChunk(Data([12, 0]))) // Gemini's own attempt, dropped
        session.simulateEvent(.turnComplete)
        #expect(await waitUntil { player.playedChunks == [a, b, a, b] })
        #expect(await waitUntil { c.state == .listening })

        // Nothing to repeat in a fresh session: the command is still swallowed, nothing plays.
        await c.stopSession()
        player.reset()
        await c.startSession()
        session.simulateEvent(.inputTranscript("hey ivy repeat that"))
        session.simulateEvent(.audioChunk(Data([13, 0])))
        session.simulateEvent(.turnComplete)
        session.simulateEvent(.inputTranscript("hi"))
        session.simulateEvent(.audioChunk(Data([14, 0])))
        #expect(await waitUntil { player.playedChunks == [Data([14, 0])] })
        await c.stopSession()
    }
}


@Suite("Push-to-talk release submits a voice request")
@MainActor
struct PushToTalkSubmissionTests {
    @Test("PTT replies use output-only playback; hands-free sessions keep echo-cancelled playback", arguments: [true, false])
    func selectsPlaybackEngine(pushToTalk: Bool) async {
        let session = MockGeminiLiveSession()
        let capture = MockAudioCapture()
        let continuousPlayer = MockLiveAudioPlayer()
        let outputOnlyPlayer = MockLiveAudioPlayer()
        let c = GeminiLiveVoiceCoordinator(session: session, audioCapture: capture,
            audioPlayer: continuousPlayer, pushToTalkAudioPlayer: outputOnlyPlayer,
            wakeWordDetector: MockWakeWordDetector())
        if pushToTalk {
            await c.beginPushToTalk()
            capture.simulateAudioChunk(loud)
            await c.endPushToTalk()
            #expect(!capture.isCapturing)
        } else {
            await c.startSession()
        }
        let reply = Data([1, 2])
        session.simulateEvent(.audioChunk(reply))
        #expect(await waitUntil { (pushToTalk ? outputOnlyPlayer : continuousPlayer).playedChunks == [reply] })
        #expect((pushToTalk ? continuousPlayer : outputOnlyPlayer).playedChunks.isEmpty)
        #expect(capture.isCapturing == !pushToTalk)
        await c.stopSession()
        #expect((pushToTalk ? outputOnlyPlayer : continuousPlayer).isStopped)
    }

    @Test("Release during an early reply or approval closes capture without cancelling the reply", arguments: [false, true])
    func releaseDuringReply(awaitsApproval: Bool) async {
        let (c, session, capture, player, _) = makeCoordinator(autoDrain: false)
        await c.beginPushToTalk()
        capture.simulateAudioChunk(loud)
        #expect(await waitUntil { session.sentAudioChunks == [loud] })
        if awaitsApproval {
            session.simulateEvent(.toolCall(FunctionCall(name: "run_shell", args: ["command": "echo fixture"], id: "early-approval")))
            #expect(await waitUntil { c.state == .toolConfirmation })
        } else {
            session.simulateEvent(.audioChunk(Data([1, 2])))
            #expect(await waitUntil { c.state == .speaking })
        }

        await c.endPushToTalk()
        #expect(!capture.isCapturing)
        #expect(!c.isPushToTalkActive)
        #expect(session.isConnected)
        #expect(session.audioInputEndCount == 0) // The server already started answering this utterance.
        if awaitsApproval {
            #expect(c.pendingConfirmation != nil)
            c.respondToPendingConfirmation(approved: false)
            #expect(await waitUntil { session.sentToolResponses.count == 1 })
            session.simulateEvent(.audioChunk(Data([1, 2])))
            #expect(await waitUntil { c.state == .speaking })
        }
        session.simulateEvent(.turnComplete)
        player.finishPlayback()
        #expect(await waitUntil { c.state == .idle })
        #expect(!session.isConnected && !capture.isCapturing)
        #expect(c.activeTaskCount == 0)
    }

    @Test("Ending a released request stops audio hardware again after playback may have restarted it")
    func releasedRequestCleanup() async {
        let (c, session, capture, _, _) = makeCoordinator()
        await c.beginPushToTalk()
        capture.simulateAudioChunk(loud)
        await c.endPushToTalk()
        #expect(capture.stopCaptureCallCount == 1)
        session.simulateEvent(.audioChunk(Data([1, 2])))
        #expect(await waitUntil { c.state == .speaking })
        await c.stopSession()
        #expect(capture.stopCaptureCallCount == 2)
        #expect(c.state == .idle && !session.isConnected)
    }

    @Test("Release while capture is returning its stream drains speech or cancels silence", arguments: [true, false])
    func releaseDuringCaptureStartup(hasSpeech: Bool) async {
        let session = MockGeminiLiveSession()
        let capture = GatedAudioCapture()
        let c = GeminiLiveVoiceCoordinator(session: session, audioCapture: capture,
            audioPlayer: MockLiveAudioPlayer(), wakeWordDetector: MockWakeWordDetector())
        let start = Task { await c.beginPushToTalk() }
        #expect(await waitUntil { capture.inner.isCapturing })
        if hasSpeech { capture.inner.simulateAudioChunk(loud) }
        await c.endPushToTalk()
        #expect(!c.isPushToTalkActive)
        await capture.resumeStart()
        await start.value
        #expect(!capture.inner.isCapturing && capture.inner.stopCaptureCallCount == (hasSpeech ? 1 : 2))
        #expect(c.state == (hasSpeech ? .thinking : .idle))
        #expect(session.audioInputEndCount == (hasSpeech ? 1 : 0))
        #expect(session.sentAudioChunks == (hasSpeech ? [loud] : []))
        #expect(session.isConnected == hasSpeech)
        await c.stopSession()
    }
    @Test("Release submits queued speech once, keeps the reply connected, and closes after playback")
    func releaseThenReply() async {
        let (c, session, capture, player, _) = makeCoordinator(autoDrain: false)
        await c.beginPushToTalk()
        capture.simulateAudioChunk(loud)
        capture.simulateAudioChunk(loud)
        // Release immediately: queued frames must finish before the end marker.
        await c.endPushToTalk()
        #expect(!c.isPushToTalkActive)
        #expect(!capture.isCapturing)
        #expect(session.sentAudioChunks == [loud, loud])
        #expect(session.audioInputEndCount == 1)
        #expect(session.isConnected)
        #expect(c.state == .thinking)
        await c.endPushToTalk()
        #expect(session.audioInputEndCount == 1)
        // A second press during this reply cannot turn it into an unattended open microphone.
        await c.beginPushToTalk()
        #expect(!c.isPushToTalkActive)
        session.simulateEvent(.audioChunk(Data([1, 2])))
        #expect(await waitUntil { c.state == .speaking })
        session.simulateEvent(.turnComplete)
        #expect(await waitUntil { player.isPlaying })
        #expect(session.isConnected)
        player.finishPlayback()
        #expect(await waitUntil { c.state == .idle })
        #expect(!session.isConnected)
        #expect(capture.stopCaptureCallCount == 2)
        await c.beginPushToTalk()
        #expect(c.state == .listening)
        await c.endPushToTalk() // silent press still cancels immediately
        #expect(c.state == .idle)
    }

    @Test("Speech recorded during a slow connection survives release and is submitted before the end marker")
    func releaseDuringConnection() async {
        let session = GatedLiveSession()
        let capture = MockAudioCapture()
        let c = GeminiLiveVoiceCoordinator(session: session, audioCapture: capture,
            audioPlayer: MockLiveAudioPlayer(), wakeWordDetector: MockWakeWordDetector())
        let start = Task { await c.beginPushToTalk() }
        #expect(await waitUntil { session.isWaitingToConnect })
        capture.simulateAudioChunk(loud)
        await c.endPushToTalk()
        #expect(!capture.isCapturing)
        #expect(!c.isPushToTalkActive)
        #expect(c.state == .connecting)
        session.open()
        await start.value
        #expect(c.state == .thinking)
        #expect(session.inner.sentAudioChunks == [loud])
        #expect(session.inner.audioInputEndCount == 1)
        session.inner.simulateEvent(.turnComplete) // reply without speech also cleans up
        #expect(await waitUntil { c.state == .idle })
    }

    @Test("Release after an already answered turn closes without submitting that speech again")
    func releaseAfterAnswer() async {
        let (c, session, capture, _, _) = makeCoordinator()
        await c.beginPushToTalk()
        capture.simulateAudioChunk(loud)
        #expect(await waitUntil { session.sentAudioChunks == [loud] })
        session.simulateEvent(.audioChunk(Data([1, 2])))
        #expect(await waitUntil { c.state == .speaking })
        session.simulateEvent(.turnComplete)
        #expect(await waitUntil { c.state == .listening })
        await c.endPushToTalk()
        #expect(c.state == .idle)
        #expect(session.audioInputEndCount == 0)
        #expect(!capture.isCapturing && !session.isConnected)
    }

    @Test("An end-of-input failure is visible and releases the socket and microphone")
    func submitFailure() async {
        let (c, session, capture, _, _) = makeCoordinator()
        await c.beginPushToTalk()
        session.setEndAudioInputError(LiveError.serverError("Fixture send failed"))
        capture.simulateAudioChunk(loud)
        await c.endPushToTalk()
        guard case .error(let message) = c.state else {
            Issue.record("Expected a visible submission failure, got \(c.state)")
            await c.stopSession()
            return
        }
        #expect(message.contains("Couldn't submit your voice request"))
        #expect(!session.isConnected && !capture.isCapturing)
        #expect(!c.isPushToTalkActive)
        await c.stopSession()
        await #expect(throws: LiveError.sessionClosed) { try await session.endAudioInput() }
    }

    @Test("Releasing the shortcut in a hands-free session leaves continuous listening intact")
    func handsFreeUnaffected() async {
        let (c, session, capture, _, _) = makeCoordinator()
        await c.startSession()
        await c.beginPushToTalk()
        capture.simulateAudioChunk(loud)
        await c.endPushToTalk()
        #expect(c.state == .listening)
        #expect(capture.isCapturing && session.isConnected)
        #expect(session.audioInputEndCount == 0)
        await c.stopSession()
    }
}
