import Foundation
import AVFoundation
import os

/// Protocol for capturing microphone audio and streaming 16kHz 16-bit mono PCM chunks.
public protocol AudioCaptureProtocol: Sendable {
    /// Requests microphone access permissions from macOS.
    func requestPermission() async -> Bool

    /// Starts microphone capture, yielding chunks of 16kHz 16-bit mono PCM audio.
    func startCapture() async throws -> AsyncThrowingStream<Data, Error>

    /// Stops microphone capture and releases audio hardware resources.
    func stopCapture() async
}

/// A mock implementation of `AudioCaptureProtocol` for testing without audio hardware.
public final class MockAudioCapture: AudioCaptureProtocol, @unchecked Sendable {
    private struct State {
        var isPermissionGranted: Bool = true
        var isCapturing: Bool = false
        var continuation: AsyncThrowingStream<Data, Error>.Continuation? = nil
        var capturedChunksCount: Int = 0
        var startCaptureCallCount: Int = 0
        var stopCaptureCallCount: Int = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(isPermissionGranted: Bool = true) {
        state.withLock {
            $0.isPermissionGranted = isPermissionGranted
        }
    }

    public var isCapturing: Bool {
        state.withLock { $0.isCapturing }
    }

    public var isPermissionGranted: Bool {
        state.withLock { $0.isPermissionGranted }
    }

    public var capturedChunksCount: Int {
        state.withLock { $0.capturedChunksCount }
    }

    public var startCaptureCallCount: Int {
        state.withLock { $0.startCaptureCallCount }
    }

    public var stopCaptureCallCount: Int {
        state.withLock { $0.stopCaptureCallCount }
    }

    public func setPermissionGranted(_ granted: Bool) {
        state.withLock { $0.isPermissionGranted = granted }
    }

    public func requestPermission() async -> Bool {
        state.withLock { $0.isPermissionGranted }
    }

    public func startCapture() async throws -> AsyncThrowingStream<Data, Error> {
        let granted = state.withLock { $0.isPermissionGranted }
        guard granted else {
            throw LiveError.microphonePermissionDenied
        }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()

        state.withLock { s in
            s.startCaptureCallCount += 1
            s.isCapturing = true
            s.continuation = continuation
        }

        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { s in
                s.isCapturing = false
                s.continuation = nil
            }
        }

        return stream
    }

    public func simulateAudioChunk(_ data: Data) {
        let continuation = state.withLock { s -> AsyncThrowingStream<Data, Error>.Continuation? in
            guard s.isCapturing else { return nil }
            s.capturedChunksCount += 1
            return s.continuation
        }
        continuation?.yield(data)
    }

    public func simulateError(_ error: Error) {
        let continuation = state.withLock { s -> AsyncThrowingStream<Data, Error>.Continuation? in
            s.isCapturing = false
            let cont = s.continuation
            s.continuation = nil
            return cont
        }
        continuation?.finish(throwing: error)
    }

    public func stopCapture() async {
        let continuation = state.withLock { s -> AsyncThrowingStream<Data, Error>.Continuation? in
            s.stopCaptureCallCount += 1
            s.isCapturing = false
            let cont = s.continuation
            s.continuation = nil
            return cont
        }
        continuation?.finish()
    }
}

/// Native macOS audio capture implementation using `AVAudioEngine` converting to 16kHz 16-bit mono PCM.
public final class SystemAudioCapture: AudioCaptureProtocol, @unchecked Sendable {
    private struct State {
        var isCapturing: Bool = false
        /// Identifies the live capture so a stale stream's termination can't tear down a newer one.
        var captureId: UUID? = nil
        var continuation: AsyncThrowingStream<Data, Error>.Continuation? = nil
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let audioEngine: AVAudioEngine
    private let voiceProcessing: Bool
    /// Muted sink that pulls the voice-processed input through the graph; without it the input tap never fires.
    private let voiceSink = AVAudioMixerNode()
    /// Set once in init, removed in deinit; never mutated concurrently.
    private var configObserver: NSObjectProtocol?

