import Foundation
import os
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
    /// The socket dropped; the session is kept while Ivy reconnects (attempt number, starting at 1).
    case reconnecting(Int)
    case error(String)

    public var isLive: Bool {
        switch self {
        case .connecting, .listening, .thinking, .toolConfirmation, .toolExecution, .speaking, .interrupting, .reconnecting:
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
        case .reconnecting: return "RECONNECTING"
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
    /// Production key source; nil when a session was injected with its own key (tests).
    private var credentials: CredentialProvider? = nil

    /// Receives each finished utterance of a session as text: (text, spoken by the user, cut off by an interruption).
    public var onTranscript: ((String, Bool, Bool) -> Void)?
    /// Receives every tool a voice session ran, with its result, so the conversation can remember it.
    public var onToolResult: ((FunctionCall, FunctionResponse) -> Void)?
    private var heardText = ""
    private var spokenText = ""

    /// Loudness of the user's voice and of Ivy's, for the UI.
    public let levelMeter = AudioLevelMeter()
    /// True while the user is audibly speaking during LISTENING.
    @Published public private(set) var isHearingUser: Bool = false
    /// "Hey Ivy, mute": the mic stays open for "Hey Ivy" only; nothing is streamed to Gemini.
    @Published public private(set) var isMuted: Bool = false
    /// Lets a lone "Ivy" (without "hey") interrupt while the user is audibly speaking. Off by default:
    /// its false-trigger rate has not been measured.
    public var loneIvyInterrupts: Bool = false
    private var vad = VoiceActivityDetector()
    /// Mic audio captured before the socket is up (and handed over by the idle wake listener); sent first.
    private var preRoll = PCMRingBuffer(seconds: 3)
    /// The user just said "Hey Ivy": their next utterance may be a bare command ("stop", "cancel", …).
    private var isAwaitingCommand = false
    /// Audio of the reply in progress and of the last finished one, for "repeat that". Memory only, this session only.
    private var currentReplyAudio: [Data] = []
    private var lastReplyAudio: [Data] = []
    private var outputLevels: [(at: ContinuousClock.Instant, level: Float)] = []
    private var outputLevelTask: Task<Void, Never>? = nil

    /// Background tasks currently owned by a session. Must be 0 whenever the coordinator is idle (leak invariant).
    var activeTaskCount: Int {
        [captureTask, eventTask, drainTask, toolExecutionTask, setupWatchdogTask, wakeWatchdogTask, reconnectTask]
            .filter { $0 != nil }.count
    }

    private var isReconnecting: Bool {
        if case .reconnecting = state { return true }
        return false
    }

    public private(set) var isPushToTalkActive: Bool = false
    public private(set) var wasSessionStartedByPushToTalk: Bool = false
    /// Started by the idle "Hey Ivy" wake word: ends after one answered turn, or after silence.
    public private(set) var wasSessionStartedByWakeWord: Bool = false
    private let wakeSilenceTimeout: Duration
    /// Wake sessions that closed without hearing a request (likely false triggers). Local only, this launch only.
    public private(set) var unansweredWakeCount = 0
    private var wakeWatchdogTask: Task<Void, Never>? = nil
    private var lastHeardVoiceAt: ContinuousClock.Instant? = nil
    private var currentSessionToken: UUID? = nil

    private var confirmationContinuation: CheckedContinuation<Bool, Never>? = nil
    private var executedToolCallIds: Set<String> = []
    private var toolExecutionTask: Task<Void, Never>? = nil
    private var pendingToolCalls = 0

    private var captureTask: Task<Void, Never>? = nil
    private var eventTask: Task<Void, Never>? = nil
    private var drainTask: Task<Void, Never>? = nil
    private var setupWatchdogTask: Task<Void, Never>? = nil
    /// A new session waits for in-flight teardowns, so an old teardown's late steps (mic stop, socket
    /// disconnect) can never land on the new session during a rapid stop/start (e.g. PTT press-release-press).
    /// 0 (the default for injected sessions) keeps the old behaviour: a dropped socket ends the session.
    private let maxReconnectAttempts: Int
    private let reconnectBaseDelay: Duration
    private let reconnectOfflineGrace: Duration
    private let networkPath: NetworkPathChecking
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>? = nil
    /// Reconnect only sessions that were working; a first connect that fails is reported straight away.
    private var hasBeenEstablished = false
    /// Bumped for every (re)connection, so failures reported by tasks of a dead socket are ignored.
    private var connectionEpoch = 0
    private var teardownsInFlight = 0
    private var teardownWaiters: [CheckedContinuation<Void, Never>] = []
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
        setupTimeout: Duration = .seconds(15),
        wakeSilenceTimeout: Duration = .seconds(8),
        maxReconnectAttempts: Int = 0,
        reconnectBaseDelay: Duration = .milliseconds(500),
        reconnectOfflineGrace: Duration = .seconds(30),
        networkPath: NetworkPathChecking = AlwaysOnlineNetworkPath()
    ) {
        self.session = session
        self.audioCapture = audioCapture
        self.audioPlayer = audioPlayer
        self.wakeWordDetector = wakeWordDetector
        self.hotkeyManager = hotkeyManager
        self.setupTimeout = setupTimeout
        self.wakeSilenceTimeout = wakeSilenceTimeout
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectBaseDelay = reconnectBaseDelay
        self.reconnectOfflineGrace = reconnectOfflineGrace
        self.networkPath = networkPath

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
    /// One line per "Hey Ivy" barge-in (`log stream --predicate 'subsystem == "com.ivy.assistant"'`); never the transcript.
    nonisolated static let bargeInLog = Logger(subsystem: "com.ivy.assistant", category: "barge-in")

    /// Convenience initializer using production implementations. The Gemini key is re-read from `credentials`
    /// at every session start, so a key saved in settings applies without relaunching.
    public convenience init(
        credentials: CredentialProvider = KeychainCredentialProvider(),
        echoCancellation: Bool = true,
        model: String = "models/gemini-3.1-flash-live-preview",
        voiceName: String = liveVoiceName,
        systemInstruction: String = IvyPersona.systemPrompt,
        hotkeyManager: GlobalHotkeyManaging? = nil,
        toolDispatcher: ToolDispatcher? = nil,
        transcribesAudio: Bool = false,
        silenceDurationMs: Int? = nil,
        toolRegistry: ToolRegistry? = nil
    ) {
        let bridge = ConfirmationBridge()
        let safetyGate = InteractiveSafetyGate(confirmationProvider: bridge)
        // Live declares every tool once, at setup: there is no later request to add a group to.
        let dispatcher = toolDispatcher ?? ToolDispatcher(registry: toolRegistry ?? .standardRegistry(), safetyGate: safetyGate)
        let client = GeminiLiveClient(
            apiKey: credentials.credential(for: .geminiAPIKey) ?? "",
            model: model,
            voiceName: Self.liveVoiceName,
            systemInstruction: systemInstruction,
            tools: dispatcher.registry.toolDeclarations,
            transcribesAudio: transcribesAudio,
            silenceDurationMs: silenceDurationMs
        )
        // Capture and playback share one engine so voice processing can cancel Ivy's own voice from the mic.
        let engine = AVAudioEngine()
        let capture = SystemAudioCapture(audioEngine: engine, voiceProcessing: echoCancellation)
        let player = SystemLiveAudioPlayer(audioEngine: engine, ownsEngine: false)
        let detector = SystemWakeWordDetector()
        self.init(
            session: client,
            audioCapture: capture,
            audioPlayer: player,
            wakeWordDetector: detector,
            hotkeyManager: hotkeyManager,
            toolDispatcher: dispatcher,
            maxReconnectAttempts: 4,
            networkPath: SystemNetworkPath()
        )
        self.credentials = credentials
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
        case .connecting, .thinking, .speaking, .interrupting, .toolConfirmation, .toolExecution, .reconnecting:
            // Active session or transition in progress; do not start duplicate or interrupt speaking
            break
        }
    }

    /// Starts a session because the idle "Hey Ivy" wake word fired. Like "Hey Siri", it answers one request and
    /// closes; if nobody speaks within `wakeSilenceTimeout` (e.g. a false trigger) it closes without a turn.
    /// `preRoll` is what the idle listener heard around the wake phrase (16 kHz PCM), so a request spoken in the
    /// same breath ("Hey Ivy, what time is it?") is not lost.
    public func startWakeSession(preRoll: Data = Data()) async {
        guard !state.isLive else { return }
        await startSession(preRoll: preRoll)
        guard state.isLive, let token = currentSessionToken else { return }
        wasSessionStartedByWakeWord = true
        let startedAt = clock.now
        wakeWatchdogTask = Task { [weak self] in
            while true {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return // cancelled by teardown
                }
                guard let self, self.currentSessionToken == token else { return }
                // A reply (or tool activity) has started: the turn-end path closes the session from here.
                guard self.state == .listening || self.state == .connecting else { return }
                let reference = max(startedAt, self.lastHeardVoiceAt ?? startedAt)
                if self.clock.now - reference > self.wakeSilenceTimeout {
                    print("[VOICE] wake session closed: no request heard")
                    self.unansweredWakeCount += 1
                    await self.stopSession()
                    return
                }
            }
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
            if state == .listening || state == .connecting || isReconnecting {
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
    public func startSession(preRoll initialAudio: Data = Data()) async {
        if state.isLive {
            await stopSession()
        }
        while teardownsInFlight > 0 {
            await withCheckedContinuation { teardownWaiters.append($0) }
        }

        if let credentials {
            updateApiKey(credentials.credential(for: .geminiAPIKey) ?? "")
        }
        let token = UUID()
        self.currentSessionToken = token
        transition(to: .connecting)
        latestTranscript = ""
        latency = LiveLatencyMetrics()
        sessionStartedAt = clock.now
        isSetupAcknowledged = false
        vad = VoiceActivityDetector()
        preRoll = PCMRingBuffer(seconds: 3)
        preRoll.append(initialAudio)

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

        // Open the microphone before the socket: what the user says while it connects is kept and sent first.
        do {
            let audioStream = try await audioCapture.startCapture()
            guard currentSessionToken == token else {
                await audioCapture.stopCapture()
                return
            }
            startCaptureLoop(audioStream, token: token)
        } catch {
            guard currentSessionToken == token else { return }
            await tearDown(then: .error("Failed to start audio capture: \(error.localizedDescription)"))
            return
        }

        // Connect to Gemini Live
        do {
            try await session.connect()
        } catch {
            guard currentSessionToken == token else { return }
            await tearDown(then: .error("Failed to connect to Ivy Live: \(error.localizedDescription)"))
            return
        }
        guard currentSessionToken == token else {
            await session.disconnect()
            return
        }
        latency.connect = elapsed(since: sessionStartedAt)
        connectionEpoch += 1
        startSetupWatchdog(token: token)
        startEventLoop(token: token)
        if state == .connecting {
            transition(to: .listening)
        }
    }

    private func startCaptureLoop(_ audioStream: AsyncThrowingStream<Data, Error>, token: UUID) {
        captureTask = Task { [weak self, session] in
            var sentAudioFrameCount = 0
            do {
                for try await chunk in audioStream {
                    guard !Task.isCancelled else { break }
                    guard let self, self.currentSessionToken == token else { break }

                    let heardVoice = self.vad.process(chunk)
                    self.levelMeter.reportInput(self.vad.level)
                    let hearing = self.vad.isSpeech && self.state == .listening && !self.isMuted
                    if self.isHearingUser != hearing { self.isHearingUser = hearing }

                    switch self.state {
                    case .speaking, .toolConfirmation, .thinking, .toolExecution:
                        await self.monitorForWakePhrase(chunk, token: token)
                    case .listening where self.isMuted:
                        await self.monitorForWakePhrase(chunk, token: token)
                    case .connecting:
                        // No socket yet: hold the audio (bounded, memory only) so the start of the request isn't lost.
                        self.preRoll.append(chunk)
                    case .listening:
                        // Active user-turn capture: stream audio chunk to Gemini Live.
                        if heardVoice {
                            self.turnReferenceAt = self.clock.now
                            self.lastHeardVoiceAt = self.turnReferenceAt
                        }
                        let epoch = self.connectionEpoch
                        do {
                            if !self.preRoll.isEmpty {
                                // ponytail: quarter-second frames keep each WebSocket message small.
                                let held = self.preRoll.drain()
                                for offset in stride(from: 0, to: held.count, by: 8000) {
                                    try await session.sendAudio(held.subdata(in: offset..<min(offset + 8000, held.count)))
                                }
                            }
                            try await session.sendAudio(chunk)
                        } catch {
                            // The socket died under us: recover (or fail) the connection, keep the mic loop alive.
                            guard self.currentSessionToken == token else { break }
                            await self.handleFailure(error, token: token, epoch: epoch)
                            continue
                        }
                        sentAudioFrameCount += 1
                        if sentAudioFrameCount == 1 || sentAudioFrameCount % 50 == 0 {
                            print("[AUDIO] PCM frame sent count=\(sentAudioFrameCount) bytes=\(chunk.count)")
                        }
                    case .idle, .interrupting, .reconnecting, .error:
                        // Mic audio is dropped: these states must never feed Gemini Live.
                        break
                    }
                }
            } catch {
                // The microphone stream itself failed: nothing a reconnect can fix.
                guard let self, self.currentSessionToken == token else { return }
                await self.tearDown(then: .error(error.localizedDescription))
            }
        }
    }

    /// Monitoring mode: mic audio is NOT streamed to Gemini Live. While Ivy speaks this prevents server-side
    /// barge-in on her own voice; during a confirmation, saying "yes" must never approve a SafetyGate request.
    /// Only the explicit "Hey Ivy" wake phrase is listened for, on this Mac.
    private func monitorForWakePhrase(_ chunk: Data, token: UUID) async {
        let detected = await wakeWordDetector.processAudioChunk(chunk)
        guard currentSessionToken == token, detected else { return }
        await handleWakePhraseDetected(token: token)
    }

    /// Cleanly terminates the live voice session.
    public func stopSession() async {
        await tearDown(then: .idle)
    }

    /// Releases mic, playback, tasks, and socket, then settles in `finalState` (no IDLE flicker on the way to ERROR).
    /// Hands the buffered transcripts to `onTranscript`: the user's words first, then Ivy's.
    private func flushTranscripts(interrupted: Bool) {
        flushHeard()
        let spoken = spokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        spokenText = ""
        if !spoken.isEmpty { onTranscript?(spoken, false, interrupted) }
    }

    private func flushHeard() {
        let heard = heardText.trimmingCharacters(in: .whitespacesAndNewlines)
        heardText = ""
        if !heard.isEmpty { onTranscript?(heard, true, false) }
    }

    private func tearDown(then finalState: VoiceSessionState) async {
        // A session that ends mid-reply still keeps what was said so far.
        flushTranscripts(interrupted: isModelTurnOpen)
        currentSessionToken = nil
        captureTask?.cancel()
        eventTask?.cancel()
        drainTask?.cancel()
        toolExecutionTask?.cancel()
        setupWatchdogTask?.cancel()
        wakeWatchdogTask?.cancel()
        wakeWatchdogTask = nil
        lastHeardVoiceAt = nil
        reconnectAttempt = 0
        hasBeenEstablished = false
        connectionEpoch += 1
        reconnectTask?.cancel()
        reconnectTask = nil
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
        isAwaitingCommand = false
        isMuted = false
        isHearingUser = false
        _ = preRoll.drain()
        currentReplyAudio = []
        lastReplyAudio = []

        teardownsInFlight += 1
        await audioCapture.stopCapture()
        await stopPlayback()
        await wakeWordDetector.reset()
        await session.disconnect()
        teardownsInFlight -= 1
        if teardownsInFlight == 0 {
            let waiters = teardownWaiters
            teardownWaiters = []
            waiters.forEach { $0.resume() }
        }

        // A session started during the awaits above owns the state now.
        guard currentSessionToken == nil else { return }
        transition(to: finalState)
        latestTranscript = ""
        wasSessionStartedByPushToTalk = false
        wasSessionStartedByWakeWord = false
        levelMeter.reset()
    }

    /// States in which "Hey Ivy" is listened for locally instead of streaming the mic to Gemini.
    private var isMonitoringForWakePhrase: Bool {
        switch state {
        case .speaking, .toolConfirmation, .thinking, .toolExecution: return true
        case .listening: return isMuted
        default: return false
        }
    }

    /// Handles explicit wake phrase ("Hey Ivy") detection while Ivy is speaking or waiting for confirmation.
    public func handleWakePhraseDetected(token: UUID? = nil) async {
        if let token, currentSessionToken != token { return }
        guard isMonitoringForWakePhrase else { return }
        // What the user says next may be a bare command ("stop", "cancel", "goodbye", …).
        isAwaitingCommand = true

        if state == .listening {
            // Muted: "Hey Ivy" reopens the microphone.
            isMuted = false
            await wakeWordDetector.reset()
            return
        }
        if state == .thinking || state == .toolExecution {
            // The turn is abandoned: whatever Ivy says about it is dropped. A tool that is already running is
            // left to finish and report back, so the server can close the turn (and end the discarding).
            isDiscardingInterruptedTurn = true
            await wakeWordDetector.reset()
            guard isMonitoringForWakePhrase else { return }
            transition(to: .listening)
            Self.bargeInLog.notice("barge-in: wake phrase cancelled the turn in progress")
            return
        }

        if !currentReplyAudio.isEmpty { lastReplyAudio = currentReplyAudio }
        flushTranscripts(interrupted: true)
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
        Self.bargeInLog.notice("barge-in: wake phrase interrupted speech; playback stopped, listening")
    }

    /// Evaluates transcription text directly for "Hey Ivy" interruption.
    public func processTranscriptionForInterruption(_ text: String, token: UUID? = nil) async {
        if let token, currentSessionToken != token { return }
        guard isMonitoringForWakePhrase else { return }
        #if DEBUG
        print("[WAKE] recognition partial chars=\(text.count)")
        #endif
        let loneIvy = loneIvyInterrupts && vad.isSpeech && WakePhraseMatcher.containsIvy(text)
        if WakePhraseMatcher.containsWakePhrase(text) || loneIvy {
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
            hasBeenEstablished = true
            setupWatchdogTask?.cancel()
            setupWatchdogTask = nil
            if case .reconnecting = state {
                print("[LIVE] reconnected after \(reconnectAttempt) attempt(s)")
                reconnectAttempt = 0
                transition(to: .listening)
            }
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
            if await interceptCommand(token: token) { return }
            if isDiscardingInterruptedTurn {
                // The user abandoned this turn: its tools are never run. Answering lets the server close the turn.
                do {
                    try await session.sendToolResponse(FunctionResponse(name: call.name, response: ["error": "Cancelled by the user."], id: call.id))
                } catch {
                    await handleFailure(error, token: token, epoch: connectionEpoch)
                }
                return
            }
            drainTask?.cancel()
            drainTask = nil

            let callKey = call.id ?? "\(call.name):\(call.args.description)"
            if executedToolCallIds.contains(callKey) {
                #if DEBUG
                print("[TOOL] duplicate function call suppressed: \(call.name)")
                #endif
                return
            }
            executedToolCallIds.insert(callKey)

            pendingToolCalls += 1
            transition(to: .thinking)
            executingToolName = call.name

            toolExecutionTask?.cancel()
            let toolEpoch = connectionEpoch
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
                self.onToolResult?(call, response)

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
                    await self.handleFailure(error, token: token, epoch: toolEpoch)
                }
            }

        case .audioChunk(let data):
            if isDiscardingInterruptedTurn {
                // Leftover audio of a turn the user interrupted with "Hey Ivy": never play it.
                return
            }
            if await interceptCommand(token: token) { return }
            drainTask?.cancel()
            drainTask = nil
            if !isModelTurnOpen {
                isModelTurnOpen = true
                currentReplyAudio = []
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
                // Local playback failure: reconnecting the socket can't fix it.
                guard currentSessionToken == token else { return }
                await tearDown(then: .error(error.localizedDescription))
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
            currentReplyAudio.append(data)
            scheduleOutputLevels(for: data)

        case .textTurn(let text):
            latestTranscript = text

        case .inputTranscript(let text):
            heardText += text

        case .outputTranscript(let text):
            // The rest of a reply the user cut off with "Hey Ivy" was never heard: don't record it.
            if isDiscardingInterruptedTurn { return }
            if await interceptCommand(token: token) { return }
            // Ivy has started answering, so the user's utterance is complete.
            if spokenText.isEmpty { flushHeard() }
            spokenText += text

        case .turnComplete:
            if isDiscardingInterruptedTurn {
                // The interrupted turn is finally closed; the next audio belongs to a fresh reply.
                isDiscardingInterruptedTurn = false
                return
            }
            if await interceptCommand(token: token) {
                // The reply to a command ended before anything of it was played.
                isDiscardingInterruptedTurn = false
                return
            }
            flushTranscripts(interrupted: false)
            isModelTurnOpen = false
            if !currentReplyAudio.isEmpty { lastReplyAudio = currentReplyAudio }
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
            if !currentReplyAudio.isEmpty { lastReplyAudio = currentReplyAudio }
            flushTranscripts(interrupted: true)
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
            await handleFailure(LiveError.sessionClosed, token: token, epoch: connectionEpoch)
        }
    }

    /// Ends a model turn: back to LISTENING, or closes a push-to-talk session whose key is already released.
    private func finishTurn() async {
        await wakeWordDetector.reset()
        if (wasSessionStartedByPushToTalk && !isPushToTalkActive) || wasSessionStartedByWakeWord {
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
        outputLevelTask?.cancel()
        outputLevelTask = nil
        outputLevels = []
        levelMeter.reportOutput(0)
        await audioPlayer.stop()
    }

    /// Queues the loudness of a reply chunk (24 kHz PCM) against the time it will actually be heard: chunks
    /// arrive faster than they play, so reporting on arrival would show a burst and then nothing.
    private func scheduleOutputLevels(for data: Data) {
        let window = 2400 // 50 ms
        var at = max(clock.now, outputLevels.last.map { $0.at + .milliseconds(50) } ?? clock.now)
        for offset in stride(from: 0, to: data.count, by: window) {
            outputLevels.append((at, VoiceActivityDetector.level(of: data.subdata(in: offset..<min(offset + window, data.count)))))
            at += .milliseconds(50)
        }
        guard outputLevelTask == nil else { return }
        outputLevelTask = Task { [weak self] in
            while let self, let next = self.outputLevels.first {
                do {
                    try await Task.sleep(until: next.at, clock: self.clock)
                } catch {
                    return // playback was stopped; stopPlayback() already zeroed the meter
                }
                guard !self.outputLevels.isEmpty else { return }
                self.levelMeter.reportOutput(self.outputLevels.removeFirst().level)
            }
            self?.levelMeter.reportOutput(0)
            self?.outputLevelTask = nil
        }
    }

    /// Runs when the first piece of a reply arrives, i.e. once the user's utterance is complete. If that
    /// utterance was one of Ivy's own commands, it is handled here and the model's reply to it is dropped
    /// (returns true). The allow-list cannot approve anything: a pending confirmation is only ever denied.
    private func interceptCommand(token: UUID) async -> Bool {
        guard !heardText.isEmpty else { return false }
        let command = VoiceCommand.parse(heardText, afterWake: isAwaitingCommand)
        isAwaitingCommand = false
        guard let command else { return false }
        heardText = ""
        print("[VOICE] local command handled")
        switch command {
        case .endSession:
            await stopSession()
            return true
        case .stop:
            break
        case .cancel:
            cancelPendingConfirmation()
        case .mute:
            isMuted = true
        case .unmute:
            isMuted = false
        case .repeatLast:
            isDiscardingInterruptedTurn = true
            await replayLastReply(token: token)
            return true
        }
        isDiscardingInterruptedTurn = true
        return true
    }

    /// "Repeat that": plays the last reply again from memory.
    private func replayLastReply(token: UUID) async {
        guard !lastReplyAudio.isEmpty else { return }
        transition(to: .speaking)
        let epoch = playbackEpoch
        for chunk in lastReplyAudio {
            do {
                try await audioPlayer.playChunk(chunk)
            } catch {
                guard currentSessionToken == token else { return }
                await tearDown(then: .error(error.localizedDescription))
                return
            }
            guard epoch == playbackEpoch, currentSessionToken == token else { return }
            scheduleOutputLevels(for: chunk)
        }
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            guard let self else { return }
            await self.audioPlayer.waitUntilFinished()
            guard !Task.isCancelled, self.currentSessionToken == token, self.state == .speaking else { return }
            await self.finishTurn()
        }
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
        let epoch = connectionEpoch
        setupWatchdogTask = Task { [weak self, setupTimeout] in
            do {
                try await Task.sleep(for: setupTimeout)
            } catch {
                return // cancelled: setup was acknowledged or the session ended
            }
            guard let self, self.currentSessionToken == token, !self.isSetupAcknowledged else { return }
            await self.handleFailure(LiveError.timeout("no setup acknowledgement from the server."), token: token, epoch: epoch)
        }
    }

    /// Consumes the current connection's events; a stream failure is reported with this connection's epoch.
    private func startEventLoop(token: UUID) {
        eventTask?.cancel()
        let epoch = connectionEpoch
        let events = session.receiveEvents()
        eventTask = Task { [weak self] in
            do {
                for try await event in events {
                    guard !Task.isCancelled else { break }
                    guard let self, self.currentSessionToken == token, self.connectionEpoch == epoch else { break }
                    await self.handleLiveEvent(event, token: token)
                }
            } catch {
                guard let self, self.currentSessionToken == token else { return }
                await self.handleFailure(error, token: token, epoch: epoch)
            }
        }
    }

    /// Full teardown (mic tap, capture/drain/tool tasks, playback, socket, session token), then a stable error state.
    private func handleFailure(_ error: Error, token: UUID, epoch: Int) async {
        // A task of an already-replaced connection failing is old news: the reconnect loop owns recovery.
        guard currentSessionToken == token, epoch == connectionEpoch else { return }
        guard hasBeenEstablished, reconnectAttempt < maxReconnectAttempts, Self.isRecoverable(error) else {
            await tearDown(then: .error(error.localizedDescription))
            return
        }
        // Claim the recovery synchronously (later reports of the same drop see a newer epoch), then run it in its
        // own task: the caller is usually the dead connection's event loop, which the reconnect cancels.
        connectionEpoch += 1
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            await self?.reconnect(after: error, token: token)
        }
    }

    static func isRecoverable(_ error: Error) -> Bool {
        if let live = error as? LiveError { return live.isRecoverable }
        return error is URLError
    }

    /// Keeps the session (mic, conversation, state machine) and replaces only the dead socket, with backoff.
    /// Anything tied to the old socket is dropped: queued audio, the partial model turn, and a pending tool
    /// confirmation (denied — a tool is never executed for a connection that no longer exists).
    private func reconnect(after error: Error, token: UUID) async {
        var lastError = error
        eventTask?.cancel()
        eventTask = nil
        drainTask?.cancel()
        drainTask = nil
        toolExecutionTask?.cancel()
        toolExecutionTask = nil
        setupWatchdogTask?.cancel()
        setupWatchdogTask = nil
        cancelPendingConfirmation()
        executingToolName = nil
        pendingToolCalls = 0
        isModelTurnOpen = false
        isDiscardingInterruptedTurn = false
        await stopPlayback()
        await wakeWordDetector.reset()

        while currentSessionToken == token, reconnectAttempt < maxReconnectAttempts {
            reconnectAttempt += 1
            transition(to: .reconnecting(reconnectAttempt))
            print("[LIVE] connection lost; reconnect attempt \(reconnectAttempt)/\(maxReconnectAttempts)")
            await session.disconnect()
            guard currentSessionToken == token else { return }

            guard await networkPath.waitUntilOnline(timeout: reconnectOfflineGrace) else {
                lastError = LiveError.connectionFailed("the Mac is offline.")
                break
            }
            do {
                try await Task.sleep(for: reconnectBaseDelay * (1 << (reconnectAttempt - 1)))
            } catch {
                return // the session was torn down while waiting
            }
            guard currentSessionToken == token else { return }

            do {
                isSetupAcknowledged = false
                connectionEpoch += 1
                try await session.connect()
                guard currentSessionToken == token else {
                    await session.disconnect()
                    return
                }
                startSetupWatchdog(token: token)
                startEventLoop(token: token)
                return // `.connected` moves RECONNECTING → LISTENING; a new failure re-enters with the attempts used so far
            } catch {
                lastError = error
                if !Self.isRecoverable(error) { break }
            }
        }

        guard currentSessionToken == token else { return }
        await tearDown(then: .error("Lost connection to Ivy Live: \(lastError.localizedDescription)"))
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
