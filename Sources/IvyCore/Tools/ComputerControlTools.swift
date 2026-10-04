import Foundation
import CoreGraphics

// MARK: - Factory & Group

/// Namespace for registering computer control primitive tools.
public enum ComputerControlTools {
    /// Returns the full set of primitive computer control tools.
    public static func all(
        session: ComputerControlSession,
        driver: ComputerInputDriving = SystemComputerInputDriver(),
        observationProvider: (any DesktopObservationProviding)? = nil
    ) -> [IvyTool] {
        [
            UIClickTool(session: session, driver: driver, observationProvider: observationProvider),
            UITypeTool(session: session, driver: driver, observationProvider: observationProvider),
            UIKeyTool(session: session, driver: driver),
            UIScrollTool(session: session, driver: driver),
            UIMoveTool(session: session, driver: driver),
            UIDragTool(session: session, driver: driver),
            UIObserveTool(session: session, observationProvider: observationProvider)
        ]
    }
}

// MARK: - ui_click

/// Synthesizes a mouse click at target coordinates or an accessibility element.
public final class UIClickTool: IvyTool, Sendable {
    public let name = "ui_click"
    public let description = "Clicks at coordinates or a target element in the active application window."
    public let group = ToolGroup.system
    public let safetyClassification = ToolSafetyClassification.risky

    public var declaration: FunctionDeclaration {
        FunctionDeclaration(
            name: name,
            description: description,
            parameters: ToolParameters(
                properties: [
                    "x": ToolProperty(type: "NUMBER", description: "X coordinate in screen points."),
                    "y": ToolProperty(type: "NUMBER", description: "Y coordinate in screen points."),
                    "element_id": ToolProperty(type: "STRING", description: "Target accessibility element ID from observation."),
                    "button": ToolProperty(type: "STRING", description: "Mouse button: 'left', 'right', or 'middle'. Default is 'left'."),
                    "click_count": ToolProperty(type: "INTEGER", description: "1 for single click, 2 for double click. Default is 1."),
                    "token": ToolProperty(type: "STRING", description: "Observation token ID returned by ui_observe.")
                ],
                required: []
            )
        )
    }

    private let session: ComputerControlSession
    private let driver: ComputerInputDriving
    private let observationProvider: (any DesktopObservationProviding)?

    public init(
        session: ComputerControlSession,
        driver: ComputerInputDriving = SystemComputerInputDriver(),
        observationProvider: (any DesktopObservationProviding)? = nil
    ) {
        self.session = session
        self.driver = driver
        self.observationProvider = observationProvider
    }

