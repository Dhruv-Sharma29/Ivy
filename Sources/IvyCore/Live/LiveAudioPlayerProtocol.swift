import Foundation
import AVFoundation
import os

/// Protocol for playing incoming streaming 24kHz 16-bit mono PCM audio chunks from Gemini Live.
public protocol LiveAudioPlayerProtocol: Sendable {
    var isPlaying: Bool { get }
    func playChunk(_ data: Data) async throws
    func stop() async
}

/// A mock implementation of `LiveAudioPlayerProtocol` for testing without audio output hardware.
public final class MockLiveAudioPlayer: LiveAudioPlayerProtocol, @unchecked Sendable {
    private struct State {
        var playedChunks: [Data] = []
        var isPlaying: Bool = false
        var isStopped: Bool = false
        var playError: Error? = nil
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(playError: Error? = nil) {
        state.withLock {
            $0.playError = playError
        }
    }

    public var isPlaying: Bool {
        state.withLock { $0.isPlaying }
    }

    public var isStopped: Bool {
        state.withLock { $0.isStopped }
    }

    public var playedChunks: [Data] {
        state.withLock { $0.playedChunks }
    }

    public func setPlayError(_ error: Error?) {
        state.withLock { $0.playError = error }
    }

    public func playChunk(_ data: Data) async throws {
        let errorToThrow = state.withLock { s -> Error? in
            if let error = s.playError {
                return error
            }
            s.playedChunks.append(data)
            s.isPlaying = true
            s.isStopped = false
            return nil
        }

        if let errorToThrow {
            throw errorToThrow
        }
    }

    public func stop() async {
        state.withLock { s in
            s.isPlaying = false
            s.isStopped = true
        }
    }

    public func reset() {
        state.withLock { s in
            s.playedChunks.removeAll()
            s.isPlaying = false
            s.isStopped = false
        }
    }
}

/// Native macOS audio player for 24kHz 16-bit mono PCM chunks using `AVAudioEngine` and `AVAudioPlayerNode`.
public final class SystemLiveAudioPlayer: LiveAudioPlayerProtocol, @unchecked Sendable {
    private struct State {
        var isPlaying: Bool = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let audioEngine: AVAudioEngine
    private let playerNode: AVAudioPlayerNode
    private let audioFormat: AVAudioFormat?

    public init(
        audioEngine: AVAudioEngine = AVAudioEngine(),
        playerNode: AVAudioPlayerNode = AVAudioPlayerNode()
    ) {
        self.audioEngine = audioEngine
        self.playerNode = playerNode
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000,
            channels: 1,
            interleaved: false
        )

        audioEngine.attach(playerNode)
        if let audioFormat {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
        }
    }

    public var isPlaying: Bool {
        state.withLock { $0.isPlaying }
    }

    public func playChunk(_ data: Data) async throws {
        guard let audioFormat else {
            throw LiveError.serverError("Unsupported audio format for playback.")
        }

        // Each frame in 16-bit mono is 2 bytes
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0 else { return }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            throw LiveError.serverError("Failed to allocate audio buffer.")
        }

        pcmBuffer.frameLength = frameCount
        if let channelData = pcmBuffer.int16ChannelData {
            data.withUnsafeBytes { rawBytes in
                if let baseAddress = rawBytes.baseAddress {
                    memcpy(channelData[0], baseAddress, data.count)
                }
            }
        }

        if !audioEngine.isRunning {
            try audioEngine.start()
        }

        if !playerNode.isPlaying {
            playerNode.play()
        }

        state.withLock { $0.isPlaying = true }

        await playerNode.scheduleBuffer(pcmBuffer)
    }

    public func stop() async {
        playerNode.stop()
        audioEngine.stop()
        state.withLock { $0.isPlaying = false }
    }
}
