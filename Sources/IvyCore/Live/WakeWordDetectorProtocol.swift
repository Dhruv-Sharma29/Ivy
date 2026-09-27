import Foundation
@preconcurrency import Speech
import AVFoundation
import os

/// Protocol for detecting the "Hey Ivy" wake phrase during model speech to trigger explicit interruption.
public protocol WakeWordDetectorProtocol: Sendable {
    /// Ingests a raw 16kHz mono 16-bit PCM audio chunk and returns true if "Hey Ivy" was detected.
    func processAudioChunk(_ data: Data) async -> Bool

    /// Directly tests a transcribed text string for the wake phrase.
    func processText(_ text: String) async -> Bool

    /// Resets any ongoing detection state or speech buffers.
    func reset() async
}

/// A thread-safe mock implementation of `WakeWordDetectorProtocol` for deterministic offline testing.
public final class MockWakeWordDetector: WakeWordDetectorProtocol, @unchecked Sendable {
    private struct State {
        var shouldTrigger: Bool = false
        var processedChunksCount: Int = 0
        var processedTexts: [String] = []
        var isReset: Bool = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(shouldTrigger: Bool = false) {
        state.withLock {
            $0.shouldTrigger = shouldTrigger
        }
    }

    public func setShouldTrigger(_ value: Bool) {
        state.withLock { $0.shouldTrigger = value }
    }

    public var processedChunksCount: Int {
        state.withLock { $0.processedChunksCount }
    }

    public var processedTexts: [String] {
        state.withLock { $0.processedTexts }
    }

    public var isReset: Bool {
        state.withLock { $0.isReset }
    }

    public func processAudioChunk(_ data: Data) async -> Bool {
        state.withLock { s in
            s.processedChunksCount += 1
            s.isReset = false
            return s.shouldTrigger
        }
    }

    public func processText(_ text: String) async -> Bool {
        state.withLock { s in
            s.processedTexts.append(text)
            if s.shouldTrigger { return true }
            return WakePhraseMatcher.containsWakePhrase(text)
        }
    }

    public func reset() async {
        state.withLock { s in
            s.isReset = true
            s.shouldTrigger = false
        }
    }
}

/// Native macOS wake-word detector using Apple's on-device `SFSpeechRecognizer` and `WakePhraseMatcher`.
public final class SystemWakeWordDetector: WakeWordDetectorProtocol, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var recognitionRequest: SFSpeechAudioBufferRecognitionRequest? = nil
        var recognitionTask: SFSpeechRecognitionTask? = nil
        var detected: Bool = false
        var isRunning: Bool = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let speechRecognizer: SFSpeechRecognizer?
    private let audioFormat: AVAudioFormat?

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.speechRecognizer = SFSpeechRecognizer(locale: locale)
        self.audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )
    }

    public func processAudioChunk(_ data: Data) async -> Bool {
        let isAlreadyDetected = state.withLock { $0.detected }
        if isAlreadyDetected { return true }

        ensureRecognitionTaskRunning()

        guard let audioFormat, data.count >= 2 else { return false }
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: frameCount) else {
            return false
        }

        pcmBuffer.frameLength = frameCount
        if let channelData = pcmBuffer.int16ChannelData {
            data.withUnsafeBytes { rawBytes in
                if let baseAddress = rawBytes.baseAddress {
                    memcpy(channelData[0], baseAddress, data.count)
                }
            }
        }

        state.withLock { s in
            s.recognitionRequest?.append(pcmBuffer)
        }

        return state.withLock { $0.detected }
    }

    public func processText(_ text: String) async -> Bool {
        let isMatch = WakePhraseMatcher.containsWakePhrase(text)
        if isMatch {
            state.withLock { $0.detected = true }
        }
        return isMatch
    }

    public func reset() async {
        state.withLock { s in
            s.recognitionRequest?.endAudio()
            s.recognitionTask?.cancel()
            s.recognitionTask = nil
            s.recognitionRequest = nil
            s.detected = false
            s.isRunning = false
        }
    }

    private func ensureRecognitionTaskRunning() {
        state.withLock { s in
            guard !s.isRunning, let recognizer = speechRecognizer, recognizer.isAvailable else { return }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            s.recognitionRequest = request
            s.isRunning = true
            s.detected = false

            s.recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let transcript = result.bestTranscription.formattedString
                    if WakePhraseMatcher.containsWakePhrase(transcript) {
                        self.state.withLock { $0.detected = true }
                    }
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.state.withLock {
                        $0.isRunning = false
                    }
                }
            }
        }
    }
}
