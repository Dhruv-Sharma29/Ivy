import Foundation
import AVFoundation

/// Protocol defining audio playback operations.
/// Abstracted so unit tests can verify playback coordination without touching macOS audio hardware.
@MainActor
public protocol AudioPlayerProtocol: AnyObject {
    /// Plays the provided audio binary data (e.g. MP3) and awaits completion.
    /// - Parameter data: Encoded audio data to play.
    /// - Throws: `SpeechError` if playback fails to start, is cancelled, or is interrupted.
    func play(data: Data) async throws

    /// Stops any active audio playback immediately and releases player resources.
    func stop()

    /// Indicates whether audio is currently actively playing.
    var isPlaying: Bool { get }
}

/// In-memory mock audio player for deterministic, headless unit tests.
@MainActor
public final class MockAudioPlayer: AudioPlayerProtocol {
    public var playedData: [Data] = []
    public private(set) var isPlaying: Bool = false
    public var shouldThrowError: (any Error)? = nil
    public var playbackDuration: TimeInterval = 0
    public var onPlayCalled: (() -> Void)? = nil
    public var onStopCalled: (() -> Void)? = nil

    private var currentContinuation: CheckedContinuation<Void, any Error>?

    public init() {}

    public func play(data: Data) async throws {
        stop()

        guard !data.isEmpty else {
            throw SpeechError.emptyAudioData
        }

        if let error = shouldThrowError {
            throw error
        }

        playedData.append(data)
        isPlaying = true
        onPlayCalled?()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.currentContinuation = continuation
                if self.playbackDuration > 0 {
                    let duration = self.playbackDuration
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                        self?.finishPlayback()
                    }
                } else {
                    self.finishPlayback()
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.stop()
            }
        }
    }

    public func finishPlayback() {
        guard isPlaying else { return }
        isPlaying = false
        let cont = currentContinuation
        currentContinuation = nil
        cont?.resume()
    }

    public func stop() {
        guard isPlaying || currentContinuation != nil else { return }
        isPlaying = false
        onStopCalled?()
        let cont = currentContinuation
        currentContinuation = nil
        cont?.resume(throwing: SpeechError.cancelled)
    }
}

/// Production implementation of `AudioPlayerProtocol` using `AVAudioPlayer`.
@MainActor
public final class SystemAudioPlayer: NSObject, AudioPlayerProtocol, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, any Error>?

    public var isPlaying: Bool {
        player?.isPlaying ?? false
    }

    public override init() {
        super.init()
    }

    public func play(data: Data) async throws {
        stop()

        guard !data.isEmpty else {
            throw SpeechError.emptyAudioData
        }

        let avPlayer: AVAudioPlayer
        do {
            avPlayer = try AVAudioPlayer(data: data)
        } catch {
            throw SpeechError.playbackFailed("Failed to initialize audio player: \(error.localizedDescription)")
        }

        self.player = avPlayer
        avPlayer.delegate = self
        avPlayer.prepareToPlay()

        guard avPlayer.play() else {
            self.player = nil
            throw SpeechError.playbackFailed("Failed to start audio playback.")
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.playbackContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor in
                self.stop()
            }
        }
    }

    public func stop() {
        if let player = self.player {
            if player.isPlaying {
                player.stop()
            }
            self.player = nil
        }
        if let continuation = self.playbackContinuation {
            self.playbackContinuation = nil
            continuation.resume(throwing: SpeechError.cancelled)
        }
    }

    // MARK: - AVAudioPlayerDelegate

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            if let continuation = self.playbackContinuation {
                self.playbackContinuation = nil
                if flag {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SpeechError.playbackFailed("Audio playback interrupted or failed."))
                }
            }
        }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor in
            self.player = nil
            if let continuation = self.playbackContinuation {
                self.playbackContinuation = nil
                let msg = error?.localizedDescription ?? "Audio decoding error"
                continuation.resume(throwing: SpeechError.playbackFailed(msg))
            }
        }
    }

}

