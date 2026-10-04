import Foundation
import CoreGraphics

/// Scope restricting computer control actions to an explicit target application and window.
public struct ComputerControlScope: Equatable, Sendable, Codable {
    public let bundleIdentifier: String
    public let processIdentifier: Int32?
    public let windowTitle: String?
    public let windowID: UInt32?
    public let displayID: UInt32?
    public var isAuthorized: Bool

    public init(
        bundleIdentifier: String,
        processIdentifier: Int32? = nil,
        windowTitle: String? = nil,
        windowID: UInt32? = nil,
        displayID: UInt32? = nil,
        isAuthorized: Bool = false
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.displayID = displayID
        self.isAuthorized = isAuthorized
    }

    /// Validates that target application is not a prohibited system or credential surface.
    public var isPermittedApp: Bool {
        let prohibited: Set<String> = [
            "com.apple.securityagent",
            "com.apple.coreauthui",
            "com.apple.keychain-access",
            "com.apple.passwords",
            "com.apple.systempreferences",
            "com.apple.systemsettings"
        ]
        return !prohibited.contains(bundleIdentifier.lowercased())
    }
}

/// Token validating that an observation belongs to the active session and has not expired or been superseded.
public struct ObservationToken: Equatable, Sendable, Codable, Hashable {
    public let id: UUID
    public let sessionID: UUID
    public let revision: Int
    public let createdAt: Date
    public let expiresAt: Date

    public init(sessionID: UUID, revision: Int, ttl: TimeInterval = 5.0, now: Date = Date()) {
        self.id = UUID()
        self.sessionID = sessionID
        self.revision = revision
        self.createdAt = now
        self.expiresAt = now.addingTimeInterval(ttl)
    }

    public func isValid(for session: UUID, at date: Date = Date()) -> Bool {
        sessionID == session && date <= expiresAt
    }
}

/// Kind of computer control primitive action.
public enum ComputerControlActionKind: String, Equatable, Sendable, Codable, CaseIterable {
    case observe = "ui_observe"
    case click = "ui_click"
    case type = "ui_type"
    case key = "ui_key"
    case scroll = "ui_scroll"
    case move = "ui_move"
    case drag = "ui_drag"
}

/// Mouse buttons supported by synthetic event execution.
public enum MouseButton: String, Equatable, Sendable, Codable {
    case left
    case right
    case middle
}

/// Target locator for an action: either a session-assigned element identifier, normalized screen coordinates, or screenshot visual coordinates.
public enum TargetLocation: Equatable, Sendable, Codable {
    case elementID(String)
    case point(x: Double, y: Double, displayID: UInt32?)
    case visualPoint(pixelX: Double, pixelY: Double, screenshotID: UUID)

    public var isValid: Bool {
        switch self {
        case .elementID(let id):
            return !id.trimmingCharacters(in: .whitespaces).isEmpty
        case .point(let x, let y, let displayID):
            guard x.isFinite && y.isFinite else { return false }
            if displayID == nil {
                return x >= 0 && y >= 0 && x <= 20_000 && y <= 20_000
            } else {
                return x >= -20_000 && y >= -20_000 && x <= 20_000 && y <= 20_000
            }
        case .visualPoint(let px, let py, _):
            return px.isFinite && py.isFinite && px >= 0 && py >= 0 && px <= 40_000 && py <= 40_000
        }
    }
}

/// Action to be dispatched through the safety gate and native driver.
public struct ComputerControlAction: Equatable, Sendable {
    public let kind: ComputerControlActionKind
    public let target: TargetLocation?
    public let text: String?
    public let button: MouseButton
    public let clickCount: Int
    public let deltaX: Double
    public let deltaY: Double
    public let token: ObservationToken?

    public init(
        kind: ComputerControlActionKind,
        target: TargetLocation? = nil,
        text: String? = nil,
        button: MouseButton = .left,
        clickCount: Int = 1,
        deltaX: Double = 0,
        deltaY: Double = 0,
        token: ObservationToken? = nil
    ) {
        self.kind = kind
        self.target = target
        self.text = text
        self.button = button
        self.clickCount = clickCount
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.token = token
    }
}

