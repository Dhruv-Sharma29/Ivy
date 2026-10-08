import Foundation
import Combine
import os

/// Energy-based voice activity detection over 16 kHz 16-bit mono PCM: RMS per 20 ms frame against a noise
/// floor that adapts to the room. Drives the "hearing you" indicator, end-of-speech latency marks and the
/// wake-session silence timeout. It never decides turn boundaries: the Live server does that.
public struct VoiceActivityDetector: Sendable {
    static let frameSamples = 320 // 20 ms at 16 kHz
    /// Speech must be this many times louder than the room…
    static let speechRatio = 3.0
    /// …and at least this loud, so a silent room's tiny floor doesn't make breathing count as speech.
    static let minimumSpeechRMS = 300.0
    /// Frames (200 ms) speech stays "on" after the last loud frame, bridging gaps between words.
    static let hangoverFrames = 10

    public private(set) var noiseFloor: Double = 100
    public private(set) var isSpeech = false
    /// Loudness of the most recent frame, 0…1 (RMS relative to full scale, perceptually stretched).
    public private(set) var level: Float = 0
    private var hangover = 0

    public init() {}

    /// Feeds one capture chunk. Returns true if any frame in it was speech.
    @discardableResult
    public mutating func process(_ pcm: Data) -> Bool {
        var heard = false
        pcm.withUnsafeBytes { raw in
            let sampleCount = raw.count / 2
            var start = 0
            while start < sampleCount {
                let end = min(start + Self.frameSamples, sampleCount)
                var sum = 0.0
                for i in start..<end {
                    let s = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
                    sum += s * s
                }
                let rms = (sum / Double(end - start)).squareRoot()
                level = Self.level(rms: rms)
                if rms > max(noiseFloor * Self.speechRatio, Self.minimumSpeechRMS) {
                    heard = true
                    hangover = Self.hangoverFrames
                    // Creep up slowly, so a room that got louder (fan, music) stops reading as speech eventually.
                    noiseFloor += (rms - noiseFloor) * 0.002
                } else {
                    hangover = max(0, hangover - 1)
                    noiseFloor += (rms - noiseFloor) * 0.05
                }
                isSpeech = hangover > 0
                start = end
            }
        }
        return heard
    }

    /// RMS of a whole chunk as a 0…1 level (for meters that don't need the detector's state).
    public static func level(of pcm: Data) -> Float {
        let count = pcm.count / 2
        guard count > 0 else { return 0 }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                let v = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)))
                sum += v * v
            }
        }
        return level(rms: (sum / Double(count)).squareRoot())
    }

    static func level(rms: Double) -> Float {
        // Square root stretches quiet speech into the visible range.
        Float(min(1, (rms / 32768).squareRoot() * 1.8))
    }
}

/// Input (the user's voice) and output (Ivy's voice) loudness for the UI. Reports may arrive from audio
/// threads at any rate; published values change at most 30 times a second, on the main actor.
public final class AudioLevelMeter: ObservableObject, @unchecked Sendable {
    public static let publishInterval: TimeInterval = 1.0 / 30

    /// 0…1. Mutated only on the main actor.
    @Published public private(set) var inputLevel: Float = 0
    @Published public private(set) var outputLevel: Float = 0

    private struct Pending {
        var input: Float?
        var output: Float?
        var lastPublish = Date.distantPast
        var scheduled = false
    }
    private let pending = OSAllocatedUnfairLock(initialState: Pending())

    public init() {}

    public func reportInput(_ level: Float) { report { $0.input = level } }
    public func reportOutput(_ level: Float) { report { $0.output = level } }

    /// Both meters to zero (session ended).
    public func reset() {
        report { $0.input = 0; $0.output = 0 }
    }

    private func report(_ set: @Sendable (inout Pending) -> Void) {
        let delay = pending.withLock { p -> TimeInterval? in
            set(&p)
            guard !p.scheduled else { return nil } // a publish is already on its way and will carry this value
            p.scheduled = true
            return max(0, Self.publishInterval - Date().timeIntervalSince(p.lastPublish))
        }
        guard let delay else { return }
        Task { @MainActor [weak self] in
            if delay > 0 {
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return // cancelled with its owner; nothing left to update
                }
            }
            self?.publish()
        }
    }

    @MainActor
    private func publish() {
        let (input, output) = pending.withLock { p -> (Float?, Float?) in
            defer { p.input = nil; p.output = nil; p.scheduled = false; p.lastPublish = Date() }
            return (p.input, p.output)
        }
        if let input, input != inputLevel { inputLevel = input }
        if let output, output != outputLevel { outputLevel = output }
    }
}

