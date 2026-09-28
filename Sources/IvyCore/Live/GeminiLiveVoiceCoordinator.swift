import Foundation
import Combine
import AVFoundation

/// Lifecycle states for an active Gemini Live voice session.
public enum VoiceSessionState: Equatable, Sendable {
    case idle
    case connecting
    case listening
    case thinking
    case toolConfirmation
    case toolExecution
    case speaking
    case interrupting
    case error(String)

    public var isLive: Bool {
        switch self {
        case .connecting, .listening, .thinking, .toolConfirmation, .toolExecution, .speaking, .interrupting:
            return true
        case .idle, .error:
            return false
        }
    }

    public var isToolConfirmation: Bool {
        self == .toolConfirmation
    }

    public var isToolExecution: Bool {
        self == .toolExecution
    }

    /// Content-free name for debug logs (error messages are omitted).
    var debugName: String {
        switch self {
        case .idle: return "IDLE"
        case .connecting: return "CONNECTING"
        case .listening: return "LISTENING"
        case .thinking: return "THINKING"
        case .toolConfirmation: return "TOOL_CONFIRMATION"
        case .toolExecution: return "TOOL_EXECUTION"
        case .speaking: return "SPEAKING"
        case .interrupting: return "INTERRUPTING"
        case .error: return "ERROR"
        }
    }
}

/// Latency marks for the current Live session and its most recent model turn. Durations only, never content.
public struct LiveLatencyMetrics: Equatable, Sendable {
    /// Session start → socket open and setup sent.
    public var connect: Duration?
    /// Session start → server `setupComplete`.
    public var setupAck: Duration?
    /// End of user speech (or tool response sent) → first audio chunk of the reply.
    public var firstAudio: Duration?
    /// Same reference → first reply chunk scheduled on the speaker.
    public var playbackStart: Duration?
    /// Same reference → reply playback fully drained.
    public var responseComplete: Duration?

    public init() {}
}

/// Coordinates microphone audio capture, Gemini Live session streaming, and native audio playback.
@MainActor
public final class GeminiLiveVoiceCoordinator: ObservableObject {
    @Published public private(set) var state: VoiceSessionState = .idle
    @Published public private(set) var latestTranscript: String = ""
    @Published public private(set) var pendingConfirmation: ConfirmationRequest? = nil
    @Published public private(set) var executingToolName: String? = nil
    /// False when speech recognition is unavailable (e.g. `swift run` without an .app bundle), so "Hey Ivy" can't interrupt.
    @Published public private(set) var isWakePhraseAvailable: Bool = false
    public private(set) var latency = LiveLatencyMetrics()

    public let session: GeminiLiveSession
    public let audioCapture: AudioCaptureProtocol
    public let audioPlayer: LiveAudioPlayerProtocol
    public let wakeWordDetector: WakeWordDetectorProtocol
    public let hotkeyManager: GlobalHotkeyManaging?
    public let toolDispatcher: ToolDispatcher
    private let setupTimeout: Duration

    public private(set) var isPushToTalkActive: Bool = false
    public private(set) var wasSessionStartedByPushToTalk: Bool = false
    private var currentSessionToken: UUID? = nil

    private var confirmationContinuation: CheckedContinuation<Bool, Never>? = nil
    private var executedToolCallIds: Set<String> = []
    private var toolExecutionTask: Task<Void, Never>? = nil
    private var pendingToolCalls = 0

    private var captureTask: Task<Void, Never>? = nil
    private var eventTask: Task<Void, Never>? = nil
    private var drainTask: Task<Void, Never>? = nil
    private var setupWatchdogTask: Task<Void, Never>? = nil
    private var isSetupAcknowledged = false

    /// True between a model turn's first audio chunk and its `turnComplete`, independent of playback.
    private var isModelTurnOpen = false
    /// After a local "Hey Ivy", the server keeps streaming the interrupted turn; drop it until that turn closes.
    private var isDiscardingInterruptedTurn = false
    /// Bumped on every playback stop so a chunk whose scheduling raced the stop is silenced, never resumed.
    private var playbackEpoch = 0

    private let clock = ContinuousClock()
    private var sessionStartedAt: ContinuousClock.Instant? = nil
    private var turnReferenceAt: ContinuousClock.Instant? = nil

