import Foundation

/// Decorative idle moments never represent a tool, task, microphone or approval state.
enum CompanionIdleActivity: Int, CaseIterable {
    case phone, laptop, dance

    var firstFrame: Int { 16 + rawValue * 4 }
    var duration: TimeInterval {
        switch self {
        case .phone: 9
        case .laptop: 11
        case .dance: 5
        }
    }
}

struct CompanionIdleMoment: Equatable {
    let activity: CompanionIdleActivity
    let elapsed: TimeInterval

    /// One brief activity per 48-second window, with a random quiet lead-in and longer rest afterward.
    /// A view-lifetime seed avoids changing the choice on every frame. Tests supply a fixed seed.
    static func sample(elapsed: TimeInterval, seed: UInt64) -> Self? {
        guard elapsed.isFinite, elapsed >= 0 else { return nil }
        let cycle = UInt64(floor(elapsed / 48).truncatingRemainder(dividingBy: 65_536))
        var random = seed &+ cycle &* 0x9E3779B97F4A7C15
        random = (random ^ (random >> 30)) &* 0xBF58476D1CE4E5B9
        random = (random ^ (random >> 27)) &* 0x94D049BB133111EB
        random ^= random >> 31
        let start = TimeInterval(12 + random % 13)
        let position = elapsed.truncatingRemainder(dividingBy: 48) - start
        let choice = (random >> 8) % 5
        let activity: CompanionIdleActivity = choice < 2 ? .phone : (choice < 4 ? .laptop : .dance)
        guard position >= 0, position < activity.duration else { return nil }
        return Self(activity: activity, elapsed: position)
    }

    var animation: CompanionAnimationSample {
        let dancing = activity == .dance
        let beat = sin(elapsed * .pi / 0.6)
        let frame = activity.firstFrame + Int(elapsed / (dancing ? 0.24 : 0.4)) % 4
        return CompanionAnimationSample(frame: frame, verticalOffset: dancing ? -abs(beat) * 3 : 0,
                                        scale: 1, rotationDegrees: dancing ? beat * 3 : 0)
    }
}
