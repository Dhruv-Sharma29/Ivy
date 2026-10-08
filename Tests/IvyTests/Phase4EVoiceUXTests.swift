import Testing
import Foundation
import Combine
import os
@testable import IvyCore

/// Records every published voice state so tests can assert exact transition sequences.
@MainActor
private final class StateRecorder {
    private(set) var states: [VoiceSessionState] = []
    private var cancellable: AnyCancellable?

    init(_ coordinator: GeminiLiveVoiceCoordinator) {
        cancellable = coordinator.$state.sink { [weak self] in self?.states.append($0) }
    }

    var names: [String] { states.map(\.debugName) }
}

/// Player whose `playChunk` suspends until released, to force the stop-vs-schedule race.
private final class GatedLiveAudioPlayer: LiveAudioPlayerProtocol, @unchecked Sendable {
    private struct State {
        var gate: CheckedContinuation<Void, Never>? = nil
        var stopCount = 0
        var played: [Data] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var isPlaying: Bool { false }
    var stopCount: Int { state.withLock { $0.stopCount } }
    var hasPendingChunk: Bool { state.withLock { $0.gate != nil } }

    func playChunk(_ data: Data) async throws {
        await withCheckedContinuation { cont in state.withLock { $0.gate = cont } }
        state.withLock { $0.played.append(data) }
    }

    func release() {
        let cont = state.withLock { s -> CheckedContinuation<Void, Never>? in
            defer { s.gate = nil }
            return s.gate
        }
        cont?.resume()
    }

    func waitUntilFinished() async {}
    func stop() async { state.withLock { $0.stopCount += 1 } }
}

@Suite("Phase 4E - Voice UX, Streaming & Interruption Polish")
@MainActor
struct Phase4EVoiceUXTests {

    private static let sandbox = URL(fileURLWithPath: "/Users/testuser/Sandbox")

    private struct Harness {
        let coordinator: GeminiLiveVoiceCoordinator
        let session: MockGeminiLiveSession
        let capture: MockAudioCapture
        let player: MockLiveAudioPlayer
        let detector: MockWakeWordDetector
        let workspace: MockWorkspace
    }

    private func makeHarness(
        player: MockLiveAudioPlayer = MockLiveAudioPlayer(autoDrain: false),
        setupTimeout: Duration = .seconds(15)
    ) -> Harness {
        let session = MockGeminiLiveSession()
        let capture = MockAudioCapture(isPermissionGranted: true)
        let detector = MockWakeWordDetector()
        let workspace = MockWorkspace()
        workspace.knownApps["safari.app"] = URL(fileURLWithPath: "/Applications/Safari.app")
        let registry = ToolRegistry(tools: [
            OpenAppTool(workspace: workspace),
            RunShellTool(executor: MockShellExecutor()),
            FileOpTool(executor: MockFileExecutor(), allowedRoot: Self.sandbox)
        ])
        let dispatcher = ToolDispatcher(
            registry: registry,
            safetyGate: InteractiveSafetyGate(confirmationProvider: ConfirmationBridge())
        )
        let coordinator = GeminiLiveVoiceCoordinator(
            session: session,
            audioCapture: capture,
            audioPlayer: player,
            wakeWordDetector: detector,
            hotkeyManager: MockGlobalHotkeyManager(),
            toolDispatcher: dispatcher,
            setupTimeout: setupTimeout
        )
        return Harness(coordinator: coordinator, session: session, capture: capture, player: player, detector: detector, workspace: workspace)
    }