    public init(
        session: GeminiLiveSession,
        audioCapture: AudioCaptureProtocol,
        audioPlayer: LiveAudioPlayerProtocol,
        wakeWordDetector: WakeWordDetectorProtocol = SystemWakeWordDetector(),
        hotkeyManager: GlobalHotkeyManaging? = nil,
        toolDispatcher: ToolDispatcher? = nil,
        setupTimeout: Duration = .seconds(15)
    ) {
        self.session = session
        self.audioCapture = audioCapture
        self.audioPlayer = audioPlayer
        self.wakeWordDetector = wakeWordDetector
        self.hotkeyManager = hotkeyManager
        self.setupTimeout = setupTimeout

        if let toolDispatcher {
            self.toolDispatcher = toolDispatcher
            if let interactiveGate = toolDispatcher.safetyGate as? InteractiveSafetyGate,
               let bridge = interactiveGate.confirmationProvider as? ConfirmationBridge {
                bridge.handler = self
            }
        } else {
            let bridge = ConfirmationBridge()
            let safetyGate = InteractiveSafetyGate(confirmationProvider: bridge)
            self.toolDispatcher = ToolDispatcher(registry: .defaultRegistry(), safetyGate: safetyGate)
            bridge.handler = self
        }

        wakeWordDetector.setTranscriptionHandler { [weak self] transcript in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.processTranscriptionForInterruption(transcript, token: self.currentSessionToken)
            }
        }
    }

    public static let liveVoiceName: String = GeminiLiveClient.liveVoiceName

    /// Convenience initializer using production implementations.
    public convenience init(
        apiKey: String,
        model: String = "models/gemini-3.1-flash-live-preview",
        voiceName: String = liveVoiceName,
        systemInstruction: String = IvyPersona.systemPrompt,
        hotkeyManager: GlobalHotkeyManaging? = nil,
        toolDispatcher: ToolDispatcher? = nil
    ) {
        let bridge = ConfirmationBridge()
        let safetyGate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = toolDispatcher ?? ToolDispatcher(registry: .defaultRegistry(), safetyGate: safetyGate)
        let client = GeminiLiveClient(
            apiKey: apiKey,
            model: model,
            voiceName: Self.liveVoiceName,
            systemInstruction: systemInstruction,
            tools: dispatcher.registry.toolDeclarations
        )
        // Capture and playback share one engine so voice processing can cancel Ivy's own voice from the mic.
        let engine = AVAudioEngine()
        let capture = SystemAudioCapture(audioEngine: engine, voiceProcessing: true)
        let player = SystemLiveAudioPlayer(audioEngine: engine, ownsEngine: false)
        let detector = SystemWakeWordDetector()
        self.init(
            session: client,
            audioCapture: capture,
            audioPlayer: player,
            wakeWordDetector: detector,
            hotkeyManager: hotkeyManager,
            toolDispatcher: dispatcher
        )
    }

    /// Registers the global push-to-talk hotkey.
    public func registerHotkey(shortcut: HotkeyShortcut = .defaultPushToTalk) throws {
        guard let hotkeyManager else { return }
        try hotkeyManager.register(shortcut: shortcut) { [weak self] in
            Task { @MainActor [weak self] in
                await self?.beginPushToTalk()
            }
        } onKeyUp: { [weak self] in
            Task { @MainActor [weak self] in
                await self?.endPushToTalk()
            }
        }
    }

    /// Unregisters the global push-to-talk hotkey.
    public func unregisterHotkey() {
        hotkeyManager?.unregister()
    }

    /// Begins push-to-talk listening (idempotent key-down event).
    public func beginPushToTalk() async {
        guard !isPushToTalkActive else {
            // Idempotent: already active, duplicate key-down ignored
            return
        }
        isPushToTalkActive = true

        switch state {
        case .idle, .error:
            wasSessionStartedByPushToTalk = true
            await startSession()
        case .listening:
            // Already listening (e.g. continuous hands-free session); do not restart
            wasSessionStartedByPushToTalk = false
        case .connecting, .thinking, .speaking, .interrupting, .toolConfirmation, .toolExecution:
            // Active session or transition in progress; do not start duplicate or interrupt speaking
            break
        }
    }

    /// Responds to the currently pending tool confirmation request.
    /// If an optional request id is provided, ensures only the matching request is answered.
    public func respondToPendingConfirmation(id: UUID? = nil, approved: Bool) {
        guard let continuation = confirmationContinuation, let pending = pendingConfirmation else { return }
        if let id, pending.id != id {
            return
        }
        confirmationContinuation = nil
        pendingConfirmation = nil
        transition(to: approved ? .toolExecution : .thinking)
        continuation.resume(returning: approved)
    }

    /// Ends push-to-talk listening (idempotent key-up event).
    public func endPushToTalk() async {
        guard isPushToTalkActive else {
            // Idempotent: already inactive, duplicate key-up ignored
            return
        }
        isPushToTalkActive = false

        if wasSessionStartedByPushToTalk {
            if state == .listening || state == .connecting {
                wasSessionStartedByPushToTalk = false
                await stopSession()
            }
        }
    }

    /// Updates the API key for the underlying session client if supported.
    public func updateApiKey(_ newKey: String) {
        if let client = session as? GeminiLiveClient {
            client.updateApiKey(newKey)
        }
    }

    /// Performs clean shutdown on app termination.
    public func shutdown() async {
        unregisterHotkey()
        isPushToTalkActive = false
        wasSessionStartedByPushToTalk = false
        await stopSession()
    }

    deinit {
        captureTask?.cancel()
        eventTask?.cancel()
        drainTask?.cancel()
        setupWatchdogTask?.cancel()
        hotkeyManager?.unregister()
    }

    /// Starts a live voice conversation session.
    public func startSession() async {
        if state.isLive {
            await stopSession()
        }

        let token = UUID()
        self.currentSessionToken = token
        transition(to: .connecting)
        latestTranscript = ""
        latency = LiveLatencyMetrics()
        sessionStartedAt = clock.now
        isSetupAcknowledged = false

        // Check microphone permission
        let hasMicPermission = await audioCapture.requestPermission()
        guard currentSessionToken == token else { return }
        guard hasMicPermission else {
            transition(to: .error(LiveError.microphonePermissionDenied.localizedDescription))
            return
        }

        // Request speech recognition permission for wake phrase interruption
        let wakeAvailable = await wakeWordDetector.requestPermission()
        guard currentSessionToken == token else { return }
        isWakePhraseAvailable = wakeAvailable

        // Connect to Gemini Live
        do {
            try await session.connect()
        } catch {
            guard currentSessionToken == token else { return }
            transition(to: .error("Failed to connect to Ivy Live: \(error.localizedDescription)"))
            return
        }
        guard currentSessionToken == token else {
            await session.disconnect()
            return
        }
        latency.connect = elapsed(since: sessionStartedAt)
        startSetupWatchdog(token: token)

        // Start event processing loop
        let events = session.receiveEvents()
        eventTask = Task { [weak self] in
            do {
                for try await event in events {
                    guard !Task.isCancelled else { break }
                    guard let self, self.currentSessionToken == token else { break }
                    await self.handleLiveEvent(event, token: token)
                }
            } catch {
                guard let self, self.currentSessionToken == token else { return }
                await self.handleFailure(error, token: token)
            }
        }

        // Start microphone capture loop
        do {
            let audioStream = try await audioCapture.startCapture()
            guard currentSessionToken == token else {
                await audioCapture.stopCapture()
                await session.disconnect()
                return
            }
            if state == .connecting {
                transition(to: .listening)
            }

            captureTask = Task { [weak self, session] in
                var sentAudioFrameCount = 0
                do {
                    for try await chunk in audioStream {
                        guard !Task.isCancelled else { break }
                        guard let self, self.currentSessionToken == token else { break }

                        switch self.state {
                        case .speaking, .toolConfirmation:
                            // Monitoring mode: mic audio is NOT streamed to Gemini Live. While speaking this prevents
                            // server VAD barge-in; during confirmation, saying "yes" must never approve a SafetyGate
                            // request. Only the explicit "Hey Ivy" wake phrase is checked.
                            let detected = await self.wakeWordDetector.processAudioChunk(chunk)
                            guard self.currentSessionToken == token else { break }
                            if detected {
                                await self.handleWakePhraseDetected(token: token)
                            }
                        case .listening:
                            // Active user-turn capture: stream audio chunk to Gemini Live.
                            if Self.containsVoice(chunk) {
                                self.turnReferenceAt = self.clock.now
                            }
                            try await session.sendAudio(chunk)
                            sentAudioFrameCount += 1
                            if sentAudioFrameCount == 1 || sentAudioFrameCount % 50 == 0 {
                                print("[AUDIO] PCM frame sent count=\(sentAudioFrameCount) bytes=\(chunk.count)")
                            }
                        case .idle, .connecting, .thinking, .toolExecution, .interrupting, .error:
                            // Mic audio is dropped: these states must never feed Gemini Live.
                            break
                        }
                    }
                } catch {
                    guard let self, self.currentSessionToken == token else { return }
                    await self.handleFailure(error, token: token)
                }
            }
        } catch {
            await session.disconnect()
            guard currentSessionToken == token else { return }
            transition(to: .error("Failed to start audio capture: \(error.localizedDescription)"))
        }
    }

    /// Cleanly terminates the live voice session.
    public func stopSession() async {
        await tearDown(then: .idle)
    }

    /// Releases mic, playback, tasks, and socket, then settles in `finalState` (no IDLE flicker on the way to ERROR).
    private func tearDown(then finalState: VoiceSessionState) async {
        currentSessionToken = nil
        captureTask?.cancel()
        eventTask?.cancel()
        drainTask?.cancel()
        toolExecutionTask?.cancel()
        setupWatchdogTask?.cancel()
        captureTask = nil
        eventTask = nil
        drainTask = nil
        toolExecutionTask = nil
        setupWatchdogTask = nil

        cancelPendingConfirmation()
        executingToolName = nil
        executedToolCallIds.removeAll()
        pendingToolCalls = 0
        isModelTurnOpen = false
        isDiscardingInterruptedTurn = false
        turnReferenceAt = nil

        await audioCapture.stopCapture()
        await stopPlayback()
        await wakeWordDetector.reset()
        await session.disconnect()

        // A session started during the awaits above owns the state now.
        guard currentSessionToken == nil else { return }
        transition(to: finalState)
        latestTranscript = ""
        wasSessionStartedByPushToTalk = false
    }

    /// Handles explicit wake phrase ("Hey Ivy") detection while Ivy is speaking or waiting for confirmation.
    public func handleWakePhraseDetected(token: UUID? = nil) async {
        if let token, currentSessionToken != token { return }
        guard state == .speaking || state == .toolConfirmation else { return }

        cancelPendingConfirmation()
        transition(to: .interrupting)
        // Only a still-streaming turn has leftovers to drop; one already complete is merely draining locally.
        isDiscardingInterruptedTurn = isModelTurnOpen
        isModelTurnOpen = false
        drainTask?.cancel()
        drainTask = nil
        toolExecutionTask?.cancel()
        toolExecutionTask = nil
        executingToolName = nil

        await stopPlayback()
        #if DEBUG
        print("[WAKE] interruption: playback stopped, queue cleared, discardingTurn=\(isDiscardingInterruptedTurn)")
        #endif
        await wakeWordDetector.reset()
        // A stopSession/failure during the awaits above owns the state now.
        guard state == .interrupting else { return }
        transition(to: .listening)
    }

    /// Evaluates transcription text directly for "Hey Ivy" interruption.
    public func processTranscriptionForInterruption(_ text: String, token: UUID? = nil) async {
        if let token, currentSessionToken != token { return }
        guard state == .speaking || state == .toolConfirmation else { return }
        #if DEBUG
        print("[WAKE] recognition partial chars=\(text.count) TEMPDIAG=\(text.suffix(60))")
        #endif
        if WakePhraseMatcher.containsWakePhrase(text) {
            #if DEBUG
            print("[WAKE] wake phrase matched")
            #endif
            await handleWakePhraseDetected(token: token)
        }
    }

    /// Handles events emitted by the Gemini Live session.
    private func handleLiveEvent(_ event: LiveEvent, token: UUID) async {
        guard currentSessionToken == token else { return }
        switch event {
        case .connected:
            isSetupAcknowledged = true
            setupWatchdogTask?.cancel()
            setupWatchdogTask = nil
            if latency.setupAck == nil {
                latency.setupAck = elapsed(since: sessionStartedAt)
                #if DEBUG
                print("[LIVE METRICS] connect=\(Self.ms(latency.connect)) setupAck=\(Self.ms(latency.setupAck))")
                #endif
            }
            if state == .connecting {
                transition(to: .listening)
            }

        case .toolCall(let call):
            drainTask?.cancel()
            drainTask = nil

            let callKey = call.id ?? "\(call.name):\(call.args.description)"
            if executedToolCallIds.contains(callKey) {
                #if DEBUG
                print("[TOOL] duplicate function call suppressed: \(callKey)")
                #endif
                return
            }
            executedToolCallIds.insert(callKey)

            pendingToolCalls += 1
            transition(to: .thinking)
            executingToolName = call.name

            toolExecutionTask?.cancel()
            toolExecutionTask = Task { [weak self, session] in
                guard let self, self.currentSessionToken == token else { return }

                // Check if tool is classified as safe; if safe, transition directly to .toolExecution
                if let tool = self.toolDispatcher.registry.tool(named: call.name) {
                    let classification = self.toolDispatcher.safetyGate.policy?.classification(for: tool, call: call) ?? tool.safetyClassification
                    if classification == .safe {
                        self.transition(to: .toolExecution)
                    }
                }

                let response = await self.toolDispatcher.dispatch(call)

                guard self.currentSessionToken == token else {
                    #if DEBUG
                    print("[TOOL] Session token changed while dispatching tool; discarding result")
                    #endif
                    return
                }
                self.pendingToolCalls = max(0, self.pendingToolCalls - 1)
                // State stays TOOL_EXECUTION until the spoken reply arrives (no THINKING flicker in between).

                do {
                    try await session.sendToolResponse(response)
                    self.turnReferenceAt = self.clock.now
                } catch {
                    guard self.currentSessionToken == token else { return }
                    await self.handleFailure(error, token: token)
                }
            }

        case .audioChunk(let data):
            if isDiscardingInterruptedTurn {
                // Leftover audio of a turn the user interrupted with "Hey Ivy": never play it.
                return
            }
            drainTask?.cancel()
            drainTask = nil
            if !isModelTurnOpen {
                isModelTurnOpen = true
                latency.firstAudio = elapsed(since: turnReferenceAt)
                latency.playbackStart = nil
                latency.responseComplete = nil
            }
            // A pending approval card stays up even if the model narrates meanwhile.
            if state != .toolConfirmation && state != .speaking {
                executingToolName = nil
                transition(to: .speaking)
            }

            let epoch = playbackEpoch
            do {
                try await audioPlayer.playChunk(data)
            } catch {
                await handleFailure(error, token: token)
                return
            }
            guard epoch == playbackEpoch else {
                // Playback was stopped (interruption/teardown) while this chunk was being scheduled.
                await audioPlayer.stop()
                return
            }
            if latency.playbackStart == nil {
                latency.playbackStart = elapsed(since: turnReferenceAt)
            }

        case .textTurn(let text):
            latestTranscript = text

        case .turnComplete:
            if isDiscardingInterruptedTurn {
                // The interrupted turn is finally closed; the next audio belongs to a fresh reply.
                isDiscardingInterruptedTurn = false
                return
            }
            isModelTurnOpen = false
            switch state {
            case .speaking:
                // Generation is done but queued audio may still be playing; LISTENING only once it drains.
                drainTask?.cancel()
                drainTask = Task { [weak self] in
                    guard let self, self.currentSessionToken == token else { return }
                    await self.audioPlayer.waitUntilFinished()
                    guard !Task.isCancelled, self.currentSessionToken == token, self.state == .speaking else { return }
                    self.latency.responseComplete = self.elapsed(since: self.turnReferenceAt)
                    #if DEBUG
                    print("[LIVE METRICS] firstAudio=\(Self.ms(self.latency.firstAudio)) playbackStart=\(Self.ms(self.latency.playbackStart)) complete=\(Self.ms(self.latency.responseComplete))")
                    #endif
                    self.turnReferenceAt = nil
                    await self.finishTurn()
                }
            case .thinking, .toolExecution:
                // Turn ended without any speech (and no tool still running): reopen the mic instead of stalling.
                guard pendingToolCalls == 0 else { break }
                executingToolName = nil
                await finishTurn()
            default:
                break
            }

        case .interrupted:
            // Server-side barge-in closes the current turn itself; nothing left to discard.
            isDiscardingInterruptedTurn = false
            isModelTurnOpen = false
            drainTask?.cancel()
            drainTask = nil
            toolExecutionTask?.cancel()
            toolExecutionTask = nil
            executingToolName = nil
            cancelPendingConfirmation()
            await stopPlayback()
            await wakeWordDetector.reset()
            guard currentSessionToken == token else { return }
            transition(to: .listening)

        case .disconnected:
            // Our own stopSession() clears the token first, so reaching here means the socket dropped under us.
            await handleFailure(LiveError.sessionClosed, token: token)
        }
    }

    /// Ends a model turn: back to LISTENING, or closes a push-to-talk session whose key is already released.
    private func finishTurn() async {
        await wakeWordDetector.reset()
        if wasSessionStartedByPushToTalk && !isPushToTalkActive {
            await stopSession()
        } else {
            transition(to: .listening)
        }
    }

    private func transition(to next: VoiceSessionState) {
        guard state != next else { return }
        #if DEBUG
        print("[VOICE] \(state.debugName) -> \(next.debugName)")
        #endif
        state = next
    }

    private func stopPlayback() async {
        playbackEpoch += 1
        await audioPlayer.stop()
    }

    private func cancelPendingConfirmation() {
        guard let cont = confirmationContinuation else {
            pendingConfirmation = nil
            return
        }
        confirmationContinuation = nil
        pendingConfirmation = nil
        cont.resume(returning: false)
    }

    /// Fails the session if the server never acknowledges setup (otherwise mic sends would wait forever).
    private func startSetupWatchdog(token: UUID) {
        setupWatchdogTask?.cancel()
        setupWatchdogTask = Task { [weak self, setupTimeout] in
            do {
                try await Task.sleep(for: setupTimeout)
            } catch {
                return // cancelled: setup was acknowledged or the session ended
            }
            guard let self, self.currentSessionToken == token, !self.isSetupAcknowledged else { return }
            await self.handleFailure(LiveError.timeout("no setup acknowledgement from the server."), token: token)
        }
    }

    /// Full teardown (mic tap, capture/drain/tool tasks, playback, socket, session token), then a stable error state.
    private func handleFailure(_ error: Error, token: UUID) async {
        guard currentSessionToken == token else { return }
        await tearDown(then: .error(error.localizedDescription))
    }

    private func elapsed(since start: ContinuousClock.Instant?) -> Duration? {
        start.map { clock.now - $0 }
    }

    static func ms(_ duration: Duration?) -> String {
        guard let duration else { return "n/a" }
        let (seconds, attoseconds) = duration.components
        return "\(seconds * 1000 + attoseconds / 1_000_000_000_000_000)ms"
    }

    /// ponytail: peak-amplitude gate, not real VAD. It only timestamps end-of-speech for latency metrics,
    /// so background noise skews numbers rather than behavior; swap for server input transcription if precision matters.
    static func containsVoice(_ pcm: Data, threshold: Int16 = 1000) -> Bool {
        let bytes = [UInt8](pcm)
        var i = 0
        while i + 1 < bytes.count {
            let sample = Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
            if sample > threshold || sample < -threshold { return true }
            i += 2
        }
        return false
    }
}

extension GeminiLiveVoiceCoordinator: ConfirmationHandler {
    public func handleConfirmation(_ request: ConfirmationRequest) async -> Bool {
        // A tool task that outlived its session must not raise a card nobody can resolve.
        guard currentSessionToken != nil else { return false }
        cancelPendingConfirmation()
        self.pendingConfirmation = request
        transition(to: .toolConfirmation)
        // respondToPendingConfirmation / interruption / teardown own every state change after this point.
        return await withCheckedContinuation { continuation in
            self.confirmationContinuation = continuation
        }
    }
}
