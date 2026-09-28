import Foundation
import Combine

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
}

/// Coordinates microphone audio capture, Gemini Live session streaming, and native audio playback.
@MainActor
public final class GeminiLiveVoiceCoordinator: ObservableObject {
    @Published public private(set) var state: VoiceSessionState = .idle
    @Published public private(set) var latestTranscript: String = ""
    @Published public private(set) var pendingConfirmation: ConfirmationRequest? = nil
    @Published public private(set) var executingToolName: String? = nil

    public let session: GeminiLiveSession
    public let audioCapture: AudioCaptureProtocol
    public let audioPlayer: LiveAudioPlayerProtocol
    public let wakeWordDetector: WakeWordDetectorProtocol
    public let hotkeyManager: GlobalHotkeyManaging?
    public let toolDispatcher: ToolDispatcher

    public private(set) var isPushToTalkActive: Bool = false
    public private(set) var wasSessionStartedByPushToTalk: Bool = false
    private var currentSessionToken: UUID? = nil

    private var confirmationContinuation: CheckedContinuation<Bool, Never>? = nil
    private var executedToolCallIds: Set<String> = []
    private var toolExecutionTask: Task<Void, Never>? = nil

    private var captureTask: Task<Void, Never>? = nil
    private var eventTask: Task<Void, Never>? = nil
    private var drainTask: Task<Void, Never>? = nil

    public init(
        session: GeminiLiveSession,
        audioCapture: AudioCaptureProtocol,
        audioPlayer: LiveAudioPlayerProtocol,
        wakeWordDetector: WakeWordDetectorProtocol = SystemWakeWordDetector(),
        hotkeyManager: GlobalHotkeyManaging? = nil,
        toolDispatcher: ToolDispatcher? = nil
    ) {
        self.session = session
        self.audioCapture = audioCapture
        self.audioPlayer = audioPlayer
        self.wakeWordDetector = wakeWordDetector
        self.hotkeyManager = hotkeyManager

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
        let capture = SystemAudioCapture()
        let player = SystemLiveAudioPlayer()
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
        if approved {
            state = .toolExecution
        } else {
            state = .thinking
        }
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
        hotkeyManager?.unregister()
    }

    /// Starts a live voice conversation session.
    public func startSession() async {
        if state.isLive {
            await stopSession()
        }

        let token = UUID()
        self.currentSessionToken = token
        state = .connecting
        latestTranscript = ""

        // Check microphone permission
        let hasMicPermission = await audioCapture.requestPermission()
        guard currentSessionToken == token else { return }
        guard hasMicPermission else {
            state = .error(LiveError.microphonePermissionDenied.localizedDescription)
            return
        }

        // Request speech recognition permission for wake phrase interruption
        _ = await wakeWordDetector.requestPermission()
        guard currentSessionToken == token else { return }

        // Connect to Gemini Live
        do {
            try await session.connect()
        } catch {
            guard currentSessionToken == token else { return }
            state = .error("Failed to connect to Ivy Live: \(error.localizedDescription)")
            return
        }
        guard currentSessionToken == token else {
            await session.disconnect()
            return
        }

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
                self.handleFailure(error, token: token)
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
                state = .listening
            }

