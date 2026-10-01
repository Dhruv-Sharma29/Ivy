import Foundation
import CoreGraphics

/// What the on-screen companion shows. It appears only while something is happening (or when the user asked
/// for it to stay), and approval always wins: a card waiting for the user must never be hidden behind a face.
public enum CompanionMood: Equatable, Sendable {
    case hidden
    case idle
    case listening
    case thinking
    case speaking
    /// A task step is running; progress 0…1.
    case working(Double)
    case needsApproval
    case error(String)

    public var isVisible: Bool { self != .hidden }

    /// Highest priority first: approval > error > speaking > listening > working > thinking > idle/hidden.
    public static func resolve(
        voice: VoiceSessionState,
        chatThinking: Bool,
        approvalPending: Bool,
        task: TaskRun?,
        showWhileIdle: Bool
    ) -> CompanionMood {
        if approvalPending || voice.isToolConfirmation { return .needsApproval }
        if case .awaitingApproval? = task?.phase { return .needsApproval }
        if case .paused? = task?.phase { return .needsApproval }
        if case .error(let message) = voice { return .error(message) }
        switch voice {
        case .speaking: return .speaking
        case .listening, .interrupting: return .listening
        case .connecting, .reconnecting, .thinking, .toolExecution: return .thinking
        case .idle, .error, .toolConfirmation: break
        }
        if let task, task.isActive {
            if case .planning = task.phase { return .thinking }
            let steps = task.plan.steps
            let done = steps.filter(\.status.isFinished).count
            return .working(steps.isEmpty ? 0 : Double(done) / Double(steps.count))
        }
        if chatThinking { return .thinking }
        return showWhileIdle ? .idle : .hidden
    }

    /// The face for this mood (drawn as shapes; the kaomoji is for VoiceOver and the roadmap's reference).
    public var accessibilityDescription: String {
        switch self {
        case .hidden: return "Ivy is hidden"
        case .idle: return "Ivy is here"
        case .listening: return "Ivy is listening"
        case .thinking: return "Ivy is thinking"
        case .speaking: return "Ivy is speaking"
        case .working(let p): return "Ivy is working, \(Int(p * 100)) percent done"
        case .needsApproval: return "Ivy needs your approval"
        case .error(let message): return "Ivy hit a problem: \(message)"
        }
    }
}

/// Where the companion sits: a corner of the screen's visible frame (AppKit coordinates, origin bottom-left).
public enum CompanionCorner: String, Codable, CaseIterable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight

    public static let margin: CGFloat = 16

    /// The panel origin for this corner.
    public func origin(for size: CGSize, in visibleFrame: CGRect, margin: CGFloat = margin) -> CGPoint {
        let left = visibleFrame.minX + margin
        let right = visibleFrame.maxX - size.width - margin
        let bottom = visibleFrame.minY + margin
        let top = visibleFrame.maxY - size.height - margin
        switch self {
        case .topLeft: return CGPoint(x: left, y: top)
        case .topRight: return CGPoint(x: right, y: top)
        case .bottomLeft: return CGPoint(x: left, y: bottom)
        case .bottomRight: return CGPoint(x: right, y: bottom)
        }
    }

    /// Where a dragged panel snaps: the corner nearest its centre.
    public static func nearest(to center: CGPoint, in visibleFrame: CGRect) -> CompanionCorner {
        let isTop = center.y >= visibleFrame.midY
        let isRight = center.x >= visibleFrame.midX
        switch (isTop, isRight) {
        case (true, true): return .topRight
        case (true, false): return .topLeft
        case (false, true): return .bottomRight
        case (false, false): return .bottomLeft
        }
    }
}

// MARK: - Screenshot geometry and pointing

/// Where a capture came from on screen, so a point in the image Ivy was shown can be found again on screen.
public struct CaptureGeometry: Equatable, Sendable {
    /// The captured area in global display coordinates (points, origin top-left of the main display — the
    /// convention CoreGraphics and ScreenCaptureKit use).
    public let frame: CGRect
    /// Pixel size of the image actually sent (after downscaling).
    public let imageSize: CGSize

    public init(frame: CGRect, imageSize: CGSize) {
        self.frame = frame
        self.imageSize = imageSize
    }

