import Foundation
@preconcurrency import Speech
import AVFoundation
import os

/// Listens for "Hey Ivy" while Ivy is idle (like "Hey Siri"). Must release the microphone on `stop()`,
/// because Live takes it over as soon as the wake word fires.
public protocol WakeWordListening: AnyObject, Sendable {
    /// Starts listening; `onWake` fires once, after which the listener has already stopped itself.
    func start(onWake: @escaping @Sendable () -> Void) async throws
    func stop() async
    /// The last moments of microphone audio before the wake fired (16 kHz 16-bit mono), handed over once.
    /// Memory only. Empty if the listener keeps no pre-roll.
    func takePreRoll() -> Data
}

public extension WakeWordListening {
    func takePreRoll() -> Data { Data() }
}

public enum WakeWordListenerError: Error, LocalizedError, Equatable, Sendable {
    case requiresAppBundle
    case microphoneDenied
    case speechRecognitionDenied
    case onDeviceRecognitionUnavailable
    case audioEngineFailed(String)

    public var errorDescription: String? {
        switch self {
        case .requiresAppBundle:
            return "\"Hey Ivy\" wake-up needs Ivy.app (scripts/run-ivy-app.sh), not `swift run`."
        case .microphoneDenied:
            return "\"Hey Ivy\" wake-up needs microphone access. Allow Ivy in System Settings › Privacy & Security › Microphone."
        case .speechRecognitionDenied:
            return "\"Hey Ivy\" wake-up needs speech recognition. Allow Ivy in System Settings › Privacy & Security › Speech Recognition."
        case .onDeviceRecognitionUnavailable:
            return "\"Hey Ivy\" wake-up needs on-device speech recognition for English, which isn't available on this Mac. Ambient audio is never sent to a server."
        case .audioEngineFailed(let reason):
            return "\"Hey Ivy\" wake-up couldn't start the microphone: \(reason)"
        }
    }
}