    /// With `voiceProcessing`, Apple's echo cancellation removes audio this engine plays from the mic signal,
    /// so Ivy's own voice doesn't drown out the user (needed for "Hey Ivy" over speakers). Share the engine
    /// with the player for it to work.
    public init(audioEngine: AVAudioEngine = AVAudioEngine(), voiceProcessing: Bool = false) {
        self.audioEngine = audioEngine
        self.voiceProcessing = voiceProcessing
        // Enabling voice processing (or a device change) reconfigures the engine and stops it right after
        // start; without a restart the mic tap goes silent for the rest of the session.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: nil
        ) { [weak self] _ in
            guard let self, self.state.withLock({ $0.isCapturing }), !self.audioEngine.isRunning else { return }
            do {
                try self.audioEngine.start()
                print("[AUDIO] engine restarted after configuration change")
            } catch {
                print("[AUDIO] capture error: restart after configuration change failed: \(error.localizedDescription)")
            }
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    public func requestPermission() async -> Bool {
        #if os(macOS)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
        #else
        return true
        #endif
    }

    public func startCapture() async throws -> AsyncThrowingStream<Data, Error> {
        let granted = await requestPermission()
        guard granted else {
            throw LiveError.microphonePermissionDenied
        }

        // Installing a second tap on bus 0 raises an AVFoundation exception; restart cleanly instead.
        await stopCapture()

        let inputNode = audioEngine.inputNode
        if voiceProcessing && !inputNode.isVoiceProcessingEnabled {
            // Voice processing can only be reconfigured while the engine is stopped (the player may have started it).
            if audioEngine.isRunning { audioEngine.stop() }
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                // Don't duck the user's other apps while Ivy listens.
                inputNode.voiceProcessingOtherAudioDuckingConfiguration = .init(enableAdvancedDucking: false, duckingLevel: .min)
            } catch {
                print("[AUDIO] echo cancellation unavailable, capturing without it: \(error.localizedDescription)")
            }
        }
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard hardwareFormat.sampleRate > 0, hardwareFormat.channelCount > 0 else {
            let err = "No audio input hardware detected."
            print("[AUDIO] capture error: \(err)")
            throw LiveError.connectionFailed(err)
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            let err = "Failed to create 16kHz PCM audio format."
            print("[AUDIO] capture error: \(err)")
            throw LiveError.connectionFailed(err)
        }

        guard let converter = AVAudioConverter(from: hardwareFormat, to: targetFormat) else {
            let err = "Failed to create audio format converter from \(hardwareFormat) to \(targetFormat)."
            print("[AUDIO] capture error: \(err)")
            throw LiveError.connectionFailed(err)
        }
        // Voice-processed input is multichannel (e.g. 5 ch); only channel 0 carries the echo-cancelled voice.
        if hardwareFormat.channelCount > 1 {
            converter.channelMap = [0]
        }
        if inputNode.isVoiceProcessingEnabled {
            if voiceSink.engine == nil {
                audioEngine.attach(voiceSink)
            }
            audioEngine.disconnectNodeOutput(inputNode)
            audioEngine.connect(inputNode, to: voiceSink, format: hardwareFormat)
            audioEngine.connect(voiceSink, to: audioEngine.mainMixerNode, format: nil)
            voiceSink.outputVolume = 0
        }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let captureId = UUID()

        state.withLock { s in
            s.isCapturing = true
            s.captureId = captureId
            s.continuation = continuation
        }

        var bufferCount = 0
        inputNode.installTap(onBus: 0, bufferSize: 2048, format: hardwareFormat) { [weak self] buffer, _ in
            guard let self else { return }

            let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / buffer.format.sampleRate)
            guard frameCapacity > 0,
                  let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                return
            }

            var error: NSError? = nil
            var inputConsumed = false
            let status = converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if status != .error, let channelData = convertedBuffer.int16ChannelData {
                let byteCount = Int(convertedBuffer.frameLength) * 2 // 16-bit mono = 2 bytes per frame
                let chunk = Data(bytes: channelData[0], count: byteCount)
                bufferCount += 1
                if bufferCount == 1 || bufferCount % 50 == 0 {
                    print("[AUDIO] input buffer received bytes=\(byteCount)")
                }
                let cont = self.state.withLock { $0.continuation }
                cont?.yield(chunk)
            } else if let error {
                print("[AUDIO] capture error: \(error.localizedDescription)")
            }
        }

        do {
            try audioEngine.start()
            print("[AUDIO] capture started")
        } catch {
            inputNode.removeTap(onBus: 0)
            state.withLock { s in
                s.isCapturing = false
                s.captureId = nil
                s.continuation = nil
            }
            print("[AUDIO] capture error: \(error.localizedDescription)")
            throw LiveError.connectionFailed("Failed to start audio engine: \(error.localizedDescription)")
        }

        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.stopCapture(only: captureId)
            }
        }

        return stream
    }

    public func stopCapture() async {
        await stopCapture(only: nil)
    }

    /// Stops capture; with an id, only if that capture is still the live one.
    private func stopCapture(only captureId: UUID?) async {
        let (wasCapturing, continuation) = state.withLock { s -> (Bool, AsyncThrowingStream<Data, Error>.Continuation?) in
            if let captureId, s.captureId != captureId { return (false, nil) }
            let was = s.isCapturing
            s.isCapturing = false
            s.captureId = nil
            let cont = s.continuation
            s.continuation = nil
            return (was, cont)
        }

        if wasCapturing {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        continuation?.finish()
    }
}