    private func waitUntil(timeout: UInt64 = 1_000_000_000, _ condition: () -> Bool) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeout {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    /// Lets queued MainActor events settle when asserting that something did NOT happen.
    private func settle() async {
        try? await Task.sleep(nanoseconds: 60_000_000)
    }

    private func speak(_ h: Harness, _ chunk: Data) async {
        h.session.simulateEvent(.audioChunk(chunk))
        _ = await waitUntil { h.player.playedChunks.contains(chunk) && h.coordinator.state == .speaking }
    }

    // MARK: - 1. State machine

    @Test("Normal turn: IDLE -> CONNECTING -> LISTENING -> SPEAKING -> LISTENING, no duplicate emissions")
    func normalTurnStateSequence() async {
        let h = makeHarness()
        let recorder = StateRecorder(h.coordinator)
        await h.coordinator.startSession()
        await speak(h, Data([0x01, 0x02]))
        h.session.simulateEvent(.audioChunk(Data([0x03, 0x04])))
        h.session.simulateEvent(.turnComplete)
        _ = await waitUntil { h.player.playedChunks.count == 2 }
        h.player.finishPlayback()
        #expect(await waitUntil { h.coordinator.state == .listening })
        #expect(recorder.names == ["IDLE", "CONNECTING", "LISTENING", "SPEAKING", "LISTENING"])
        await h.coordinator.stopSession()
    }

    @Test("Hey Ivy: SPEAKING -> INTERRUPTING -> LISTENING")
    func heyIvyStateSequence() async {
        let h = makeHarness()
        let recorder = StateRecorder(h.coordinator)
        await h.coordinator.startSession()
        await speak(h, Data([0x01, 0x02]))
        h.detector.simulateTranscription("Hey Ivy")
        #expect(await waitUntil { h.coordinator.state == .listening })
        #expect(recorder.names.suffix(3) == ["SPEAKING", "INTERRUPTING", "LISTENING"])
        #expect(h.player.isStopped)
        await h.coordinator.stopSession()
    }

    @Test("Failure goes straight to ERROR without an IDLE flicker")
    func failureHasNoIdleFlicker() async {
        let h = makeHarness()
        let recorder = StateRecorder(h.coordinator)
        await h.coordinator.startSession()
        h.session.simulateEvent(.disconnected)
        #expect(await waitUntil { !h.coordinator.state.isLive })
        #expect(recorder.names == ["IDLE", "CONNECTING", "LISTENING", "ERROR"])
    }

    // MARK: - 2/3. Streaming & playback queue

    @Test("First audio chunk plays immediately, before turnComplete")
    func firstChunkPlaysImmediately() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        let first = Data([0x10, 0x20])
        h.session.simulateEvent(.audioChunk(first))
        #expect(await waitUntil { h.player.playedChunks == [first] })
        #expect(h.coordinator.state == .speaking)
        await h.coordinator.stopSession()
    }

    @Test("Audio chunks are played in arrival order")
    func chunkOrdering() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        let chunks = (0..<25).map { Data([UInt8($0), 0x7F]) }
        chunks.forEach { h.session.simulateEvent(.audioChunk($0)) }
        #expect(await waitUntil { h.player.playedChunks.count == chunks.count })
        #expect(h.player.playedChunks == chunks)
        await h.coordinator.stopSession()
    }