    /// A rectangle in image pixels → the same area in AppKit screen coordinates (origin bottom-left of the main
    /// display), clamped to the image. `mainDisplayHeight` is the main display's height in points.
    public func screenRect(forImageRect rect: CGRect, mainDisplayHeight: CGFloat) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0, frame.width > 0, frame.height > 0 else { return nil }
        let bounds = CGRect(origin: .zero, size: imageSize)
        let clamped = rect.standardized.intersection(bounds)
        guard !clamped.isNull, clamped.width > 0, clamped.height > 0 else { return nil }
        let sx = frame.width / imageSize.width
        let sy = frame.height / imageSize.height
        let topLeftGlobal = CGRect(x: frame.minX + clamped.minX * sx, y: frame.minY + clamped.minY * sy,
                                   width: clamped.width * sx, height: clamped.height * sy)
        // Flip from top-left (CG) to bottom-left (AppKit) global coordinates.
        return CGRect(x: topLeftGlobal.minX, y: mainDisplayHeight - topLeftGlobal.maxY,
                      width: topLeftGlobal.width, height: topLeftGlobal.height)
    }
}

/// The geometry of the latest screenshot Ivy was shown, read by `point_at` (lock-backed: tools run off the main actor).
public final class ScreenGeometryRelay: Sendable {
    private let latest = OSAllocatedUnfairLockBox<CaptureGeometry?>(nil)

    public init() {}

    public var current: CaptureGeometry? { latest.value }

    public func record(_ geometry: CaptureGeometry?) {
        latest.value = geometry
    }
}

/// Draws a highlight and a label on screen for a few seconds. Display only: it can't click or type.
public protocol AnnotationPresenting: Sendable {
    func show(_ rect: CGRect, label: String) async
}

public struct NoAnnotationPresenter: AnnotationPresenting {
    public init() {}
    public func show(_ rect: CGRect, label: String) async {}
}

/// Lets Ivy point at something in the last screenshot it was shown. Safe: it only draws a temporary highlight;
/// it cannot click, type, move anything or take a new capture.
public final class PointAtTool: IvyTool, Sendable {
    public static let maxLabel = 60

    public let name = "point_at"
    public let description = "Highlights an area of the user's screen for a few seconds, with a short label, to show where something is. Coordinates are pixels in the most recent screenshot you were shown (origin top-left). It only draws; it cannot click or type."
    public let group = ToolGroup.core
    public let safetyClassification = ToolSafetyClassification.safe
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "x": ToolProperty(type: "INTEGER", description: "Left edge, in screenshot pixels."),
                "y": ToolProperty(type: "INTEGER", description: "Top edge, in screenshot pixels."),
                "width": ToolProperty(type: "INTEGER", description: "Width in pixels (at least 4)."),
                "height": ToolProperty(type: "INTEGER", description: "Height in pixels (at least 4)."),
                "label": ToolProperty(type: "STRING", description: "A few words shown next to the highlight, at most \(PointAtTool.maxLabel) characters."),
            ],
            required: ["x", "y", "width", "height", "label"]))
    }

    private let geometry: ScreenGeometryRelay
    private let presenter: AnnotationPresenting
    private let mainDisplayHeight: @Sendable () -> CGFloat

    public init(geometry: ScreenGeometryRelay, presenter: AnnotationPresenting = NoAnnotationPresenter(),
                mainDisplayHeight: @escaping @Sendable () -> CGFloat = { CGDisplayBounds(CGMainDisplayID()).height }) {
        self.geometry = geometry
        self.presenter = presenter
        self.mainDisplayHeight = mainDisplayHeight
    }

    func parse(_ arguments: [String: AnyCodable]) throws -> (rect: CGRect, label: String) {
        let args = ToolArguments(arguments)
        try args.allow(["x", "y", "width", "height", "label"])
        let (x, y, w, h) = (try args.int("x"), try args.int("y"), try args.int("width"), try args.int("height"))
        guard x >= 0, y >= 0, w >= 4, h >= 4, x <= 20_000, y <= 20_000, w <= 20_000, h <= 20_000 else {
            throw ToolError.invalidArgument("The area must be inside the screenshot, at least 4×4 pixels.")
        }
        return (CGRect(x: x, y: y, width: w, height: h), try args.string("label", max: Self.maxLabel))
    }

    public func validate(arguments: [String: AnyCodable]) throws {
        _ = try parse(arguments)
        guard geometry.current != nil else {
            throw ToolError.invalidArgument("There's no screenshot to point at. Ask the user to show you their screen (⌃⌥⌘S) first.")
        }
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        guard let geometry = geometry.current,
              let rect = geometry.screenRect(forImageRect: request.rect, mainDisplayHeight: mainDisplayHeight()) else {
            return .failure("That area isn't inside the last screenshot.")
        }
        await presenter.show(rect, label: request.label)
        return .success("Highlighted \"\(request.label)\" on the user's screen.", summary: "pointed at \(request.label)")
    }
}