/// Snapshot of an accessible UI element inside the scoped window.
public struct UIElementSnapshot: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let role: String
    public let title: String?
    public let value: String?
    public let frame: CGRect
    public let isEnabled: Bool
    public let isFocused: Bool
    public let actions: [String]

    public init(
        id: String,
        role: String,
        title: String? = nil,
        value: String? = nil,
        frame: CGRect,
        isEnabled: Bool = true,
        isFocused: Bool = false,
        actions: [String] = []
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.value = value
        self.frame = frame
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.actions = actions
    }
}

/// Distinct observation types for accessibility tree inspection vs visual screenshot capture.
public enum DesktopObservationKind: String, Equatable, Sendable, Codable {
    case accessibilityTree = "accessibility_tree"
    case screenshotVisual = "screenshot_visual"
}

/// Metadata and coordinate mapping for a visual screenshot observation.
public struct ScreenshotMetadata: Equatable, Sendable, Codable {
    public let screenshotID: UUID
    public let windowID: UInt32?
    public let displayID: UInt32?
    public let dimensions: CGSize
    public let transform: ScreenshotCoordinateTransform
    public let createdAt: Date

    public init(
        screenshotID: UUID,
        windowID: UInt32? = nil,
        displayID: UInt32? = nil,
        dimensions: CGSize,
        transform: ScreenshotCoordinateTransform,
        createdAt: Date = Date()
    ) {
        self.screenshotID = screenshotID
        self.windowID = windowID
        self.displayID = displayID
        self.dimensions = dimensions
        self.transform = transform
        self.createdAt = createdAt
    }
}

/// Scoped desktop observation containing accessible elements and optional visual frame metadata.
public struct DesktopObservation: Equatable, Sendable {
    public let sessionID: UUID
    public let token: ObservationToken
    public let scope: ComputerControlScope
    public let elements: [UIElementSnapshot]
    public let screenshotID: UUID?
    public let kind: DesktopObservationKind
    public let visualMetadata: ScreenshotMetadata?
    public let imageData: Data?
    public let timestamp: Date

    public init(
        sessionID: UUID,
        token: ObservationToken,
        scope: ComputerControlScope,
        elements: [UIElementSnapshot] = [],
        screenshotID: UUID? = nil,
        kind: DesktopObservationKind = .accessibilityTree,
        visualMetadata: ScreenshotMetadata? = nil,
        imageData: Data? = nil,
        timestamp: Date = Date()
    ) {
        self.sessionID = sessionID
        self.token = token
        self.scope = scope
        self.elements = elements
        self.screenshotID = screenshotID ?? visualMetadata?.screenshotID
        self.kind = kind
        self.visualMetadata = visualMetadata
        self.imageData = imageData
        self.timestamp = timestamp
    }
}

/// Reasons why an active control session may be paused.
public enum ComputerControlPauseReason: String, Equatable, Sendable, Codable {
    case userTakeover = "User moved mouse or typed"
    case focusLost = "Target window lost focus"
    case permissionRevoked = "Accessibility or screen permission unavailable"
    case budgetExhausted = "Action limit or timeout reached"
    case staleTarget = "Target elements changed or moved"
    case userRequested = "Session paused by user"
}

/// Lifecycle states of a computer control session.
public enum ComputerControlSessionState: Equatable, Sendable {
    case idle
    case requested(goal: String, scope: ComputerControlScope)
    case active(goal: String, scope: ComputerControlScope, token: ObservationToken)
    case paused(goal: String, scope: ComputerControlScope, reason: ComputerControlPauseReason)
    case completed(goal: String, summary: String)
    case cancelled(goal: String, reason: String)
    case failed(goal: String, error: String)

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }

    public var currentScope: ComputerControlScope? {
        switch self {
        case .requested(_, let scope), .active(_, let scope, _), .paused(_, let scope, _):
            return scope
        case .idle, .completed, .cancelled, .failed:
            return nil
        }
    }
}
