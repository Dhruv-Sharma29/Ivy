import Foundation
import AVFoundation
import os

/// Protocol for playing incoming streaming 24kHz 16-bit mono PCM audio chunks from Gemini Live.
public protocol LiveAudioPlayerProtocol: Sendable {
    var isPlaying: Bool { get }
    func playChunk(_ data: Data) async throws
    /// Awaits until all scheduled audio buffers have finished playing through the output hardware.
    func waitUntilFinished() async
    /// Immediately halts playback and purges all queued buffers.
    func stop() async
}

/// A mock implementation of `LiveAudioPlayerProtocol` for testing without audio output hardware.
public final class MockLiveAudioPlayer: LiveAudioPlayerProtocol, @unchecked Sendable {
    private struct State {
        var playedChunks: [Data] = []
        var isPlaying: Bool = false
        var isStopped: Bool = false
        var autoDrain: Bool = true
        var playError: Error? = nil
        var waitContinuations: [CheckedContinuation<Void, Never>] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(playError: Error? = nil, autoDrain: Bool = true) {
        state.withLock {
            $0.playError = playError
            $0.autoDrain = autoDrain
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

    public func setAutoDrain(_ autoDrain: Bool) {
        state.withLock { $0.autoDrain = autoDrain }
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

    public func waitUntilFinished() async {
        let (shouldWait, isAuto) = state.withLock { s -> (Bool, Bool) in
            return (s.isPlaying, s.autoDrain)
        }
        guard shouldWait else { return }

        if isAuto {
            finishPlayback()
            return
        }

        await withCheckedContinuation { cont in
            state.withLock { s in
                if !s.isPlaying {
                    cont.resume()
                } else {
                    s.waitContinuations.append(cont)
                }
            }
        }
    }

    public func finishPlayback() {
        let continuations = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isPlaying = false
            let conts = s.waitContinuations
            s.waitContinuations = []
            return conts
        }
        for cont in continuations {
            cont.resume()
        }
    }

    public func stop() async {
        let continuations = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isPlaying = false
            s.isStopped = true
            let conts = s.waitContinuations
            s.waitContinuations = []
            return conts
        }
        for cont in continuations {
            cont.resume()
        }
    }

    public func reset() {
        let continuations = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.playedChunks.removeAll()
            s.isPlaying = false
            s.isStopped = false
            let conts = s.waitContinuations
            s.waitContinuations = []
            return conts
        }
        for cont in continuations {
            cont.resume()
        }
    }
}

/// Native macOS audio player for 24kHz 16-bit mono PCM chunks using `AVAudioEngine` and `AVAudioPlayerNode`.
public final class SystemLiveAudioPlayer: LiveAudioPlayerProtocol, @unchecked Sendable {
    private struct State {
        var isPlaying: Bool = false
        var activeBuffers: Int = 0
        var waitContinuations: [CheckedContinuation<Void, Never>] = []
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

        state.withLock { s in
            s.isPlaying = true
            s.activeBuffers += 1
        }

        playerNode.scheduleBuffer(pcmBuffer) { [weak self] in
            guard let self else { return }
            let continuations = self.state.withLock { s -> [CheckedContinuation<Void, Never>] in
                s.activeBuffers = max(0, s.activeBuffers - 1)
                if s.activeBuffers == 0 {
                    s.isPlaying = false
                    let pending = s.waitContinuations
                    s.waitContinuations = []
                    return pending
                }
                return []
            }
            for cont in continuations {
                cont.resume()
            }
        }
    }

    public func waitUntilFinished() async {
        let shouldWait = state.withLock { $0.activeBuffers > 0 }
        guard shouldWait else { return }

        await withCheckedContinuation { cont in
            state.withLock { s in
                if s.activeBuffers == 0 {
                    cont.resume()
                } else {
                    s.waitContinuations.append(cont)
                }
            }
        }
    }

    public func stop() async {
        let (wasPlaying, continuations) = state.withLock { s -> (Bool, [CheckedContinuation<Void, Never>]) in
            let was = s.isPlaying
            s.isPlaying = false
            s.activeBuffers = 0
            let pending = s.waitContinuations
            s.waitContinuations = []
            return (was, pending)
        }

        for cont in continuations {
            cont.resume()
        }

        if wasPlaying {
            playerNode.stop()
            audioEngine.stop()
        }
    }
}
