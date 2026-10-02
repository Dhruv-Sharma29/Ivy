import Foundation

/// A free position relative to a display's usable area, so resolution changes cannot strand Ivy off-screen.
public struct CompanionPlacement: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let horizontal: Double
    public let vertical: Double

    public init(origin: CGPoint, panelSize: CGSize, visibleFrame: CGRect, displayID: UInt32, contentFrame: CGRect? = nil) {
        let content = contentFrame ?? CGRect(origin: .zero, size: panelSize)
        self.displayID = displayID
        horizontal = Self.fraction(origin.x + content.minX - visibleFrame.minX, extent: visibleFrame.width - content.width)
        vertical = Self.fraction(origin.y + content.minY - visibleFrame.minY, extent: visibleFrame.height - content.height)
    }

    public func origin(panelSize: CGSize, visibleFrame: CGRect, contentFrame: CGRect? = nil) -> CGPoint {
        let content = contentFrame ?? CGRect(origin: .zero, size: panelSize)
        return CGPoint(x: visibleFrame.minX - content.minX + Self.bounded(horizontal) * max(0, visibleFrame.width - content.width),
                       y: visibleFrame.minY - content.minY + Self.bounded(vertical) * max(0, visibleFrame.height - content.height))
    }

    private static func fraction(_ value: CGFloat, extent: CGFloat) -> Double {
        extent > 0 ? bounded(Double(value / extent)) : 0
    }

    private static func bounded(_ value: Double) -> Double {
        value.isFinite ? max(0, min(1, value)) : 0.5
    }
}
