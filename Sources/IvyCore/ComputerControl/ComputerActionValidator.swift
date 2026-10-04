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

    /// Validates that target coordinates are finite, non-negative, and within screen limits.
    public static func validatePoint(_ point: CGPoint) throws {
        guard point.x.isFinite && point.y.isFinite &&
              point.x >= 0 && point.y >= 0 &&
              point.x <= maxCoordinate && point.y <= maxCoordinate else {
            throw ComputerInputError.invalidCoordinates(x: point.x, y: point.y)
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
        case .point(let x, let y, _):
            let pt = CGPoint(x: x, y: y)
            try validatePoint(pt)
            return pt

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
            try validatePoint(center)
            return center
        }
    }
}