/// Idle wake-word listener: its own microphone tap, feeding on-device speech recognition only, so ambient
/// audio never leaves the Mac. Matches with the same `WakePhraseMatcher` as in-session barge-in.
public final class SystemWakeWordListener: WakeWordListening, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var isListening = false
        var request: SFSpeechAudioBufferRecognitionRequest? = nil
        var task: SFSpeechRecognitionTask? = nil
        var taskId: UUID? = nil
        var onWake: (@Sendable () -> Void)? = nil
        var recentRestarts: [Date] = []
        /// ponytail: 1.5 s covers "Hey Ivy" plus the recognizer's lag, so the words right after it survive the
        /// hand-over; it can also hold a moment of what was said just before. Trim to the phrase's end time if
        /// the recognizer's segment timestamps prove reliable.
        var preRoll = PCMRingBuffer(seconds: 1.5)
    }

    private static let preRollFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false)

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let engine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?

    private let routeQueue = DispatchQueue(label: "com.ivy.assistant.wake-route")
    /// Set once in init, removed in deinit; never mutated concurrently.
    private var configObserver: NSObjectProtocol?

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.routeQueue.async { [weak self] in
                self?.handleConfigurationChange()
            }
        }
    }

    deinit {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
        }
    }

    public func start(onWake: @escaping @Sendable () -> Void) async throws {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            throw WakeWordListenerError.requiresAppBundle
        }
        guard await Self.speechAuthorized() else { throw WakeWordListenerError.speechRecognitionDenied }
        guard await Self.microphoneAuthorized() else { throw WakeWordListenerError.microphoneDenied }
        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            throw WakeWordListenerError.onDeviceRecognitionUnavailable
        }

        await stop()
        try installTap()
        state.withLock { s in
            s.isListening = true
            s.onWake = onWake
            s.recentRestarts = []
        }
        startRecognitionTask()
        do {
            try engine.start()
        } catch {
            await stop()
            throw WakeWordListenerError.audioEngineFailed(error.localizedDescription)
        }
        print("[WAKE] idle wake-word listening started (on-device)")
    }

    /// Taps the current input device in its native format (the recognizer needs no conversion).
    private func installTap() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw WakeWordListenerError.audioEngineFailed("no audio input device")
        }
        let converter = Self.preRollFormat.flatMap { AVAudioConverter(from: format, to: $0) }
        if format.channelCount > 1 { converter?.channelMap = [0] }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            let pcm = converter.flatMap { Self.convert(buffer, with: $0) }
            self?.state.withLock { s in
                s.request?.append(buffer)
                if let pcm { s.preRoll.append(pcm) }
            }
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> Data? {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000.0 / buffer.format.sampleRate)
        guard capacity > 0, let format = preRollFormat,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        // A failed conversion only costs the pre-roll; wake detection itself uses the unconverted buffer.
        guard status != .error, let samples = out.int16ChannelData else { return nil }
        return Data(bytes: samples[0], count: Int(out.frameLength) * 2)
    }

    public func takePreRoll() -> Data {
        state.withLock { $0.preRoll.drain() }
    }

    /// Audio route changed while listening (device plugged/unplugged, default input switched): re-tap the new
    /// device with its own format and start a fresh recognition request for it.
    private func handleConfigurationChange() {
        guard state.withLock({ $0.isListening }) else { return }
        engine.inputNode.removeTap(onBus: 0)
        do {
            try installTap()
            startRecognitionTask()
            if !engine.isRunning {
                try engine.start()
            }
            print("[WAKE] audio route changed; wake-word listening reconfigured")
        } catch {
            print("[WAKE] wake-word listening stopped: audio route change could not be recovered: \(error.localizedDescription)")
            state.withLock { s in
                s.isListening = false
                s.request?.endAudio()
                s.task?.cancel()
                s.request = nil
                s.task = nil
                s.taskId = nil
                s.onWake = nil
            }
            engine.stop()
        }
    }

    public func stop() async {
        await stop(keepPreRoll: false)
    }

    private func stop(keepPreRoll: Bool) async {
        let (wasListening, request, task) = state.withLock { s -> (Bool, SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            defer {
                if !keepPreRoll { _ = s.preRoll.drain() }
                s.isListening = false
                s.request = nil
                s.task = nil
                s.taskId = nil
                s.onWake = nil
            }
            return (s.isListening, s.request, s.task)
        }
        request?.endAudio()
        task?.cancel()
        if wasListening {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            print("[WAKE] idle wake-word listening stopped")
        }
    }

    /// A fresh request per task: recognition tasks end on each final result, on errors, and on long silences.
    private func startRecognitionTask() {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = ["Hey Ivy", "Ivy"]
        let taskId = UUID()

        let started = state.withLock { s -> Bool in
            guard s.isListening else { return false }
            s.request?.endAudio()
            s.task?.cancel()
            s.request = request
            s.taskId = taskId
            return true
        }
        guard started else { return }

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let heard = [result.bestTranscription.formattedString] + result.transcriptions.map(\.formattedString)
                if heard.contains(where: WakePhraseMatcher.containsWakePhrase) {
                    self.fireWake(taskId: taskId)
                    return
                }
            }
            if error != nil || result?.isFinal == true {
                self.restart(after: taskId)
            }
        }
        state.withLock { s in
            if s.taskId == taskId { s.task = task } else { task.cancel() }
        }
    }

    private func fireWake(taskId: UUID) {
        let onWake = state.withLock { s -> (@Sendable () -> Void)? in
            guard s.taskId == taskId, s.isListening else { return nil }
            defer { s.onWake = nil }
            return s.onWake
        }
        guard let onWake else { return }
        Task { [weak self] in
            await self?.stop(keepPreRoll: true) // hand the microphone to Live; the controller collects the pre-roll
            onWake()
        }
    }

    /// Restarts the finished task; backs off if the recognizer keeps failing so it can't spin.
    private func restart(after taskId: UUID) {
        let delay = state.withLock { s -> Double? in
            guard s.taskId == taskId, s.isListening else { return nil }
            let now = Date()
            s.recentRestarts = s.recentRestarts.filter { now.timeIntervalSince($0) < 60 } + [now]
            return s.recentRestarts.count > 20 ? 5.0 : 0.2
        }
        guard let delay else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.state.withLock({ $0.taskId == taskId && $0.isListening }) else { return }
            self.startRecognitionTask()
        }
    }

    private static func speechAuthorized() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
            }
        default: return false
        }
    }

    private static func microphoneAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
