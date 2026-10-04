import Foundation

/// Converts global AppKit points into a display-local, top-left canvas. Pixel scale is irrelevant.
public struct AnnotationGeometry: Equatable, Sendable {
    public let highlight: CGRect
    public let start: CGPoint
    public let end: CGPoint
    public let headA: CGPoint
    public let headB: CGPoint
    public let labelOrigin: CGPoint
    public let labelWidth: CGFloat

    /// Arrowhead travels with the tip during the entrance, then lands at the target edge.
    public func arrow(at progress: CGFloat) -> (tip: CGPoint, headA: CGPoint, headB: CGPoint) {
        let t = progress.isFinite ? min(1, max(0, progress)) : 0
        let tip = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
        let offset = CGPoint(x: tip.x - end.x, y: tip.y - end.y)
        return (tip, CGPoint(x: headA.x + offset.x, y: headA.y + offset.y),
                CGPoint(x: headB.x + offset.x, y: headB.y + offset.y))
    }

    public init?(screen: CGRect, target: CGRect) {
        guard [screen.minX, screen.minY, screen.width, screen.height, target.minX, target.minY, target.width, target.height].allSatisfy(\.isFinite),
              screen.width >= 64, screen.height >= 64, target.width > 0, target.height > 0 else { return nil }
        let clipped = screen.intersection(target)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        let h = CGRect(x: clipped.minX - screen.minX, y: screen.maxY - clipped.maxY, width: clipped.width, height: clipped.height)
        highlight = h
        let margin: CGFloat = 16
        let candidates: [(CGPoint, CGPoint)] = [
            (CGPoint(x: margin, y: h.midY), CGPoint(x: max(margin, h.minX - 6), y: h.midY)),
            (CGPoint(x: screen.width - margin, y: h.midY), CGPoint(x: min(screen.width - margin, h.maxX + 6), y: h.midY)),
            (CGPoint(x: h.midX, y: margin), CGPoint(x: h.midX, y: max(margin, h.minY - 6))),
            (CGPoint(x: h.midX, y: screen.height - margin), CGPoint(x: h.midX, y: min(screen.height - margin, h.maxY + 6)))
        ]
        func length(_ pair: (CGPoint, CGPoint)) -> CGFloat { hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y) }
        let fallback = (CGPoint(x: margin, y: margin), CGPoint(x: h.midX, y: h.midY))
        let pair = candidates.filter({ length($0) >= 40 }).min(by: { length($0) < length($1) }) ?? fallback
        guard length(pair) > 0 else { return nil }
        start = pair.0; end = pair.1
        let dx = (end.x - start.x) / length(pair), dy = (end.y - start.y) / length(pair)
        headA = CGPoint(x: end.x - dx * 12 - dy * 6, y: end.y - dy * 12 + dx * 6)
        headB = CGPoint(x: end.x - dx * 12 + dy * 6, y: end.y - dy * 12 - dx * 6)
        labelWidth = min(280, screen.width - margin * 2)
        labelOrigin = CGPoint(x: min(max(margin, h.minX), screen.width - margin - labelWidth),
                              y: min(max(margin, h.minY - 32), screen.height - margin - 28))
    }
}
