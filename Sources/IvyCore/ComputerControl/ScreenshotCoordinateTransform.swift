import Foundation
import CoreGraphics

/// Errors occurring during coordinate transformations between screenshots and display surfaces.
public enum ScreenshotTransformError: Error, LocalizedError, Equatable, Sendable {
    case coordinatesOutOfBounds(x: Double, y: Double)
    case nonFiniteCoordinates
    case pointOutsideWindow(x: Double, y: Double, windowFrame: CGRect)
    case targetDisplaced(displacement: Double)
    case invalidDisplayBounds
    case crossDisplayTargetingProhibited(point: CGPoint, displayBounds: CGRect)

    public var errorDescription: String? {
        switch self {
        case .coordinatesOutOfBounds(let x, let y):
            return "Screenshot coordinates (\(x), \(y)) are out of image bounds."
        case .nonFiniteCoordinates:
            return "Screenshot coordinates must be finite, valid numbers."
        case .pointOutsideWindow(let x, let y, let frame):
            return "Resolved screen point (\(Int(x)), \(Int(y))) falls outside target window bounds (\(Int(frame.origin.x)), \(Int(frame.origin.y)), \(Int(frame.width))x\(Int(frame.height)))."
        case .targetDisplaced(let d):
            return "Target window moved by \(Int(d))pt since capture; screenshot coordinates invalidated."
        case .invalidDisplayBounds:
            return "Specified display bounds are invalid or empty."
        case .crossDisplayTargetingProhibited(let pt, let bounds):
            return "Target point (\(Int(pt.x)), \(Int(pt.y))) falls outside authorized display bounds (\(Int(bounds.origin.x)), \(Int(bounds.origin.y)), \(Int(bounds.width))x\(Int(bounds.height)))."
        }
    }
}

/// Transform mapping coordinates between screenshot pixel space and global display point space.
///
/// Handles:
/// - Display scaling (e.g. 2.0x Retina, standard 1.0x).
/// - Window-relative offsets to Quartz/CoreGraphics global screen coordinates.
/// - Secondary displays with negative origins (e.g. monitor placed to the left or above).
/// - Window movement displacement invalidation.
public struct ScreenshotCoordinateTransform: Equatable, Sendable, Codable {
    /// Target window frame in global display points (Quartz top-left origin).
    public let windowFrame: CGRect
    /// Physical pixel dimensions of the captured screenshot.
    public let imageSize: CGSize
    /// Display scale factor (e.g. 2.0 for Retina, 1.0 for non-Retina).
    public let scaleFactor: CGFloat
    /// Quartz DirectDisplay identifier for the window's host display.
    public let displayID: UInt32?
    /// Global bounds of the hosting display, if known.
    public let displayBounds: CGRect?

    public init(
        windowFrame: CGRect,
        imageSize: CGSize,
        scaleFactor: CGFloat = 2.0,
        displayID: UInt32? = nil,
        displayBounds: CGRect? = nil
    ) {
        self.windowFrame = windowFrame
        self.imageSize = imageSize
        self.scaleFactor = scaleFactor > 0 ? scaleFactor : 1.0
        self.displayID = displayID
        self.displayBounds = displayBounds
    }

    /// Converts physical screenshot pixel coordinates to global display points.
    public func pixelToGlobalPoint(pixelPoint: CGPoint) throws -> CGPoint {
        guard pixelPoint.x.isFinite && pixelPoint.y.isFinite else {
            throw ScreenshotTransformError.nonFiniteCoordinates
        }
        guard pixelPoint.x >= 0 && pixelPoint.y >= 0 &&
              pixelPoint.x <= imageSize.width && pixelPoint.y <= imageSize.height else {
            throw ScreenshotTransformError.coordinatesOutOfBounds(x: pixelPoint.x, y: pixelPoint.y)
        }

        let winRelX = pixelPoint.x / scaleFactor
        let winRelY = pixelPoint.y / scaleFactor
        let globalX = windowFrame.minX + winRelX
        let globalY = windowFrame.minY + winRelY
        let globalPt = CGPoint(x: globalX, y: globalY)

        // Strict containment check inside window (with 1pt rounding tolerance)
        let expandedWindow = windowFrame.insetBy(dx: -1.0, dy: -1.0)
        guard expandedWindow.contains(globalPt) else {
            throw ScreenshotTransformError.pointOutsideWindow(x: globalX, y: globalY, windowFrame: windowFrame)
        }

        // Display bounds check if present
        if let displayBounds {
            let expandedDisplay = displayBounds.insetBy(dx: -1.0, dy: -1.0)
            guard expandedDisplay.contains(globalPt) else {
                throw ScreenshotTransformError.crossDisplayTargetingProhibited(point: globalPt, displayBounds: displayBounds)
            }
        }

        return globalPt
    }

