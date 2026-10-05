import Foundation

/// Global AppKit points (bottom-left origin), bound to the display that the user selected.
public struct ScreenRegionSelection: Equatable, Sendable {
    public let displayID: UInt32
    public let screen: CGRect
    public let rect: CGRect

    public init?(displayID: UInt32, screen: CGRect, rect: CGRect) {
        guard Self.valid(screen), Self.valid(rect), screen.contains(rect), rect.width >= 8, rect.height >= 8 else { return nil }
        self.displayID = displayID; self.screen = screen; self.rect = rect
    }

    /// ScreenCaptureKit source rectangles are display-local points with a top-left origin.
    public var sourceRect: CGRect {
        CGRect(x: rect.minX - screen.minX, y: screen.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Capture directly at the vision pipeline's resolution limit, avoiding a full Retina-sized bitmap.
    public func pixelSize(atScale scale: CGFloat) -> CGSize? {
        guard scale.isFinite, scale > 0 else { return nil }
        let bounded = min(scale, 2048 / max(rect.width, rect.height))
        return CGSize(width: max(1, (rect.width * bounded).rounded(.down)), height: max(1, (rect.height * bounded).rounded(.down)))
    }

    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite)
            && rect.width > 0 && rect.height > 0 && rect.width <= 20_000 && rect.height <= 20_000
    }
}

public enum ScreenQuestionShortcut: String, Codable, CaseIterable, Sendable {
    case pushToTalk, region, area
    public var label: String {
        switch self { case .pushToTalk: "Voice key (⌘⇧Space)"; case .region: "⌃⌥⌘R"; case .area: "⌃⌥⌘A" }
    }
    public var hotkey: HotkeyShortcut {
        if self == .pushToTalk { return .defaultPushToTalk }
        return HotkeyShortcut(keyCode: self == .region ? 15 : 0, modifiers: [.control, .option, .command])
    }
}

/// A bounded freehand stroke. The outlined rectangle shows the entire crop, including lasso corners.
public struct ScreenSelectionGesture: Sendable {
    public enum Mode: Sendable { case freehand, rectangle }
    public var mode: Mode = .freehand
    public private(set) var points: [CGPoint] = []
    public private(set) var hover = CGPoint.zero
    public init() {}

    public mutating func move(_ point: CGPoint) {
        if point.x.isFinite && point.y.isFinite { hover = point }
    }
    public mutating func begin(_ point: CGPoint) {
        points = []; move(point)
        if point.x.isFinite && point.y.isFinite { points = [point] }
    }
    public mutating func drag(_ point: CGPoint) {
        guard !points.isEmpty, point.x.isFinite, point.y.isFinite else { return }
        move(point)
        if mode == .rectangle {
            points = [points[0], point]
        } else if points.count < 1024 {
            points.append(point)
        }
    }
    public func crop(in screen: CGRect) -> CGRect {
        if let first = points.first, points.count > 1 {
            let minX = points.reduce(first.x) { min($0, $1.x) }, maxX = points.reduce(first.x) { max($0, $1.x) }
            let minY = points.reduce(first.y) { min($0, $1.y) }, maxY = points.reduce(first.y) { max($0, $1.y) }
            let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(screen)
            if rect.width >= 8 && rect.height >= 8 { return rect }
        }
        let width = min(240, screen.width), height = min(180, screen.height)
        return CGRect(x: min(max(hover.x - width / 2, screen.minX), screen.maxX - width),
                      y: min(max(hover.y - height / 2, screen.minY), screen.maxY - height), width: width, height: height)
    }
}

public protocol SelectedRegionCapturing: Sendable {
    func capture(selection: ScreenRegionSelection, excludedApps: [String]) async throws -> CapturedScreen
}