            captureTask = Task { [weak self, session] in
                do {
                    for try await chunk in audioStream {
                        guard !Task.isCancelled else { break }
                        guard let self, self.currentSessionToken == token else { break }

                        if self.state == .speaking {
                            // Monitoring mode: do NOT stream mic audio to Gemini Live to prevent server VAD barge-in.
                            // Only check for the explicit "Hey Ivy" wake phrase.
                            let detected = await self.wakeWordDetector.processAudioChunk(chunk)
                            guard self.currentSessionToken == token else { break }
                            if detected {
                                await self.handleWakePhraseDetected(token: token)
                            }
                        } else if self.state == .toolConfirmation {
                            // In tool confirmation: do NOT stream mic audio to Gemini Live!
                            // Saying "yes" / "sure" through the mic must never approve a confirmation.
                            // Only check for explicit "Hey Ivy" wake phrase for cancellation.
                            let detected = await self.wakeWordDetector.processAudioChunk(chunk)
                            guard self.currentSessionToken == token else { break }
                            if detected {
                                await self.handleWakePhraseDetected(token: token)
                            }
                        } else if self.state == .toolExecution {
                            // Tool actively executing: do NOT stream mic audio to Gemini Live.
                        } else if self.state == .listening {
                            // Active user-turn capture: stream audio chunk to Gemini Live.
                            try await session.sendAudio(chunk)
                        }
                    }
                } catch {
                    guard let self, self.currentSessionToken == token else { return }
                    self.handleFailure(error, token: token)
                }
            }
        } catch {
            await session.disconnect()
            guard currentSessionToken == token else { return }
            state = .error("Failed to start audio capture: \(error.localizedDescription)")
        }
    }

    /// Cleanly terminates the live voice session.
    public func stopSession() async {
        currentSessionToken = nil
        captureTask?.cancel()
        eventTask?.cancel()
        drainTask?.cancel()
        toolExecutionTask?.cancel()
        captureTask = nil
        eventTask = nil
        drainTask = nil
        toolExecutionTask = nil

        if let cont = confirmationContinuation {
            confirmationContinuation = nil
            pendingConfirmation = nil
            cont.resume(returning: false)
        }
        pendingConfirmation = nil
        executingToolName = nil
        executedToolCallIds.removeAll()

        await audioCapture.stopCapture()
        await audioPlayer.stop()
        await wakeWordDetector.reset()
        await session.disconnect()

        state = .idle
        latestTranscript = ""
        wasSessionStartedByPushToTalk = false
    }

    /// Handles explicit wake phrase ("Hey Ivy") detection while Ivy is speaking or waiting for confirmation.
    public func handleWakePhraseDetected(token: UUID? = nil) async {
        if let token, currentSessionToken != token { return }
        guard state == .speaking || state == .toolConfirmation else { return }

        if let cont = confirmationContinuation {
            confirmationContinuation = nil
            pendingConfirmation = nil
            cont.resume(returning: false)
        }

        state = .interrupting
        #if DEBUG
        print("[WAKE] interruption requested")
        #endif
        drainTask?.cancel()
        drainTask = nil
        toolExecutionTask?.cancel()
        toolExecutionTask = nil
        executingToolName = nil

        await audioPlayer.stop()
        #if DEBUG
        print("[WAKE] playback stopped")
        print("[WAKE] audio queue cleared")
        #endif
        await wakeWordDetector.reset()
        state = .listening
        #if DEBUG
        print("[WAKE] state=listening")
        #endif
    }

    /// Evaluates transcription text directly for "Hey Ivy" interruption.
    public func processTranscriptionForInterruption(_ text: String, token: UUID? = nil) async {
        if let token, currentSessionToken != token { return }
        guard state == .speaking || state == .toolConfirmation else { return }
        #if DEBUG
        let preview = text.count > 30 ? String(text.prefix(30)) : text
        print("[WAKE] recognition partial: \(preview)")
        #endif
        let isMatch = WakePhraseMatcher.containsWakePhrase(text)
        if isMatch {
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
            if state == .connecting {
                state = .listening
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

            state = .thinking
            executingToolName = call.name

            toolExecutionTask?.cancel()
            toolExecutionTask = Task { [weak self, session] in
                guard let self, self.currentSessionToken == token else { return }

                // Check if tool is classified as safe; if safe, transition directly to .toolExecution
                if let tool = self.toolDispatcher.registry.tool(named: call.name) {
                    let classification = self.toolDispatcher.safetyGate.policy?.classification(for: tool, call: call) ?? tool.safetyClassification
                    if classification == .safe {
                        self.state = .toolExecution
                    }
                }

                let response = await self.toolDispatcher.dispatch(call)

                guard self.currentSessionToken == token else {
                    #if DEBUG
                    print("[TOOL] Session token changed while dispatching tool; discarding result")
                    #endif
                    return
                }

                self.executingToolName = nil
                if self.state == .toolExecution {
                    self.state = .thinking
                }

                do {
                    try await session.sendToolResponse(response)
                } catch {
                    guard self.currentSessionToken == token else { return }
                    self.handleFailure(error, token: token)
                }
            }

        case .audioChunk(let data):
            drainTask?.cancel()
            drainTask = nil
            if state != .speaking {
                state = .speaking
                #if DEBUG
                print("[WAKE] speaking capture active")
                #endif
            }
            do {
                try await audioPlayer.playChunk(data)
            } catch {
                handleFailure(error, token: token)
            }

        case .textTurn(let text):
            latestTranscript = text

        case .turnComplete:
            if state == .speaking {
                // Model finished generation! Wait for playback queue to drain before returning to listening
                drainTask?.cancel()
                drainTask = Task { [weak self] in
                    guard let self, self.currentSessionToken == token else { return }
                    await self.audioPlayer.waitUntilFinished()
                    guard !Task.isCancelled, self.currentSessionToken == token else { return }
                    if self.state == .speaking {
                        await self.wakeWordDetector.reset()
                        if self.wasSessionStartedByPushToTalk && !self.isPushToTalkActive {
                            await self.stopSession()
                        } else {
                            self.state = .listening
                        }
                    }
                }
            }

        case .interrupted:
            drainTask?.cancel()
            drainTask = nil
            toolExecutionTask?.cancel()
            toolExecutionTask = nil
            executingToolName = nil
            await audioPlayer.stop()
            await wakeWordDetector.reset()
            state = .listening

        case .disconnected:
            drainTask?.cancel()
            drainTask = nil
            toolExecutionTask?.cancel()
            toolExecutionTask = nil
            executingToolName = nil
            if state.isLive {
                state = .idle
            }
        }
    }

    private func handleFailure(_ error: Error, token: UUID) {
        guard currentSessionToken == token else { return }
        drainTask?.cancel()
        drainTask = nil
        toolExecutionTask?.cancel()
        toolExecutionTask = nil
        executingToolName = nil
        state = .error(error.localizedDescription)
        Task { [weak self] in
            guard let self, self.currentSessionToken == token else { return }
            await self.audioCapture.stopCapture()
            await self.audioPlayer.stop()
            await self.wakeWordDetector.reset()
            await self.session.disconnect()
        }
    }
}

extension GeminiLiveVoiceCoordinator: ConfirmationHandler {
    public func handleConfirmation(_ request: ConfirmationRequest) async -> Bool {
        self.pendingConfirmation = request
        self.state = .toolConfirmation
        let approved = await withCheckedContinuation { continuation in
            self.confirmationContinuation = continuation
        }
        self.pendingConfirmation = nil
        if approved {
            self.state = .toolExecution
        } else {
            self.state = .thinking
        }
        return approved
    }
}