    /// Converts normalized [0.0...1.0] screenshot coordinates to global display points.
    public func normalizedToGlobalPoint(normalizedPoint: CGPoint) throws -> CGPoint {
        guard normalizedPoint.x.isFinite && normalizedPoint.y.isFinite else {
            throw ScreenshotTransformError.nonFiniteCoordinates
        }
        guard normalizedPoint.x >= 0.0 && normalizedPoint.x <= 1.0 &&
              normalizedPoint.y >= 0.0 && normalizedPoint.y <= 1.0 else {
            throw ScreenshotTransformError.coordinatesOutOfBounds(x: normalizedPoint.x, y: normalizedPoint.y)
        }

        let pixelX = normalizedPoint.x * imageSize.width
        let pixelY = normalizedPoint.y * imageSize.height
        return try pixelToGlobalPoint(pixelPoint: CGPoint(x: pixelX, y: pixelY))
    }

    /// Converts global display points back to physical screenshot pixel coordinates (inverse transform).
    public func globalToPixelPoint(globalPoint: CGPoint) throws -> CGPoint {
        guard globalPoint.x.isFinite && globalPoint.y.isFinite else {
            throw ScreenshotTransformError.nonFiniteCoordinates
        }
        let expandedWindow = windowFrame.insetBy(dx: -1.0, dy: -1.0)
        guard expandedWindow.contains(globalPoint) else {
            throw ScreenshotTransformError.pointOutsideWindow(x: globalPoint.x, y: globalPoint.y, windowFrame: windowFrame)
        }

        let winRelX = globalPoint.x - windowFrame.minX
        let winRelY = globalPoint.y - windowFrame.minY
        let pixelX = winRelX * scaleFactor
        let pixelY = winRelY * scaleFactor

        return CGPoint(x: pixelX, y: pixelY)
    }

    /// Verifies that the target window has not moved or resized materially since capture.
    public func verifyWindowStability(currentWindowFrame: CGRect, maxDisplacement: Double = 10.0) throws {
        let dx = currentWindowFrame.origin.x - windowFrame.origin.x
        let dy = currentWindowFrame.origin.y - windowFrame.origin.y
        let dw = currentWindowFrame.size.width - windowFrame.size.width
        let dh = currentWindowFrame.size.height - windowFrame.size.height

        let displacement = hypot(dx, dy)
        let sizeChange = hypot(dw, dh)
        let totalDelta = max(displacement, sizeChange)

        guard totalDelta <= maxDisplacement else {
            throw ScreenshotTransformError.targetDisplaced(displacement: totalDelta)
        }
    }
}

/// Security utility detecting adversarial webpage prompt injection and preserving goal isolation.
public enum UntrustedPageSecurity {
    /// Known prompt injection signatures commonly found in adversarial web content.
    private static let injectionSignatures: [String] = [
        "ignore previous instructions",
        "ignore all previous instructions",
        "forget your instructions",
        "forget all previous",
        "system override",
        "new system prompt",
        "developer mode enabled",
        "approved by user",
        "safetygate bypass",
        "action pre-approved",
        "admin consent granted",
        "execute shell",
        "open terminal",
        "run terminal"
    ]

    /// Result of analyzing webpage text for adversarial prompt injection.
    public struct Assessment: Equatable, Sendable {
        public let containsSuspiciousContent: Bool
        public let flaggedKeywords: [String]

        public init(containsSuspiciousContent: Bool, flaggedKeywords: [String]) {
            self.containsSuspiciousContent = containsSuspiciousContent
            self.flaggedKeywords = flaggedKeywords
        }
    }

    /// Analyzes text content from a webpage or UI element snapshot for prompt injection patterns.
    public static func analyzeText(_ text: String) -> Assessment {
        let lower = text.lowercased()
        var found: [String] = []
        for sig in injectionSignatures {
            if lower.contains(sig) {
                found.append(sig)
            }
        }
        return Assessment(
            containsSuspiciousContent: !found.isEmpty,
            flaggedKeywords: found
        )
    }

    /// Sanitizes an element's visible text for LLM prompt context to clearly tag untrusted page text.
    public static func formatElementForPrompt(_ element: UIElementSnapshot) -> String {
        var desc = "- [\(element.id)] \(element.role)"
        if let t = element.title, !t.isEmpty {
            let assessment = analyzeText(t)
            let safeTitle = assessment.containsSuspiciousContent ? "[UNTRUSTED_CONTENT: \(t)]" : t
            desc += " title=\"\(safeTitle)\""
        }
        if let v = element.value, !v.isEmpty {
            let assessment = analyzeText(v)
            let safeValue = assessment.containsSuspiciousContent ? "[UNTRUSTED_CONTENT: \(v)]" : v
            desc += " value=\"\(safeValue.prefix(50))\""
        }
        desc += " bounds=(\(Int(element.frame.origin.x)),\(Int(element.frame.origin.y)),\(Int(element.frame.width))x\(Int(element.frame.height)))"
        if !element.isEnabled { desc += " [disabled]" }
        if element.isFocused { desc += " [focused]" }
        return desc
    }
}
