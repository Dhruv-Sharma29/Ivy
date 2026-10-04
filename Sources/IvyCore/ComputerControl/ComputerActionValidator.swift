import Foundation
import CoreGraphics

/// Validates computer control targets, coordinates, input payloads, and session authority.
public enum ComputerActionValidator {
    /// Maximum allowed length for typed text payloads.
    public static let maxTextLength = 2_000

    /// Maximum allowed coordinate value in points for any display.
    public static let maxCoordinate = 20_000.0

    /// Maximum number of simultaneous modifier keys.
    public static let maxModifiers = 4

    /// Maximum scroll delta in pixels per action.
    public static let maxScrollDelta = 5_000.0

    /// Prohibited control scalar ranges (null bytes and unhandled control characters).
    private static let allowedControlScalars: Set<Unicode.Scalar> = ["\n", "\t", "\r"]

    /// Validates that target coordinates are finite and within screen/display limits.
    public static func validatePoint(
        _ point: CGPoint,
        allowedBounds: CGRect? = nil,
        allowNegativeOrigin: Bool = false
    ) throws {
        guard point.x.isFinite && point.y.isFinite else {
            throw ComputerInputError.invalidCoordinates(x: point.x, y: point.y)
        }
        if let allowedBounds {
            let expanded = allowedBounds.insetBy(dx: -1.0, dy: -1.0)
            guard expanded.contains(point) else {
                throw ComputerInputError.invalidCoordinates(x: point.x, y: point.y)
            }
            return
        }
        if allowNegativeOrigin {
            guard abs(point.x) <= maxCoordinate && abs(point.y) <= maxCoordinate else {
                throw ComputerInputError.invalidCoordinates(x: point.x, y: point.y)
            }
        } else {
            guard point.x >= 0 && point.y >= 0 &&
                  point.x <= maxCoordinate && point.y <= maxCoordinate else {
                throw ComputerInputError.invalidCoordinates(x: point.x, y: point.y)
            }
        }
    }

    /// Validates scroll deltas.
    public static func validateScrollDelta(x: Double, y: Double) throws {
        guard x.isFinite && y.isFinite &&
              abs(x) <= maxScrollDelta && abs(y) <= maxScrollDelta else {
            throw ComputerInputError.invalidArgument("Scroll delta (\(x), \(y)) is invalid or exceeds max delta of \(maxScrollDelta)")
        }
    }

    /// Validates a text payload intended for typing.
    public static func validateText(_ text: String) throws {
        guard !text.isEmpty else {
            throw ComputerInputError.invalidArgument("Typed text cannot be empty.")
        }
        guard text.count <= maxTextLength else {
            throw ComputerInputError.textTooLong(count: text.count, limit: maxTextLength)
        }
        for scalar in text.unicodeScalars {
            if scalar.value == 0 {
                throw ComputerInputError.invalidArgument("Typed text contains invalid null byte.")
            }
            if CharacterSet.controlCharacters.contains(scalar) && !allowedControlScalars.contains(scalar) {
                throw ComputerInputError.invalidArgument("Typed text contains prohibited control characters.")
            }
        }
    }

    /// Resolves a target location into a verified screen coordinate.
    public static func resolveTarget(
        _ target: TargetLocation,
        session: ComputerControlSession,
        observation: DesktopObservation?
    ) throws -> CGPoint {
        guard session.state.isActive else {
            throw ComputerInputError.sessionNotActive
        }

        switch target {
        case .point(let x, let y, let displayID):
            let pt = CGPoint(x: x, y: y)
            let allowNegative = displayID != nil
            if let visual = observation?.visualMetadata {
                try validatePoint(pt, allowedBounds: visual.transform.windowFrame, allowNegativeOrigin: allowNegative)
            } else {
                try validatePoint(pt, allowNegativeOrigin: allowNegative)
            }
            return pt

        case .visualPoint(let px, let py, let shotID):
            guard let observation, let visualMeta = observation.visualMetadata, visualMeta.screenshotID == shotID else {
                throw ComputerInputError.targetNotFound("screenshot_\(shotID.uuidString.prefix(8))")
            }
            do {
                return try visualMeta.transform.pixelToGlobalPoint(pixelPoint: CGPoint(x: px, y: py))
            } catch {
                if let xfErr = error as? ScreenshotTransformError {
                    switch xfErr {
                    case .coordinatesOutOfBounds(let ox, let oy), .pointOutsideWindow(let ox, let oy, _):
                        throw ComputerInputError.invalidCoordinates(x: ox, y: oy)
                    default:
                        throw ComputerInputError.invalidArgument(xfErr.localizedDescription)
                    }
                }
                throw ComputerInputError.invalidArgument(error.localizedDescription)
            }

        case .elementID(let id):
            guard let observation else {
                throw ComputerInputError.targetNotFound(id)
            }
            guard let element = observation.elements.first(where: { $0.id == id }) else {
                throw ComputerInputError.targetNotFound(id)
            }
            guard element.isEnabled else {
                throw ComputerInputError.targetDisabled(id)
            }
            guard element.role != "AXSecureTextField" else {
                throw ComputerInputError.targetNotPermitted(id)
            }

            let center = CGPoint(x: element.frame.midX, y: element.frame.midY)
            let allowNegative = element.frame.origin.x < 0 || element.frame.origin.y < 0
            try validatePoint(center, allowNegativeOrigin: allowNegative)
            return center
        }
    }
}