    public func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType] {
        [.accessibility]
    }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        let (targetDesc, button, count) = parseConfirmationInfo(arguments)
        let app = session.state.currentScope?.bundleIdentifier ?? "active application"
        return ToolConfirmation(
            title: "Mouse Click",
            prompt: "Ivy is about to click \(targetDesc) in \(app). Do it or chicken out?",
            detail: "Action: Click\nButton: \(button)\nClick Count: \(count)\nTarget: \(targetDesc)\nApplication: \(app)"
        )
    }

    private func parseConfirmationInfo(_ arguments: [String: AnyCodable]) -> (target: String, button: String, count: Int) {
        let button = arguments["button"]?.stringValue?.lowercased() ?? "left"
        let count = arguments["click_count"]?.intValue ?? 1
        if let id = arguments["element_id"]?.stringValue {
            return ("element '\(id)'", button, count)
        }
        if let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue {
            return ("at (\(Int(x)), \(Int(y)))", button, count)
        }
        return ("at target location", button, count)
    }

    public func validate(arguments: [String: AnyCodable]) throws {
        let hasCoords = arguments["x"]?.doubleValue != nil && arguments["y"]?.doubleValue != nil
        let hasElement = arguments["element_id"]?.stringValue != nil
        guard hasCoords || hasElement else {
            throw ToolError.invalidArgument("Either (x, y) coordinates or an element_id must be provided.")
        }
        if let count = arguments["click_count"]?.intValue {
            guard count == 1 || count == 2 else {
                throw ToolError.invalidArgument("click_count must be 1 (single) or 2 (double).")
            }
        }
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard session.state.isActive else {
            return .failure("Computer control session is not active.")
        }
        guard driver.isAuthorized else {
            return .failure("Accessibility permission is required for computer control input, but is not currently granted.")
        }

        let buttonStr = arguments["button"]?.stringValue?.lowercased() ?? "left"
        let button = MouseButton(rawValue: buttonStr) ?? .left
        let clickCount = arguments["click_count"]?.intValue ?? 1

        let target: TargetLocation
        if let elementID = arguments["element_id"]?.stringValue {
            target = .elementID(elementID)
        } else if let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue {
            target = .point(x: x, y: y, displayID: nil)
        } else {
            return .failure("Target coordinates or element_id required.")
        }

        let resolvedPoint: CGPoint
        do {
            let obs: DesktopObservation?
            if case .elementID = target, let provider = observationProvider, let scope = session.state.currentScope {
                obs = try? await provider.observe(session: session, scope: scope)
            } else {
                obs = nil
            }
            resolvedPoint = try ComputerActionValidator.resolveTarget(target, session: session, observation: obs)
        } catch {
            return .failure(error.localizedDescription)
        }

        let token = session.currentToken
        let action = ComputerControlAction(kind: .click, target: target, button: button, clickCount: clickCount, token: token)
        let recordResult = session.recordAction(action)
        if case .failure(let err) = recordResult {
            return .failure("Cannot execute click: \(err.localizedDescription)")
        }

        do {
            try await driver.click(at: resolvedPoint, button: button, clickCount: clickCount)
            return .success("Clicked at (\(Int(resolvedPoint.x)), \(Int(resolvedPoint.y))) with \(button.rawValue) button.")
        } catch {
            return .failure("Click failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - ui_type

/// Synthesizes keyboard text entry into the active target.
public final class UITypeTool: IvyTool, Sendable {
    public let name = "ui_type"
    public let description = "Types text into the active application window."
    public let group = ToolGroup.system
    public let safetyClassification = ToolSafetyClassification.risky

    public var declaration: FunctionDeclaration {
        FunctionDeclaration(
            name: name,
            description: description,
            parameters: ToolParameters(
                properties: [
                    "text": ToolProperty(type: "STRING", description: "Text string to type into the focused field."),
                    "element_id": ToolProperty(type: "STRING", description: "Optional element ID to focus before typing.")
                ],
                required: ["text"]
            )
        )
    }

    private let session: ComputerControlSession
    private let driver: ComputerInputDriving
    private let observationProvider: (any DesktopObservationProviding)?

    public init(
        session: ComputerControlSession,
        driver: ComputerInputDriving = SystemComputerInputDriver(),
        observationProvider: (any DesktopObservationProviding)? = nil
    ) {
        self.session = session
        self.driver = driver
        self.observationProvider = observationProvider
    }

    public func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType] {
        [.accessibility]
    }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        let text = arguments["text"]?.stringValue ?? ""
        let preview = text.count > 40 ? "\(text.prefix(40))..." : text
        let app = session.state.currentScope?.bundleIdentifier ?? "active application"
        return ToolConfirmation(
            title: "Type Text",
            prompt: "Ivy is about to type \(text.count) characters into \(app). Do it or chicken out?",
            detail: "Action: Type Text\nLength: \(text.count) characters\nPreview: \"\(preview)\"\nApplication: \(app)"
        )
    }

    public func validate(arguments: [String: AnyCodable]) throws {
        guard let text = arguments["text"]?.stringValue else {
            throw ToolError.missingArgument("text")
        }
        try ComputerActionValidator.validateText(text)
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard session.state.isActive else {
            return .failure("Computer control session is not active.")
        }
        guard driver.isAuthorized else {
            return .failure("Accessibility permission is required for computer control input, but is not currently granted.")
        }
        guard let text = arguments["text"]?.stringValue else {
            return .failure("Missing required 'text' argument.")
        }

        // If target element is specified, focus it before typing
        if let elementID = arguments["element_id"]?.stringValue {
            let obs: DesktopObservation?
            if let provider = observationProvider, let scope = session.state.currentScope {
                obs = try? await provider.observe(session: session, scope: scope)
            } else {
                obs = nil
            }
            if let targetPoint = try? ComputerActionValidator.resolveTarget(.elementID(elementID), session: session, observation: obs) {
                try? await driver.click(at: targetPoint, button: .left, clickCount: 1)
            }
        }

        let token = session.currentToken
        let action = ComputerControlAction(kind: .type, text: text, token: token)
        let recordResult = session.recordAction(action)
        if case .failure(let err) = recordResult {
            return .failure("Cannot execute typing: \(err.localizedDescription)")
        }

        do {
            try await driver.type(text: text)
            return .success("Typed \(text.count) characters into the active application.")
        } catch {
            return .failure("Typing failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - ui_key

/// Synthesizes single key or modifier key combination presses.
public final class UIKeyTool: IvyTool, Sendable {
    public let name = "ui_key"
    public let description = "Presses a key or key combination with modifiers in the active application window."
    public let group = ToolGroup.system
    public let safetyClassification = ToolSafetyClassification.risky

    public var declaration: FunctionDeclaration {
        FunctionDeclaration(
            name: name,
            description: description,
            parameters: ToolParameters(
                properties: [
                    "key": ToolProperty(type: "STRING", description: "Key name (e.g. 'return', 'tab', 'escape', 'space', 'up', 'down', 'a')."),
                    "modifiers": ToolProperty(type: "ARRAY", description: "Modifier keys: 'command', 'shift', 'option', 'control'.")
                ],
                required: ["key"]
            )
        )
    }

    private let session: ComputerControlSession
    private let driver: ComputerInputDriving

    public init(session: ComputerControlSession, driver: ComputerInputDriving = SystemComputerInputDriver()) {
        self.session = session
        self.driver = driver
    }

    public func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType] {
        [.accessibility]
    }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        let key = arguments["key"]?.stringValue ?? "(none)"
        let modifiers = parseModifiers(arguments)
        let combo = modifiers.isEmpty ? key : "\(modifiers.joined(separator: " + ")) + \(key)"
        let app = session.state.currentScope?.bundleIdentifier ?? "active application"
        return ToolConfirmation(
            title: "Press Key",
            prompt: "Ivy is about to press key combination '\(combo)' in \(app). Do it or chicken out?",
            detail: "Action: Key Press\nCombination: \(combo)\nApplication: \(app)"
        )
    }

    private func parseModifiers(_ arguments: [String: AnyCodable]) -> [String] {
        guard let arr = arguments["modifiers"]?.arrayValue else { return [] }
        return arr.compactMap { $0.stringValue?.lowercased() }
    }

    public func validate(arguments: [String: AnyCodable]) throws {
        guard let key = arguments["key"]?.stringValue, !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ToolError.missingArgument("key")
        }
        let modifiers = parseModifiers(arguments)
        guard modifiers.count <= ComputerActionValidator.maxModifiers else {
            throw ToolError.invalidArgument("Too many modifiers: maximum allowed is \(ComputerActionValidator.maxModifiers).")
        }
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard session.state.isActive else {
            return .failure("Computer control session is not active.")
        }
        guard driver.isAuthorized else {
            return .failure("Accessibility permission is required for computer control input, but is not currently granted.")
        }
        guard let key = arguments["key"]?.stringValue else {
            return .failure("Missing required 'key' argument.")
        }
        let modifiers = parseModifiers(arguments)

        let token = session.currentToken
        let action = ComputerControlAction(kind: .key, text: key, token: token)
        let recordResult = session.recordAction(action)
        if case .failure(let err) = recordResult {
            return .failure("Cannot execute key press: \(err.localizedDescription)")
        }

        do {
            try await driver.pressKey(key: key, modifiers: modifiers)
            let combo = modifiers.isEmpty ? key : "\(modifiers.joined(separator: " + ")) + \(key)"
            return .success("Pressed key combination '\(combo)'.")
        } catch {
            return .failure("Key press failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - ui_scroll

/// Synthesizes mouse scroll wheel motion.
public final class UIScrollTool: IvyTool, Sendable {
    public let name = "ui_scroll"
    public let description = "Scrolls the active window vertically or horizontally."
    public let group = ToolGroup.system
    public let safetyClassification = ToolSafetyClassification.risky

    public var declaration: FunctionDeclaration {
        FunctionDeclaration(
            name: name,
            description: description,
            parameters: ToolParameters(
                properties: [
                    "delta_y": ToolProperty(type: "NUMBER", description: "Vertical scroll amount in points (positive scrolls up, negative scrolls down)."),
                    "delta_x": ToolProperty(type: "NUMBER", description: "Horizontal scroll amount in points."),
                    "x": ToolProperty(type: "NUMBER", description: "Optional X coordinate where scroll should occur."),
                    "y": ToolProperty(type: "NUMBER", description: "Optional Y coordinate where scroll should occur.")
                ],
                required: ["delta_y"]
            )
        )
    }

    private let session: ComputerControlSession
    private let driver: ComputerInputDriving

    public init(session: ComputerControlSession, driver: ComputerInputDriving = SystemComputerInputDriver()) {
        self.session = session
        self.driver = driver
    }

    public func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType] {
        [.accessibility]
    }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        let deltaY = arguments["delta_y"]?.doubleValue ?? 0
        let deltaX = arguments["delta_x"]?.doubleValue ?? 0
        let app = session.state.currentScope?.bundleIdentifier ?? "active application"
        return ToolConfirmation(
            title: "Scroll Window",
            prompt: "Ivy is about to scroll the active window in \(app). Do it or chicken out?",
            detail: "Action: Scroll\nDelta Y: \(Int(deltaY))\nDelta X: \(Int(deltaX))\nApplication: \(app)"
        )
    }

    public func validate(arguments: [String: AnyCodable]) throws {
        guard let deltaY = arguments["delta_y"]?.doubleValue else {
            throw ToolError.missingArgument("delta_y")
        }
        let deltaX = arguments["delta_x"]?.doubleValue ?? 0
        try ComputerActionValidator.validateScrollDelta(x: deltaX, y: deltaY)
        if let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue {
            try ComputerActionValidator.validatePoint(CGPoint(x: x, y: y))
        }
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard session.state.isActive else {
            return .failure("Computer control session is not active.")
        }
        guard driver.isAuthorized else {
            return .failure("Accessibility permission is required for computer control input, but is not currently granted.")
        }
        guard let deltaY = arguments["delta_y"]?.doubleValue else {
            return .failure("Missing required 'delta_y' argument.")
        }
        let deltaX = arguments["delta_x"]?.doubleValue ?? 0

        let point: CGPoint?
        if let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue {
            point = CGPoint(x: x, y: y)
        } else {
            point = nil
        }

        let token = session.currentToken
        let action = ComputerControlAction(kind: .scroll, deltaX: deltaX, deltaY: deltaY, token: token)
        let recordResult = session.recordAction(action)
        if case .failure(let err) = recordResult {
            return .failure("Cannot execute scroll: \(err.localizedDescription)")
        }

        do {
            try await driver.scroll(at: point, deltaX: deltaX, deltaY: deltaY)
            return .success("Scrolled by delta (x: \(Int(deltaX)), y: \(Int(deltaY))).")
        } catch {
            return .failure("Scroll failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - ui_move

/// Synthesizes mouse pointer movement to screen coordinates.
public final class UIMoveTool: IvyTool, Sendable {
    public let name = "ui_move"
    public let description = "Moves the mouse cursor to specific coordinates in the active application window."
    public let group = ToolGroup.system
    public let safetyClassification = ToolSafetyClassification.risky

    public var declaration: FunctionDeclaration {
        FunctionDeclaration(
            name: name,
            description: description,
            parameters: ToolParameters(
                properties: [
                    "x": ToolProperty(type: "NUMBER", description: "Target X coordinate in screen points."),
                    "y": ToolProperty(type: "NUMBER", description: "Target Y coordinate in screen points.")
                ],
                required: ["x", "y"]
            )
        )
    }

    private let session: ComputerControlSession
    private let driver: ComputerInputDriving

    public init(session: ComputerControlSession, driver: ComputerInputDriving = SystemComputerInputDriver()) {
        self.session = session
        self.driver = driver
    }

    public func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType] {
        [.accessibility]
    }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        let x = arguments["x"]?.doubleValue ?? 0
        let y = arguments["y"]?.doubleValue ?? 0
        return ToolConfirmation(
            title: "Move Cursor",
            prompt: "Ivy is about to move the mouse cursor to (\(Int(x)), \(Int(y))). Do it or chicken out?",
            detail: "Action: Move Cursor\nTarget: (\(Int(x)), \(Int(y)))"
        )
    }

    public func validate(arguments: [String: AnyCodable]) throws {
        guard let x = arguments["x"]?.doubleValue else { throw ToolError.missingArgument("x") }
        guard let y = arguments["y"]?.doubleValue else { throw ToolError.missingArgument("y") }
        try ComputerActionValidator.validatePoint(CGPoint(x: x, y: y))
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard session.state.isActive else {
            return .failure("Computer control session is not active.")
        }
        guard driver.isAuthorized else {
            return .failure("Accessibility permission is required for computer control input, but is not currently granted.")
        }
        guard let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue else {
            return .failure("Missing required coordinates (x, y).")
        }

        let point = CGPoint(x: x, y: y)
        let token = session.currentToken
        let action = ComputerControlAction(kind: .move, target: .point(x: x, y: y, displayID: nil), token: token)
        let recordResult = session.recordAction(action)
        if case .failure(let err) = recordResult {
            return .failure("Cannot execute move: \(err.localizedDescription)")
        }

        do {
            try await driver.move(to: point)
            return .success("Moved cursor to (\(Int(x)), \(Int(y))).")
        } catch {
            return .failure("Move cursor failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - ui_drag

/// Synthesizes a mouse drag from start coordinates to end coordinates.
public final class UIDragTool: IvyTool, Sendable {
    public let name = "ui_drag"
    public let description = "Drags the mouse from start coordinates to end coordinates."
    public let group = ToolGroup.system
    public let safetyClassification = ToolSafetyClassification.risky

    public var declaration: FunctionDeclaration {
        FunctionDeclaration(
            name: name,
            description: description,
            parameters: ToolParameters(
                properties: [
                    "start_x": ToolProperty(type: "NUMBER", description: "Start X coordinate."),
                    "start_y": ToolProperty(type: "NUMBER", description: "Start Y coordinate."),
                    "end_x": ToolProperty(type: "NUMBER", description: "End X coordinate."),
                    "end_y": ToolProperty(type: "NUMBER", description: "End Y coordinate."),
                    "button": ToolProperty(type: "STRING", description: "Mouse button ('left' or 'right', default 'left').")
                ],
                required: ["start_x", "start_y", "end_x", "end_y"]
            )
        )
    }

    private let session: ComputerControlSession
    private let driver: ComputerInputDriving

    public init(session: ComputerControlSession, driver: ComputerInputDriving = SystemComputerInputDriver()) {
        self.session = session
        self.driver = driver
    }

    public func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType] {
        [.accessibility]
    }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        let sx = arguments["start_x"]?.doubleValue ?? 0
        let sy = arguments["start_y"]?.doubleValue ?? 0
        let ex = arguments["end_x"]?.doubleValue ?? 0
        let ey = arguments["end_y"]?.doubleValue ?? 0
        return ToolConfirmation(
            title: "Drag and Drop",
            prompt: "Ivy is about to drag from (\(Int(sx)), \(Int(sy))) to (\(Int(ex)), \(Int(ey))). Do it or chicken out?",
            detail: "Action: Drag\nStart: (\(Int(sx)), \(Int(sy)))\nEnd: (\(Int(ex)), \(Int(ey)))"
        )
    }

    public func validate(arguments: [String: AnyCodable]) throws {
        guard let sx = arguments["start_x"]?.doubleValue else { throw ToolError.missingArgument("start_x") }
        guard let sy = arguments["start_y"]?.doubleValue else { throw ToolError.missingArgument("start_y") }
        guard let ex = arguments["end_x"]?.doubleValue else { throw ToolError.missingArgument("end_x") }
        guard let ey = arguments["end_y"]?.doubleValue else { throw ToolError.missingArgument("end_y") }
        try ComputerActionValidator.validatePoint(CGPoint(x: sx, y: sy))
        try ComputerActionValidator.validatePoint(CGPoint(x: ex, y: ey))
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard session.state.isActive else {
            return .failure("Computer control session is not active.")
        }
        guard driver.isAuthorized else {
            return .failure("Accessibility permission is required for computer control input, but is not currently granted.")
        }
        guard let sx = arguments["start_x"]?.doubleValue,
              let sy = arguments["start_y"]?.doubleValue,
              let ex = arguments["end_x"]?.doubleValue,
              let ey = arguments["end_y"]?.doubleValue else {
            return .failure("Missing required coordinates for drag.")
        }

        let buttonStr = arguments["button"]?.stringValue?.lowercased() ?? "left"
        let button = MouseButton(rawValue: buttonStr) ?? .left
        let start = CGPoint(x: sx, y: sy)
        let end = CGPoint(x: ex, y: ey)

        let token = session.currentToken
        let action = ComputerControlAction(kind: .drag, target: .point(x: ex, y: ey, displayID: nil), button: button, token: token)
        let recordResult = session.recordAction(action)
        if case .failure(let err) = recordResult {
            return .failure("Cannot execute drag: \(err.localizedDescription)")
        }

        do {
            try await driver.drag(from: start, to: end, button: button)
            return .success("Dragged from (\(Int(sx)), \(Int(sy))) to (\(Int(ex)), \(Int(ey))).")
        } catch {
            return .failure("Drag failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - ui_observe

/// Observes accessible UI elements within the active scoped application.
public final class UIObserveTool: IvyTool, Sendable {
    public let name = "ui_observe"
    public let description = "Observes accessible UI elements within the active application window."
    public let group = ToolGroup.system
    public let safetyClassification = ToolSafetyClassification.safe

    public var declaration: FunctionDeclaration {
        FunctionDeclaration(
            name: name,
            description: description,
            parameters: ToolParameters(
                properties: [
                    "bundle_id": ToolProperty(type: "STRING", description: "Optional bundle ID of target application.")
                ],
                required: []
            )
        )
    }

    private let session: ComputerControlSession
    private let observationProvider: (any DesktopObservationProviding)?

    public init(session: ComputerControlSession, observationProvider: (any DesktopObservationProviding)? = nil) {
        self.session = session
        self.observationProvider = observationProvider
    }

    public func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType] {
        [.accessibility]
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard let scope = session.state.currentScope else {
            return .failure("No active computer control session scope.")
        }
        guard let provider = observationProvider else {
            return .failure("Observation provider not configured.")
        }

        do {
            let observation = try await provider.observe(session: session, scope: scope)
            let count = observation.elements.count
            let tokenString = observation.token.id.uuidString
            let summary = "Observed \(count) UI elements in '\(scope.bundleIdentifier)'. Observation Token: \(tokenString)"
            return .success(summary)
        } catch {
            return .failure("Observation failed: \(error.localizedDescription)")
        }
    }
}
