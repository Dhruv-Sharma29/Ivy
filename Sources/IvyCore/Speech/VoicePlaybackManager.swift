import Foundation
import Combine

/// Lifecycle state for speech synthesis and playback.
public enum VoicePlaybackState: Equatable, Sendable {
    case idle
    case synthesizing(messageId: UUID)
    case playing(messageId: UUID)
    case error(String)

    public var isBusy: Bool {
        switch self {
        case .synthesizing, .playing:
            return true
        case .idle, .error:
            return false
        }
    }
}

/// Coordinates text-to-speech synthesis and native audio playback for chat responses.
/// Maintains actor isolation on `@MainActor` to prevent data races and race conditions.
@MainActor
public final class VoicePlaybackManager: ObservableObject {
    @Published public private(set) var state: VoicePlaybackState = .idle
    @Published public private(set) var currentMessageId: UUID? = nil
    @Published public private(set) var errorMessage: String? = nil

    public let synthesizer: SpeechSynthesizer
    public let player: AudioPlayerProtocol

    private var activeTask: Task<Void, Never>? = nil
    private var generationToken: UUID = UUID()

    public init(
        synthesizer: SpeechSynthesizer? = nil,
        player: AudioPlayerProtocol? = nil,
        apiKey: String? = nil,
        credentials: CredentialProvider? = nil,
        voiceSettings: @escaping @Sendable () -> ElevenLabsVoiceSettings = { ElevenLabsVoiceSettings() }
    ) {
        if let synthesizer {
            self.synthesizer = synthesizer
            if let apiKey,
               let configProvider = (synthesizer as? ElevenLabsSpeechSynthesizer)?.keyProvider as? ConfigurableElevenLabsKeyProvider {
                configProvider.setAPIKey(apiKey)
            }
        } else {
            // The key is resolved per request (Keychain, then environment); it is never kept as observable state.
            let keyProvider: ElevenLabsKeyProvider = apiKey.map { StaticElevenLabsKeyProvider(key: $0) }
                ?? CredentialElevenLabsKeyProvider(credentials: credentials ?? KeychainCredentialProvider())
            self.synthesizer = ElevenLabsSpeechSynthesizer(keyProvider: keyProvider, voiceSettings: voiceSettings)
        }
        self.player = player ?? SystemAudioPlayer()
    }

    /// Indicates whether a specific message is currently synthesizing or actively playing.
    public func isPlaying(messageId: UUID) -> Bool {
        switch state {
        case .synthesizing(let id), .playing(let id):
            return id == messageId
        case .idle, .error:
            return false
        }
    }

    /// Indicates whether a specific message is currently waiting for TTS synthesis.
    public func isSynthesizing(messageId: UUID) -> Bool {
        if case .synthesizing(let id) = state {
            return id == messageId
        }
        return false
    }

    /// Toggles playback for a specific chat message:
    /// - If the message is already synthesizing or playing, it stops playback.
    /// - If another message (or nothing) is playing, it stops the prior playback and starts synthesizing this message.
    public func togglePlayback(for message: ChatMessage) {
        if isPlaying(messageId: message.id) {
            stop()
        } else {
            speak(message: message)
        }
    }

    /// Initiates speech synthesis and audio playback for the provided message.
    public func speak(message: ChatMessage) {
        // Stop any currently running task or playback
        stop()

        let trimmedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            self.state = .error("Cannot read empty message.")
            self.errorMessage = "Cannot read empty message."
            return
        }

        errorMessage = nil
        let token = UUID()
        self.generationToken = token
        self.currentMessageId = message.id
        self.state = .synthesizing(messageId: message.id)

        self.activeTask = Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let audioData = try await self.synthesizer.synthesize(text: trimmedText)

                // Guard against stale completion if cancelled or another request started
                guard self.generationToken == token, !Task.isCancelled else { return }

                self.state = .playing(messageId: message.id)

                try await self.player.play(data: audioData)

                // Completed successfully
                guard self.generationToken == token else { return }
                self.state = .idle
                self.currentMessageId = nil
            } catch is CancellationError {
                guard self.generationToken == token else { return }
                self.state = .idle
                self.currentMessageId = nil
            } catch let speechErr as SpeechError where speechErr == .cancelled {
                guard self.generationToken == token else { return }
                self.state = .idle
                self.currentMessageId = nil
            } catch {
                guard self.generationToken == token else { return }
                let errorDesc = error.localizedDescription
                self.state = .error(errorDesc)
                self.errorMessage = errorDesc
                self.currentMessageId = nil
            }
        }
    }

    /// Clears any active error state and error message.
    public func clearError() {
        if case .error = state {
            state = .idle
        }
        errorMessage = nil
    }

    /// Stops any active speech synthesis request and audio playback immediately.
    public func stop() {
        // Invalidate generation token to ignore any in-flight synthesis responses
        generationToken = UUID()

        if let task = activeTask {
            task.cancel()
            activeTask = nil
        }

        player.stop()

        state = .idle
        currentMessageId = nil
    }
}