/// Fixed-capacity store of the most recent PCM bytes. Memory only; overwritten continuously.
public struct PCMRingBuffer: Sendable {
    public let capacity: Int
    private var bytes = Data()

    /// `seconds` of 16 kHz 16-bit mono audio.
    public init(seconds: Double) {
        self.capacity = Int(seconds * 16000) * 2
    }

    public mutating func append(_ chunk: Data) {
        bytes.append(chunk)
        if bytes.count > capacity {
            bytes = Data(bytes.suffix(capacity))
        }
    }

    /// Returns what is buffered and empties the buffer.
    public mutating func drain() -> Data {
        defer { bytes = Data() }
        return bytes
    }

    public var isEmpty: Bool { bytes.isEmpty }
    public var count: Int { bytes.count }
}

/// How long a pause Ivy tolerates before deciding the user has finished speaking.
public enum VoicePatience: String, Codable, CaseIterable, Sendable {
    case short, normal, long

    /// Nil leaves the server's own end-of-speech timing in place.
    public var silenceDurationMs: Int? {
        switch self {
        case .short: return 300
        case .normal: return nil
        case .long: return 1500
        }
    }
}

public enum VoiceResponseLength: String, Codable, CaseIterable, Sendable {
    case brief, normal, detailed
}

public enum VoiceSpeakingPace: String, Codable, CaseIterable, Sendable {
    case slow, normal, fast
}

/// Spoken-style hints for Live. These only add text to the system instruction: the voice itself stays Tavi.
public enum LiveVoiceStyle {
    public static func instruction(base: String, length: VoiceResponseLength, pace: VoiceSpeakingPace) -> String {
        var hints: [String] = []
        switch length {
        case .brief: hints.append("Keep spoken answers to one or two short sentences unless asked for more.")
        case .normal: break
        case .detailed: hints.append("Give fuller spoken answers with the relevant detail.")
        }
        switch pace {
        case .slow: hints.append("Speak slowly and clearly.")
        case .normal: break
        case .fast: hints.append("Speak at a brisk pace.")
        }
        return hints.isEmpty ? base : base + "\n\nSpeaking style: " + hints.joined(separator: " ")
    }
}

/// The spoken commands Ivy handles itself. This is the whole list: nothing here can approve a tool, and
/// "yes", "confirm", "do it" and the like are deliberately not commands.
public enum VoiceCommand: Equatable, Sendable {
    /// Stop talking (after a barge-in there is nothing left to stop; Ivy just doesn't answer the word).
    case stop
    /// Abandon the current turn. A pending confirmation is denied.
    case cancel
    case endSession
    case mute
    case unmute
    case repeatLast

    private static let phrases: [[String]: VoiceCommand] = [
        ["stop"]: .stop, ["stop", "it"]: .stop, ["be", "quiet"]: .stop,
        ["cancel"]: .cancel, ["cancel", "that"]: .cancel, ["never", "mind"]: .cancel, ["nevermind"]: .cancel,
        ["end"]: .endSession, ["goodbye"]: .endSession, ["good", "bye"]: .endSession, ["bye"]: .endSession,
        ["mute"]: .mute, ["unmute"]: .unmute,
        ["repeat", "that"]: .repeatLast, ["repeat"]: .repeatLast, ["say", "that", "again"]: .repeatLast,
    ]

    /// The utterance must be nothing but the command. It counts when it follows "Hey Ivy" (in the same
    /// utterance, or `afterWake`: the user just interrupted with it); a bare "goodbye" also ends the session.
    public static func parse(_ utterance: String, afterWake: Bool = false) -> VoiceCommand? {
        var tokens = WakePhraseMatcher.extractTokens(utterance)
        var addressed = afterWake
        if tokens.count >= 2, WakePhraseMatcher.isHey(tokens[0]), WakePhraseMatcher.isIvy(tokens[1]) {
            tokens.removeFirst(2)
            addressed = true
        }
        guard let command = phrases[tokens] else { return nil }
        if addressed { return command }
        return command == .endSession && tokens != ["end"] ? command : nil
    }
}
