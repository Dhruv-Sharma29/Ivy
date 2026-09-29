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
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let engine = AVAudioEngine()
    private let recognizer: SFSpeechRecognizer?

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
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
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw WakeWordListenerError.audioEngineFailed("no audio input device")
        }
        // The recognizer accepts the device's native format; no conversion needed.
        print("[WAKEDIAG] input format \(format.sampleRate)Hz \(format.channelCount)ch \(format.commonFormat.rawValue) vp=\(input.isVoiceProcessingEnabled)") // WAKEDIAG
        nonisolated(unsafe) var diagCount = 0 // WAKEDIAG
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            let hasRequest = self?.state.withLock { s -> Bool in s.request?.append(buffer); return s.request != nil } ?? false
            diagCount += 1 // WAKEDIAG
            if diagCount % 40 == 1, let ch = buffer.floatChannelData { var peak: Float = 0; for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(ch[0][i])) }; print("[WAKEDIAG] tap #\(diagCount) peak=\(peak) appended=\(hasRequest)") } // WAKEDIAG
        }
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

    public func stop() async {
        let (wasListening, request, task) = state.withLock { s -> (Bool, SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            defer {
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

        print("[WAKEDIAG] recognition task start onDevice=\(recognizer.supportsOnDeviceRecognition) available=\(recognizer.isAvailable)") // WAKEDIAG
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let error { print("[WAKEDIAG] recognition error: \(error.localizedDescription)") } // WAKEDIAG
            if let result {
                let heard = [result.bestTranscription.formattedString] + result.transcriptions.map(\.formattedString)
                print("[WAKEDIAG] heard final=\(result.isFinal) \(heard.prefix(3))") // WAKEDIAG
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
            await self?.stop() // hand the microphone to Live
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
