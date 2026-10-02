import SwiftUI
import IvyCore

/// Frames are read left-to-right from a 4 × 4 sheet. Each pose owns a consistent pair.
enum CompanionPose: Int, CaseIterable {
    case idle, listening, thinking, speaking, working, approval, error, greeting

    init(mood: CompanionMood) {
        switch mood {
        case .hidden, .idle: self = .idle
        case .listening: self = .listening
        case .thinking: self = .thinking
        case .speaking: self = .speaking
        case .working: self = .working
        case .needsApproval: self = .approval
        case .error: self = .error
        }
    }

    var firstFrame: Int { rawValue * 2 }
}

/// Pure sampling keeps animation deterministic and lets Reduce Motion bypass every moving property.
struct CompanionAnimationSample: Equatable {
    let frame: Int
    let verticalOffset: Double
    let scale: Double
    var rotationDegrees: Double = 0

    static func sample(mood: CompanionMood, elapsed: TimeInterval, level: Float, reduceMotion: Bool, isMoving: Bool = false) -> Self {
        let pose = CompanionPose(mood: mood)
        guard !reduceMotion, mood.isVisible else {
            return Self(frame: pose.firstFrame, verticalOffset: 0, scale: 1)
        }
        let time = elapsed.isFinite ? max(0, elapsed) : 0
        let audio = level.isFinite ? Double(max(0, min(1, level))) : 0
        if isMoving {
            let step = sin(time * .pi / 0.28)
            let base = pose == .idle ? CompanionPose.greeting.firstFrame : pose.firstFrame
            let alternate = pose == .speaking ? (audio > 0.025 ? 1 : 0) : (step >= 0 ? 0 : 1)
            return Self(frame: base + alternate,
                        verticalOffset: -abs(step) * 4, scale: 1.025, rotationDegrees: step * 4)
        }
        let frame: Int
        switch pose {
        case .idle:
            if time < 1.8 {
                frame = CompanionPose.greeting.firstFrame + (time.truncatingRemainder(dividingBy: 0.6) < 0.3 ? 0 : 1)
            } else {
                frame = pose.firstFrame + (time.truncatingRemainder(dividingBy: 4.8) > 4.62 ? 1 : 0)
            }
        case .approval:
            frame = pose.firstFrame + (time.truncatingRemainder(dividingBy: 4.8) > 4.62 ? 1 : 0)
        case .speaking:
            // The open mouth follows actual playback level; silence never looks like invented speech.
            frame = pose.firstFrame + (audio > 0.025 ? 1 : 0)
        case .working:
            frame = pose.firstFrame + (time.truncatingRemainder(dividingBy: 0.9) < 0.45 ? 0 : 1)
        case .listening, .thinking, .error, .greeting:
            frame = pose.firstFrame + (time.truncatingRemainder(dividingBy: 2.4) < 1.2 ? 0 : 1)
        }
        let breathing = pose == .approval || pose == .error ? 0 : sin(time * .pi / 1.8) * (pose == .idle ? 2.4 : 1.2)
        let isVoice = pose == .listening || pose == .speaking
        return Self(frame: frame, verticalOffset: breathing, scale: 1 + (isVoice ? audio * 0.025 : 0),
                    rotationDegrees: pose == .idle ? sin(time * .pi / 2.4) * 1.5 : 0)
    }
}

/// Decode once and extract the source grid without smoothing or repeatedly decoding on animation ticks.
@MainActor
enum CompanionSpriteSheet {
    static let frames: [NSImage] = {
        guard let url = Bundle.module.url(forResource: "IvyCompanionSprites", withExtension: "png"),
              let image = NSImage(contentsOf: url),
              let sheet = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        return (0..<16).compactMap { index in
            let left = sheet.width * (index % 4) / 4
            let right = sheet.width * (index % 4 + 1) / 4
            let top = sheet.height * (index / 4) / 4
            let bottom = sheet.height * (index / 4 + 1) / 4
            guard let frame = sheet.cropping(to: CGRect(x: left, y: top, width: right - left, height: bottom - top)) else { return nil }
            return NSImage(cgImage: frame, size: NSSize(width: 96, height: 96))
        }
    }()
}

struct CompanionSpriteView: View {
    let mood: CompanionMood
    @ObservedObject var meter: AudioLevelMeter
    var motionDisabled = false
    var isMoving = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // A timestamp belongs to this view's lifetime, rather than to the parent model's state.
    @State private var startedAt = Date()

    private var pose: CompanionPose { CompanionPose(mood: mood) }
    private var motionReduced: Bool { reduceMotion || motionDisabled }
    private var level: Float {
        switch mood {
        case .listening: meter.inputLevel
        case .speaking: meter.outputLevel
        default: 0
        }
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: isMoving ? 0.07 : 0.12, paused: motionReduced || !mood.isVisible)) { timeline in
            let sample = CompanionAnimationSample.sample(mood: mood, elapsed: timeline.date.timeIntervalSince(startedAt),
                                                         level: level, reduceMotion: motionReduced, isMoving: isMoving)
            Group {
                if CompanionSpriteSheet.frames.indices.contains(sample.frame) {
                    Image(nsImage: CompanionSpriteSheet.frames[sample.frame])
                        .resizable().interpolation(.none).scaledToFit()
                } else {
                    Image(nsImage: IvyLogoImage.template).resizable().scaledToFit().foregroundStyle(IvyTheme.moss)
                }
            }
            .frame(width: 96, height: 96)
            .scaleEffect(sample.scale, anchor: .bottom)
            .rotationEffect(.degrees(sample.rotationDegrees), anchor: .bottom)
            .offset(y: sample.verticalOffset)
        }
        .onAppear { startedAt = Date() }
        .onChange(of: pose) { startedAt = Date() }
        .onChange(of: mood.isVisible) { startedAt = Date() }
        .onChange(of: isMoving) { startedAt = Date() }
        .accessibilityHidden(true)
    }
}
