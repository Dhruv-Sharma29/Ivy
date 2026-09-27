import Foundation
import Combine

/// Lifecycle states for an active Gemini Live voice session.
public enum VoiceSessionState: Equatable, Sendable {
    case idle
    case connecting
    case listening
    case thinking
    case speaking
    case error(String)

    public var isLive: Bool {
        switch self {
        case .connecting, .listening, .thinking, .speaking:
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

    private var captureTask: Task<Void, Never>? = nil
    private var eventTask: Task<Void, Never>? = nil

    public init(
        session: GeminiLiveSession,
        audioCapture: AudioCaptureProtocol,
        audioPlayer: LiveAudioPlayerProtocol
    ) {
        self.session = session
        self.audioCapture = audioCapture
        self.audioPlayer = audioPlayer
    }

    /// Convenience initializer using production implementations.
    public convenience init(
        apiKey: String,
        model: String = "models/gemini-3.1-flash-live-preview",
        systemInstruction: String = IvyPersona.systemPrompt
    ) {
        let client = GeminiLiveClient(apiKey: apiKey, model: model, systemInstruction: systemInstruction)
        let capture = SystemAudioCapture()
        let player = SystemLiveAudioPlayer()
        self.init(session: client, audioCapture: capture, audioPlayer: player)
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

        // Connect to Gemini Live
        do {
            try await session.connect()
        } catch {
            state = .error("Failed to connect to Gemini Live: \(error.localizedDescription)")
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
                        await self?.handleUserSpeaking()
                        try await session.sendAudio(chunk)
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
        captureTask = nil
        eventTask = nil

        await audioCapture.stopCapture()
        await audioPlayer.stop()
        await session.disconnect()

        state = .idle
        latestTranscript = ""
    }

    /// Called when the user speaks while Ivy might be speaking or audio is playing.
    /// Immediately interrupts audio playback and resumes listening.
    private func handleUserSpeaking() async {
        if state == .speaking {
            await audioPlayer.stop()
            state = .listening
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
                state = .listening
            }

        case .interrupted:
            await audioPlayer.stop()
            state = .listening

        case .disconnected:
            if state.isLive {
                state = .idle
            }
        }
    }

    private func handleFailure(_ error: Error) {
        state = .error(error.localizedDescription)
        Task { [weak self] in
            await self?.audioCapture.stopCapture()
            await self?.audioPlayer.stop()
            await self?.session.disconnect()
        }
    }
}
