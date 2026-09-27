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

    private var captureTask: Task<Void, Never>? = nil
    private var eventTask: Task<Void, Never>? = nil
    private var drainTask: Task<Void, Never>? = nil

    public init(
        session: GeminiLiveSession,
        audioCapture: AudioCaptureProtocol,
        audioPlayer: LiveAudioPlayerProtocol,
        wakeWordDetector: WakeWordDetectorProtocol = SystemWakeWordDetector()
    ) {
        self.session = session
        self.audioCapture = audioCapture
        self.audioPlayer = audioPlayer
        self.wakeWordDetector = wakeWordDetector

        wakeWordDetector.setTranscriptionHandler { [weak self] transcript in
            Task { @MainActor [weak self] in
                await self?.processTranscriptionForInterruption(transcript)
            }
        }
    }

    /// Convenience initializer using production implementations.
    public convenience init(
        apiKey: String,
        model: String = "models/gemini-3.1-flash-live-preview",
        voiceName: String = "Kore",
        systemInstruction: String = IvyPersona.systemPrompt
    ) {
        let client = GeminiLiveClient(apiKey: apiKey, model: model, voiceName: voiceName, systemInstruction: systemInstruction)
        let capture = SystemAudioCapture()
        let player = SystemLiveAudioPlayer()
        let detector = SystemWakeWordDetector()
        self.init(session: client, audioCapture: capture, audioPlayer: player, wakeWordDetector: detector)
    }

    /// Updates the API key for the underlying session client if supported.
    public func updateApiKey(_ newKey: String) {
        if let client = session as? GeminiLiveClient {
            client.updateApiKey(newKey)
        }
    }

    deinit {
        captureTask?.cancel()
        eventTask?.cancel()
        drainTask?.cancel()
    }

    /// Starts a live voice conversation session.
    public func startSession() async {
        if state.isLive {
            await stopSession()
        }

        state = .connecting
        latestTranscript = ""

        // Check microphone permission
        let hasMicPermission = await audioCapture.requestPermission()
        guard hasMicPermission else {
            state = .error(LiveError.microphonePermissionDenied.localizedDescription)
            return
        }

        // Request speech recognition permission for wake phrase interruption
        _ = await wakeWordDetector.requestPermission()

        // Connect to Gemini Live
        do {
            try await session.connect()
        } catch {
            state = .error("Failed to connect to Ivy Live: \(error.localizedDescription)")
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
            state = .listening

            captureTask = Task { [weak self, session] in
                do {
                    for try await chunk in audioStream {
                        guard !Task.isCancelled else { break }
                        guard let self else { break }

                        if self.state == .speaking {
                            #if DEBUG
                            print("[WAKE] state=speaking")
                            print("[WAKE] microphone buffer received")
                            #endif
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
            state = .error("Failed to start audio capture: \(error.localizedDescription)")
        }
    }

    /// Cleanly terminates the live voice session.
    public func stopSession() async {
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
    }

    /// Handles explicit wake phrase ("Hey Ivy") detection while Ivy is speaking.
    public func handleWakePhraseDetected() async {
        guard state == .speaking || state == .interrupting else { return }
        #if DEBUG
        print("[WAKE] HEY IVY DETECTED")
        print("[WAKE] interrupting playback")
        #endif
        state = .interrupting
        drainTask?.cancel()
        drainTask = nil

        await audioPlayer.stop()
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
        print("[WAKE] matcher input: \"\(text)\"")
        #endif
        let isMatch = WakePhraseMatcher.containsWakePhrase(text)
        #if DEBUG
        print("[WAKE] matcher result: \(isMatch)")
        #endif
        if isMatch {
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
            state = .speaking
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
                    if self.state == .speaking {
                        await self.wakeWordDetector.reset()
                        self.state = .listening
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
