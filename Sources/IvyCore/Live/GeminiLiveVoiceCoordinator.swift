import Foundation
import Combine

/// Lifecycle states for an active Gemini Live voice session.
public enum VoiceSessionState: Equatable, Sendable {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
    case interrupting
    case error(String)

    public var isLive: Bool {
        switch self {
        case .connecting, .listening, .thinking, .speaking, .interrupting:
            return true
        case .idle, .error:
            return false
        }
    }
}

/// Coordinates microphone audio capture, Gemini Live session streaming, and native audio playback.
@MainActor
public final class GeminiLiveVoiceCoordinator: ObservableObject {
    @Published public private(set) var state: VoiceSessionState = .idle
    @Published public private(set) var latestTranscript: String = ""

    public let session: GeminiLiveSession
    public let audioCapture: AudioCaptureProtocol
    public let audioPlayer: LiveAudioPlayerProtocol
    public let wakeWordDetector: WakeWordDetectorProtocol
    public let hotkeyManager: GlobalHotkeyManaging?

    public private(set) var isPushToTalkActive: Bool = false
    public private(set) var wasSessionStartedByPushToTalk: Bool = false
    private var currentSessionToken: UUID? = nil

    private var captureTask: Task<Void, Never>? = nil
    private var eventTask: Task<Void, Never>? = nil
    private var drainTask: Task<Void, Never>? = nil

    public init(
        session: GeminiLiveSession,
        audioCapture: AudioCaptureProtocol,
        audioPlayer: LiveAudioPlayerProtocol,
        wakeWordDetector: WakeWordDetectorProtocol = SystemWakeWordDetector(),
        hotkeyManager: GlobalHotkeyManaging? = nil
    ) {
        self.session = session
        self.audioCapture = audioCapture
        self.audioPlayer = audioPlayer
        self.wakeWordDetector = wakeWordDetector
        self.hotkeyManager = hotkeyManager

        wakeWordDetector.setTranscriptionHandler { [weak self] transcript in
            Task { @MainActor [weak self] in
                await self?.processTranscriptionForInterruption(transcript)
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
        hotkeyManager: GlobalHotkeyManaging? = nil
    ) {
        let client = GeminiLiveClient(apiKey: apiKey, model: model, voiceName: Self.liveVoiceName, systemInstruction: systemInstruction)
        let capture = SystemAudioCapture()
        let player = SystemLiveAudioPlayer()
        let detector = SystemWakeWordDetector()
        self.init(
            session: client,
            audioCapture: capture,
            audioPlayer: player,
            wakeWordDetector: detector,
            hotkeyManager: hotkeyManager
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
        case .connecting, .thinking, .speaking, .interrupting:
            // Active session or transition in progress; do not start duplicate or interrupt speaking
            break
        }
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
                    await self?.handleLiveEvent(event)
                }
            } catch {
                self?.handleFailure(error)
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
            state = .listening

            captureTask = Task { [weak self, session] in
                do {
                    for try await chunk in audioStream {
                        guard !Task.isCancelled else { break }
                        guard let self else { break }

                        if self.state == .speaking {
                            // Monitoring mode: do NOT stream mic audio to Gemini Live to prevent server VAD barge-in.
                            // Only check for the explicit "Hey Ivy" wake phrase.
                            let detected = await self.wakeWordDetector.processAudioChunk(chunk)
                            if detected {
                                await self.handleWakePhraseDetected()
                            }
                        } else if self.state == .listening {
                            // Active user-turn capture: stream audio chunk to Gemini Live.
                            try await session.sendAudio(chunk)
                        }
                    }
                } catch {
                    self?.handleFailure(error)
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
        captureTask = nil
        eventTask = nil
        drainTask = nil

        await audioCapture.stopCapture()
        await audioPlayer.stop()
        await wakeWordDetector.reset()
        await session.disconnect()

        state = .idle
        latestTranscript = ""
        wasSessionStartedByPushToTalk = false
    }

    /// Handles explicit wake phrase ("Hey Ivy") detection while Ivy is speaking.
    public func handleWakePhraseDetected() async {
        guard state == .speaking else { return }
        state = .interrupting
        #if DEBUG
        print("[WAKE] interruption requested")
        #endif
        drainTask?.cancel()
        drainTask = nil

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
    public func processTranscriptionForInterruption(_ text: String) async {
        guard state == .speaking else { return }
        #if DEBUG
        let preview = text.count > 30 ? String(text.prefix(30)) : text
        print("[WAKE] recognition partial: \(preview)")
        #endif
        let isMatch = WakePhraseMatcher.containsWakePhrase(text)
        if isMatch {
            #if DEBUG
            print("[WAKE] wake phrase matched")
            #endif
            await handleWakePhraseDetected()
        }
    }

    /// Handles events emitted by the Gemini Live session.
    private func handleLiveEvent(_ event: LiveEvent) async {
        switch event {
        case .connected:
            if state == .connecting {
                state = .listening
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
                handleFailure(error)
            }

        case .textTurn(let text):
            latestTranscript = text

        case .turnComplete:
            if state == .speaking {
                // Model finished generation! Wait for playback queue to drain before returning to listening
                drainTask?.cancel()
                drainTask = Task { [weak self] in
                    guard let self else { return }
                    await self.audioPlayer.waitUntilFinished()
                    guard !Task.isCancelled else { return }
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
            await audioPlayer.stop()
            await wakeWordDetector.reset()
            state = .listening

        case .disconnected:
            drainTask?.cancel()
            drainTask = nil
            if state.isLive {
                state = .idle
            }
        }
    }

    private func handleFailure(_ error: Error) {
        drainTask?.cancel()
        drainTask = nil
        state = .error(error.localizedDescription)
        Task { [weak self] in
            await self?.audioCapture.stopCapture()
            await self?.audioPlayer.stop()
            await self?.wakeWordDetector.reset()
            await self?.session.disconnect()
        }
    }
}
