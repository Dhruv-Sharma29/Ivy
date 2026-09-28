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
        var continuation: AsyncThrowingStream<Data, Error>.Continuation? = nil
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let audioEngine: AVAudioEngine

    public init(audioEngine: AVAudioEngine = AVAudioEngine()) {
        self.audioEngine = audioEngine
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

        let inputNode = audioEngine.inputNode
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

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()

        state.withLock { s in
            s.isCapturing = true
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
            print("[AUDIO] capture error: \(error.localizedDescription)")
            throw LiveError.connectionFailed("Failed to start audio engine: \(error.localizedDescription)")
        }

        continuation.onTermination = { [weak self] _ in
            Task { [weak self] in
                await self?.stopCapture()
            }
        }

        return stream
    }

    public func stopCapture() async {
        let (wasCapturing, continuation) = state.withLock { s -> (Bool, AsyncThrowingStream<Data, Error>.Continuation?) in
            let was = s.isCapturing
            s.isCapturing = false
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
