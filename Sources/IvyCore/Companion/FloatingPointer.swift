import Foundation

public enum FloatingPointerColor: String, Codable, CaseIterable, Sendable {
    case blue, green, amber, red
}

/// AppKit screen coordinates. This moves a decorative panel, never the system cursor.
public struct FloatingPointerPlacement: Sendable {
    public static let size = CGSize(width: 32, height: 32)
    private var previous: CGRect?
    private var display: CGRect?

    public init() {}

    public mutating func reset() {
        previous = nil
        display = nil
    }

    /// Reduce Motion disables following; existing stationary point_at guidance remains available.
    public mutating func update(cursor: CGPoint, screens: [CGRect], reduceMotion: Bool) -> CGRect? {
        guard !reduceMotion, cursor.x.isFinite, cursor.y.isFinite,
              let screen = screens.first(where: {
                  $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite
                      && $0.width >= 96 && $0.height >= 96 && $0.contains(cursor)
              }) else {
            reset()
            return nil
        }
        let size = Self.size
        var x = cursor.x + 24
        var y = cursor.y - 24 - size.height
        if x + size.width > screen.maxX { x = cursor.x - 24 - size.width }
        if y < screen.minY { y = cursor.y + 24 }
        x = min(max(x, screen.minX), screen.maxX - size.width)
        y = min(max(y, screen.minY), screen.maxY - size.height)
        let target = CGPoint(x: x, y: y)
        var origin = target
        if display == screen, let previous {
            let dx = target.x - previous.minX, dy = target.y - previous.minY
            let distance = hypot(dx, dy)
            // Large jumps/changed displays snap; ordinary motion has a short, bounded trailing effect.
            if distance > 0.25 && distance < 400 {
                let fraction = min(0.35, 24 / distance)
                origin = CGPoint(x: previous.minX + dx * fraction, y: previous.minY + dy * fraction)
            }
        }
        let frame = CGRect(origin: origin, size: size)
        previous = frame
        display = screen
        return frame
    }
}