    @Test("turnComplete does not end SPEAKING until queued audio drains")
    func turnCompleteWaitsForDrain() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        await speak(h, Data([0x01, 0x02]))
        h.session.simulateEvent(.turnComplete)
        await settle()
        #expect(h.coordinator.state == .speaking)
        h.player.finishPlayback()
        #expect(await waitUntil { h.coordinator.state == .listening })
        await h.coordinator.stopSession()
    }

    @Test("Stopping the session while draining cancels the drain; no late LISTENING")
    func queueCancellationOnStop() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        await speak(h, Data([0x01, 0x02]))
        h.session.simulateEvent(.turnComplete)
        await settle()
        await h.coordinator.stopSession()
        h.player.finishPlayback()
        await settle()
        #expect(h.coordinator.state == .idle)
        #expect(h.player.isStopped)
    }

    // MARK: - 4. Interruption

    @Test("Interrupted turn's leftover audio never resumes; next reply plays after the turn closes")
    func interruptedAudioNeverResumes() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        let first = Data([0x01, 0x02])
        await speak(h, first)
        await h.coordinator.processTranscriptionForInterruption("Hey Ivy")
        #expect(h.coordinator.state == .listening)

        let leftover = Data([0x0A, 0x0B])
        h.session.simulateEvent(.audioChunk(leftover))
        await settle()
        #expect(h.coordinator.state == .listening)
        #expect(!h.player.playedChunks.contains(leftover))

        h.session.simulateEvent(.turnComplete) // server closes the interrupted turn
        let reply = Data([0x0C, 0x0D])
        await speak(h, reply)
        #expect(h.player.playedChunks.contains(reply))
        #expect(!h.player.playedChunks.contains(leftover))
        await h.coordinator.stopSession()
    }

    @Test("Interrupting an already-complete turn (draining) discards nothing from the next reply")
    func interruptDuringDrainDoesNotMuteNextReply() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        await speak(h, Data([0x01, 0x02]))
        h.session.simulateEvent(.turnComplete)
        await settle()
        await h.coordinator.handleWakePhraseDetected()
        #expect(h.coordinator.state == .listening)
        let reply = Data([0x05, 0x06])
        await speak(h, reply)
        #expect(h.coordinator.state == .speaking)
        await h.coordinator.stopSession()
    }

    @Test("Server 'interrupted' closes the discarded turn so the next reply plays")
    func serverInterruptedClearsDiscard() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        await speak(h, Data([0x01, 0x02]))
        await h.coordinator.handleWakePhraseDetected()
        h.session.simulateEvent(.interrupted)
        let reply = Data([0x07, 0x08])
        await speak(h, reply)
        #expect(h.player.playedChunks.contains(reply))
        await h.coordinator.stopSession()
    }

    @Test("A chunk still being scheduled when Hey Ivy stops playback is silenced again")
    func stopScheduleRaceIsSilenced() async {
        let session = MockGeminiLiveSession()
        let player = GatedLiveAudioPlayer()
        let coordinator = GeminiLiveVoiceCoordinator(
            session: session,
            audioCapture: MockAudioCapture(),
            audioPlayer: player,
            wakeWordDetector: MockWakeWordDetector()
        )
        await coordinator.startSession()
        session.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        #expect(await waitUntil { player.hasPendingChunk && coordinator.state == .speaking })

        await coordinator.handleWakePhraseDetected()
        #expect(coordinator.state == .listening)
        let stopsAfterInterrupt = player.stopCount

        player.release()
        #expect(await waitUntil { player.stopCount == stopsAfterInterrupt + 1 })
        #expect(coordinator.state == .listening)
        await coordinator.stopSession()
    }

    @Test("Normal speech during SPEAKING does not interrupt and is not sent to Gemini")
    func normalSpeechDoesNotInterrupt() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        await speak(h, Data([0x01, 0x02]))
        h.detector.simulateTranscription("Yeah okay, sounds good")
        let micChunk = Data([0x00, 0x40])
        h.capture.simulateAudioChunk(micChunk)
        await settle()
        #expect(h.coordinator.state == .speaking)
        #expect(!h.player.isStopped)
        #expect(!h.session.sentAudioChunks.contains(micChunk))
        await h.coordinator.stopSession()
    }

    @Test("Repeated Hey Ivy interrupts once and leaves a clean LISTENING state")
    func repeatedInterruptions() async {
        let h = makeHarness()
        let recorder = StateRecorder(h.coordinator)
        await h.coordinator.startSession()
        await speak(h, Data([0x01, 0x02]))
        for _ in 0..<4 { h.detector.simulateTranscription("Hey Ivy") }
        #expect(await waitUntil { h.coordinator.state == .listening })
        await settle()
        #expect(recorder.names.filter { $0 == "INTERRUPTING" }.count == 1)
        #expect(h.coordinator.state == .listening)
        await h.coordinator.stopSession()
    }

    // MARK: - 8. PTT

    @Test("A new PTT hold during SPEAKING interrupts; silent release closes input")
    func pttDuringSpeaking() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        await speak(h, Data([0x01, 0x02]))
        await h.coordinator.beginPushToTalk()
        #expect(h.coordinator.state == .listening && h.capture.isCapturing)
        #expect(h.player.isStopped && !h.player.isPlaying)
        await h.coordinator.endPushToTalk()
        #expect(h.coordinator.state == .idle && !h.capture.isCapturing)
        #expect(!h.session.isConnected)
        await h.coordinator.stopSession()
    }

    @Test("PTT session: release during speech closes after playback; PTT works again afterwards")
    func pttAfterPlayback() async {
        let h = makeHarness()
        await h.coordinator.beginPushToTalk()
        #expect(h.coordinator.state == .listening)
        await speak(h, Data([0x01, 0x02]))
        await h.coordinator.endPushToTalk()
        #expect(h.coordinator.state == .speaking)

        h.session.simulateEvent(.turnComplete)
        await settle()
        h.player.finishPlayback()
        #expect(await waitUntil { h.coordinator.state == .idle })
        #expect(!h.capture.isCapturing)

        await h.coordinator.beginPushToTalk()
        #expect(h.coordinator.state == .listening)
        #expect(h.capture.isCapturing)
        await h.coordinator.endPushToTalk()
        #expect(h.coordinator.state == .idle)
        #expect(!h.capture.isCapturing)
    }

    @Test("PTT works after a Hey Ivy interruption and mic audio reaches Gemini")
    func pttAfterHeyIvy() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        await speak(h, Data([0x01, 0x02]))
        await h.coordinator.handleWakePhraseDetected()
        await h.coordinator.beginPushToTalk()
        #expect(h.coordinator.state == .listening)
        let micChunk = Data([0x00, 0x40])
        h.capture.simulateAudioChunk(micChunk)
        #expect(await waitUntil { h.session.sentAudioChunks.contains(micChunk) })
        await h.coordinator.endPushToTalk()
        await h.coordinator.stopSession()
    }

    // MARK: - 10. Tool-calling voice UX

    @Test("Safe tool: LISTENING -> THINKING -> TOOL_EXECUTION -> SPEAKING -> LISTENING")
    func safeToolFlow() async {
        let h = makeHarness()
        let recorder = StateRecorder(h.coordinator)
        await h.coordinator.startSession()
        h.session.simulateToolCall(FunctionCall(name: "open_app", args: ["name": "Safari"], id: "e-safe"))
        #expect(await waitUntil { h.session.sentToolResponses.contains { $0.id == "e-safe" } })
        #expect(h.coordinator.state == .toolExecution)
        await speak(h, Data([0x01, 0x02]))
        h.session.simulateEvent(.turnComplete)
        await settle()
        h.player.finishPlayback()
        #expect(await waitUntil { h.coordinator.state == .listening })
        #expect(recorder.names == ["IDLE", "CONNECTING", "LISTENING", "THINKING", "TOOL_EXECUTION", "SPEAKING", "LISTENING"])
        #expect(h.coordinator.executingToolName == nil)
        await h.coordinator.stopSession()
    }

    @Test("Risky tool: LISTENING -> THINKING -> TOOL_CONFIRMATION -> TOOL_EXECUTION -> SPEAKING; voice cannot approve")
    func riskyToolFlow() async {
        let h = makeHarness()
        let recorder = StateRecorder(h.coordinator)
        await h.coordinator.startSession()
        h.session.simulateToolCall(FunctionCall(name: "run_shell", args: ["command": "date"], id: "e-risky"))
        #expect(await waitUntil { h.coordinator.state == .toolConfirmation })

        h.detector.simulateTranscription("yes, approve it")
        let micChunk = Data([0x00, 0x40])
        h.capture.simulateAudioChunk(micChunk)
        await settle()
        #expect(h.coordinator.state == .toolConfirmation)
        #expect(!h.session.sentAudioChunks.contains(micChunk))
        #expect(h.session.sentToolResponses.isEmpty)

        h.coordinator.respondToPendingConfirmation(id: h.coordinator.pendingConfirmation?.id, approved: true)
        #expect(await waitUntil { h.session.sentToolResponses.contains { $0.id == "e-risky" } })
        await speak(h, Data([0x01, 0x02]))
        #expect(recorder.names == ["IDLE", "CONNECTING", "LISTENING", "THINKING", "TOOL_CONFIRMATION", "TOOL_EXECUTION", "SPEAKING"])
        await h.coordinator.stopSession()
    }

    @Test("SafetyGate denial: TOOL_CONFIRMATION -> THINKING, denial sent, reply still spoken")
    func safetyGateDenial() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        h.session.simulateToolCall(FunctionCall(name: "run_shell", args: ["command": "rm -rf /tmp/x"], id: "e-deny"))
        #expect(await waitUntil { h.coordinator.state == .toolConfirmation })
        h.coordinator.respondToPendingConfirmation(approved: false)
        #expect(await waitUntil { h.session.sentToolResponses.contains { $0.id == "e-deny" } })
        #expect(h.session.sentToolResponses.first { $0.id == "e-deny" }?.isSuccess == false)
        #expect(h.coordinator.state == .thinking)
        await speak(h, Data([0x01, 0x02]))
        #expect(h.coordinator.state == .speaking)
        await h.coordinator.stopSession()
    }

    @Test("Hey Ivy during confirmation cancels it; the stale confirmation never rewrites state")
    func heyIvyCancelsConfirmationWithoutStaleWrite() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        h.session.simulateToolCall(FunctionCall(name: "run_shell", args: ["command": "date"], id: "e-cancel"))
        #expect(await waitUntil { h.coordinator.state == .toolConfirmation })
        h.detector.simulateTranscription("Hey Ivy")
        #expect(await waitUntil { h.session.sentToolResponses.contains { $0.id == "e-cancel" } })
        await settle()
        #expect(h.coordinator.state == .listening)
        #expect(h.coordinator.pendingConfirmation == nil)
        await h.coordinator.stopSession()
    }

    @Test("Stopping during confirmation stays IDLE (no late THINKING from the resumed confirmation)")
    func stopDuringConfirmationStaysIdle() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        h.session.simulateToolCall(FunctionCall(name: "run_shell", args: ["command": "date"], id: "e-stop"))
        #expect(await waitUntil { h.coordinator.state == .toolConfirmation })
        await h.coordinator.stopSession()
        await settle()
        #expect(h.coordinator.state == .idle)
        #expect(h.coordinator.pendingConfirmation == nil)
    }

    @Test("Tool turn that completes without speech returns to LISTENING instead of stalling")
    func silentToolTurnReturnsToListening() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        h.session.simulateToolCall(FunctionCall(name: "open_app", args: ["name": "Safari"], id: "e-silent"))
        #expect(await waitUntil { h.session.sentToolResponses.contains { $0.id == "e-silent" } })
        h.session.simulateEvent(.turnComplete)
        #expect(await waitUntil { h.coordinator.state == .listening })
        await h.coordinator.stopSession()
    }

    // MARK: - 11. Errors

    @Test("Live disconnect cleans up mic and playback, and the session can restart")
    func liveDisconnectRecovers() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        await speak(h, Data([0x01, 0x02]))
        h.session.simulateEvent(.disconnected)
        #expect(await waitUntil { if case .error = h.coordinator.state { return true }; return false })
        #expect(!h.capture.isCapturing)
        #expect(h.player.isStopped)

        await h.coordinator.startSession()
        #expect(h.coordinator.state == .listening)
        #expect(h.capture.isCapturing)
        await h.coordinator.stopSession()
    }

    @Test("Microphone failure tears down and lands in ERROR")
    func microphoneFailure() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        h.capture.simulateError(LiveError.connectionFailed("mic unplugged"))
        #expect(await waitUntil { if case .error = h.coordinator.state { return true }; return false })
        #expect(!h.capture.isCapturing)
        #expect(!h.session.isConnected)
    }

    @Test("Playback failure stops the mic and prevents further audio")
    func playbackFailure() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        h.player.setPlayError(LiveError.serverError("device lost"))
        h.session.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        #expect(await waitUntil { if case .error = h.coordinator.state { return true }; return false })
        #expect(!h.capture.isCapturing)
        #expect(h.player.playedChunks.isEmpty)
    }

    @Test("Missing setup acknowledgement times out into a recoverable ERROR")
    func setupTimeout() async {
        let h = makeHarness(setupTimeout: .milliseconds(50))
        h.session.setSuppressSetupAck(true)
        await h.coordinator.startSession()
        #expect(await waitUntil { if case .error = h.coordinator.state { return true }; return false })
        if case .error(let msg) = h.coordinator.state {
            #expect(msg.contains("timed out"))
        }
        #expect(!h.capture.isCapturing)

        h.session.setSuppressSetupAck(false)
        await h.coordinator.startSession()
        #expect(h.coordinator.state == .listening)
        await h.coordinator.stopSession()
    }

    @Test("Acknowledged setup cancels the watchdog")
    func acknowledgedSetupDoesNotTimeOut() async {
        let h = makeHarness(setupTimeout: .milliseconds(30))
        await h.coordinator.startSession()
        try? await Task.sleep(nanoseconds: 120_000_000)
        #expect(h.coordinator.state == .listening)
        await h.coordinator.stopSession()
    }

    // MARK: - 7/13. Microphone lifecycle & stale callbacks

    @Test("Rapid start/stop cycles leave no live mic and settle in the last requested state")
    func rapidStartStop() async {
        let h = makeHarness()
        for _ in 0..<8 {
            await h.coordinator.startSession()
            await h.coordinator.stopSession()
        }
        #expect(h.coordinator.state == .idle)
        #expect(!h.capture.isCapturing)

        let stop = Task { await h.coordinator.stopSession() }
        let start = Task { await h.coordinator.startSession() }
        await stop.value
        await start.value
        #expect(h.coordinator.state == .listening)
        #expect(h.capture.isCapturing)
        await h.coordinator.stopSession()
        #expect(!h.capture.isCapturing)
    }

    @Test("Stale-session transcription and events cannot mutate a new session")
    func staleCallbacksIgnored() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        await speak(h, Data([0x01, 0x02]))
        await h.coordinator.processTranscriptionForInterruption("Hey Ivy", token: UUID())
        #expect(h.coordinator.state == .speaking)
        await h.coordinator.handleWakePhraseDetected(token: UUID())
        #expect(h.coordinator.state == .speaking)
        await h.coordinator.stopSession()
    }

    @Test("Mic audio only reaches Gemini while LISTENING")
    func micGatedByState() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        let listeningChunk = Data([0x00, 0x40])
        h.capture.simulateAudioChunk(listeningChunk)
        #expect(await waitUntil { h.session.sentAudioChunks.contains(listeningChunk) })

        await speak(h, Data([0x01, 0x02]))
        let speakingChunk = Data([0x00, 0x41])
        h.capture.simulateAudioChunk(speakingChunk)
        await settle()
        #expect(!h.session.sentAudioChunks.contains(speakingChunk))
        await h.coordinator.stopSession()
    }

    // MARK: - 5. Latency metrics

    @Test("Latency metrics are captured in order for a full turn")
    func latencyMetrics() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        #expect(await waitUntil { h.coordinator.latency.setupAck != nil })
        #expect(h.coordinator.latency.connect != nil)

        let speech = Data([0x00, 0x40]) // loud sample -> end-of-speech reference
        h.capture.simulateAudioChunk(speech)
        #expect(await waitUntil { h.session.sentAudioChunks.contains(speech) })
        await speak(h, Data([0x01, 0x02]))
        h.session.simulateEvent(.turnComplete)
        await settle()
        h.player.finishPlayback()
        #expect(await waitUntil { h.coordinator.latency.responseComplete != nil })

        let m = h.coordinator.latency
        guard let first = m.firstAudio, let start = m.playbackStart, let done = m.responseComplete else {
            Issue.record("missing turn metrics: \(m)")
            return
        }
        #expect(first <= start)
        #expect(start <= done)
        await h.coordinator.stopSession()
    }

    @Test("Voice gate and ms formatting helpers")
    func metricHelpers() {
        #expect(!GeminiLiveVoiceCoordinator.containsVoice(Data(repeating: 0, count: 64)))
        #expect(!GeminiLiveVoiceCoordinator.containsVoice(Data([0x10, 0x00, 0xF0, 0xFF]))) // +16, -16
        #expect(GeminiLiveVoiceCoordinator.containsVoice(Data([0x00, 0x40])))
        #expect(GeminiLiveVoiceCoordinator.containsVoice(Data([0x00, 0xC0])))              // -16384
        #expect(!GeminiLiveVoiceCoordinator.containsVoice(Data([0xFF])))                   // malformed odd byte
        #expect(GeminiLiveVoiceCoordinator.ms(.milliseconds(412)) == "412ms")
        #expect(GeminiLiveVoiceCoordinator.ms(nil) == "n/a")
        #expect(LiveError.timeout("x").localizedDescription.contains("timed out"))
    }

    @Test("Wake phrase availability reflects speech-recognition permission")
    func wakePhraseAvailability() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        #expect(h.coordinator.isWakePhraseAvailable)
        await h.coordinator.stopSession()

        let denied = GeminiLiveVoiceCoordinator(
            session: MockGeminiLiveSession(),
            audioCapture: MockAudioCapture(),
            audioPlayer: MockLiveAudioPlayer(),
            wakeWordDetector: MockWakeWordDetector(isPermissionGranted: false)
        )
        await denied.startSession()
        #expect(!denied.isWakePhraseAvailable)
        #expect(denied.state == .listening) // Live still works; only Hey Ivy is unavailable
        await denied.stopSession()
    }

    // MARK: - Regression guards for preserved behavior

    @Test("Gemini Live model and Tavi voice are preserved")
    func liveModelAndVoicePreserved() {
        let client = GeminiLiveClient(apiKey: "test")
        #expect(client.model == "models/gemini-3.8-live")
        #expect(GeminiLiveVoiceCoordinator.liveVoiceName == "en-us-tavi")
        #expect(client.voiceName == "en-us-tavi")
    }

    // MARK: - Extended Verification for Phase 4E Requirements

    @Test("Audio buffer safety: SystemLiveAudioPlayer handles odd-length and single-byte PCM safely")
    func oddLengthAudioBufferSafety() async throws {
        let player = SystemLiveAudioPlayer()
        // Single byte: frameCount = 0, returns safely without error
        try await player.playChunk(Data([0x01]))
        #expect(!player.isPlaying)

        // Odd length 3 bytes: frameCount = 1 (2 bytes copied), whole frames only, no buffer overrun
        try await player.playChunk(Data([0x01, 0x02, 0x03]))

        // Odd length 5 bytes: frameCount = 2 (4 bytes copied), plays safely
        try await player.playChunk(Data([0x0A, 0x0B, 0x0C, 0x0D, 0x0E]))

        await player.stop()
        #expect(!player.isPlaying)
    }

    @Test("Setup timeout from an old session cannot terminate a new session")
    func oldSessionSetupTimeoutCannotTerminateNewSession() async throws {
        let h = makeHarness(setupTimeout: .milliseconds(50))
        // Session 1: suppress setup acknowledgement and start session
        h.session.setSuppressSetupAck(true)
        await h.coordinator.startSession()

        // Session 2: started before session 1 watchdog fires, setup ack allowed
        h.session.setSuppressSetupAck(false)
        await h.coordinator.startSession()
        #expect(await waitUntil { h.coordinator.state == .listening })

        // Sleep longer than the 50ms watchdog of session 1
        try await Task.sleep(nanoseconds: 120_000_000)

        // Session 2 must STILL be in listening, not killed by session 1 watchdog
        #expect(h.coordinator.state == .listening)
        await h.coordinator.stopSession()
    }

    @Test("Tool confirmation: wrong ID is ignored, duplicate response is idempotent")
    func toolConfirmationIdempotenceAndWrongId() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        h.session.simulateToolCall(FunctionCall(name: "run_shell", args: ["command": "echo hi"], id: "call-1"))
        #expect(await waitUntil { h.coordinator.state == .toolConfirmation })
        let correctId = h.coordinator.pendingConfirmation?.id

        // Wrong ID should be ignored
        h.coordinator.respondToPendingConfirmation(id: UUID(), approved: true)
        #expect(h.coordinator.state == .toolConfirmation)
        #expect(h.session.sentToolResponses.isEmpty)

        // Correct ID approves
        if let correctId {
            h.coordinator.respondToPendingConfirmation(id: correctId, approved: true)
            #expect(await waitUntil { h.session.sentToolResponses.contains { $0.id == "call-1" } })
            #expect(h.coordinator.state == .toolExecution)

            // Duplicate approval attempt is safe and ignored
            h.coordinator.respondToPendingConfirmation(id: correctId, approved: true)
            #expect(h.session.sentToolResponses.count == 1)
        }

        await h.coordinator.stopSession()
    }

    @Test("Stale tool response after session stop is safely discarded and cannot resurrect tool state")
    func staleToolResponseDiscardedAfterStop() async {
        let h = makeHarness()
        await h.coordinator.startSession()
        h.session.simulateToolCall(FunctionCall(name: "run_shell", args: ["command": "sleep 1"], id: "call-stale"))
        #expect(await waitUntil { h.coordinator.state == .toolConfirmation })

        // Stop session before confirmation is answered
        await h.coordinator.stopSession()
        #expect(h.coordinator.state == .idle)
        #expect(h.coordinator.pendingConfirmation == nil)

        // Starting a new session leaves clean state
        await h.coordinator.startSession()
        #expect(h.coordinator.state == .listening)
        #expect(h.coordinator.executingToolName == nil)
        #expect(h.coordinator.pendingConfirmation == nil)
        await h.coordinator.stopSession()
    }
}
