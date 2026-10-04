import Foundation
import CoreGraphics
import os
#if os(macOS)
import AppKit
import Carbon
import ApplicationServices
#endif

/// Errors arising during native input synthesis and validation.
public enum ComputerInputError: LocalizedError, Equatable, Sendable {
    case permissionDenied
    case invalidCoordinates(x: Double, y: Double)
    case invalidArgument(String)
    case unsupportedKey(String)
    case excessiveModifiers([String])
    case textTooLong(count: Int, limit: Int)
    case eventCreationFailed(String)
    case sessionNotActive
    case tokenExpired
    case prohibitedApplication(String)
    case targetNotFound(String)
    case targetDisabled(String)
    case targetNotPermitted(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Accessibility permission is required for computer control input, but is not currently granted."
        case .invalidCoordinates(let x, let y):
            return "Invalid target coordinates: (\(x), \(y)). Coordinates must be finite, non-negative, and within screen limits."
        case .invalidArgument(let msg):
            return "Invalid argument: \(msg)"
        case .unsupportedKey(let key):
            return "Key '\(key)' is not recognized or supported."
        case .excessiveModifiers(let mods):
            return "Too many modifiers specified: \(mods.joined(separator: ", ")). Maximum allowed is 4."
        case .textTooLong(let count, let limit):
            return "Text length (\(count)) exceeds maximum allowed length of \(limit) characters."
        case .eventCreationFailed(let msg):
            return "System event synthesis failed: \(msg)"
        case .sessionNotActive:
            return "Computer control session is not active or has been cancelled."
        case .tokenExpired:
            return "Observation token is missing or expired. A fresh observation must be taken before dispatching actions."
        case .prohibitedApplication(let bundleID):
            return "Interaction with application '\(bundleID)' is prohibited by safety policy."
        case .targetNotFound(let id):
            return "Target element '\(id)' was not found in the current observation snapshot."
        case .targetDisabled(let id):
            return "Target element '\(id)' is currently disabled and cannot be interacted with."
        case .targetNotPermitted(let id):
            return "Target element '\(id)' is a protected or secure surface (e.g. password field) and cannot be accessed."
        }
    }
}

/// Recorded synthetic input event for inspection, tracing, and unit test verification.
public enum InputEventRecord: Equatable, Sendable {
    case click(point: CGPoint, button: MouseButton, clickCount: Int)
    case move(point: CGPoint)
    case drag(start: CGPoint, end: CGPoint, button: MouseButton)
    case type(text: String)
    case key(key: String, modifiers: [String])
    case scroll(point: CGPoint?, deltaX: Double, deltaY: Double)
    case releaseAll
}

/// Protocol abstracting native mouse and keyboard input synthesis.
public protocol ComputerInputDriving: Sendable {
    /// Indicates whether system accessibility permission is granted for synthetic input.
    var isAuthorized: Bool { get }

    /// Synthesizes a mouse click at target screen coordinates.
    func click(at point: CGPoint, button: MouseButton, clickCount: Int) async throws

    /// Synthesizes mouse pointer motion to target screen coordinates.
    func move(to point: CGPoint) async throws

    /// Synthesizes a mouse drag from a start position to an end position.
    func drag(from start: CGPoint, to end: CGPoint, button: MouseButton) async throws

    /// Types text into the focused field.
    func type(text: String) async throws

    /// Presses a key or key combination and guarantees release.
    func pressKey(key: String, modifiers: [String]) async throws

    /// Synthesizes mouse scroll wheel motion.
    func scroll(at point: CGPoint?, deltaX: Double, deltaY: Double) async throws

    /// Emergency release for any held mouse buttons or keys.
    func releaseAllHeldInputs() async
}

/// Production implementation of ComputerInputDriving using macOS CGEvent and Carbon keycodes.
public final class SystemComputerInputDriver: ComputerInputDriving, Sendable {
    private struct State: Sendable {
        var heldKeys: Set<String> = []
        var isMouseDown: Bool = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let permissionChecker: @Sendable () -> Bool

    public init(permissionChecker: (@Sendable () -> Bool)? = nil) {
        self.permissionChecker = permissionChecker ?? {
            #if os(macOS)
            return AXIsProcessTrusted()
            #else
            return false
            #endif
        }
    }

    public var isAuthorized: Bool {
        permissionChecker()
    }

    public func click(at point: CGPoint, button: MouseButton, clickCount: Int) async throws {
        guard isAuthorized else {
            throw ComputerInputError.permissionDenied
        }
        try ComputerActionValidator.validatePoint(point)
        guard clickCount >= 1 && clickCount <= 2 else {
            throw ComputerInputError.invalidArgument("Click count must be 1 (single) or 2 (double).")
        }

        #if os(macOS)
        let (downType, upType, cgButton) = mouseEventTypes(for: button)

        // Move to target point first
        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }

        for c in 1...clickCount {
            guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: point, mouseButton: cgButton),
                  let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: point, mouseButton: cgButton) else {
                throw ComputerInputError.eventCreationFailed("Failed to allocate CGEvent for mouse click")
            }

            downEvent.setIntegerValueField(.mouseEventClickState, value: Int64(c))
            upEvent.setIntegerValueField(.mouseEventClickState, value: Int64(c))

            downEvent.post(tap: .cghidEventTap)
            upEvent.post(tap: .cghidEventTap)
        }
        #endif
    }

    public func move(to point: CGPoint) async throws {
        guard isAuthorized else {
            throw ComputerInputError.permissionDenied
        }
        try ComputerActionValidator.validatePoint(point)

        #if os(macOS)
        guard let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) else {
            throw ComputerInputError.eventCreationFailed("Failed to allocate CGEvent for mouse move")
        }
        moveEvent.post(tap: .cghidEventTap)
        #endif
    }

    public func drag(from start: CGPoint, to end: CGPoint, button: MouseButton) async throws {
        guard isAuthorized else {
            throw ComputerInputError.permissionDenied
        }
        try ComputerActionValidator.validatePoint(start)
        try ComputerActionValidator.validatePoint(end)

        #if os(macOS)
        let (downType, upType, cgButton) = mouseEventTypes(for: button)
        let dragType: CGEventType = (button == .right) ? .rightMouseDragged : .leftMouseDragged

        if let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: start, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }

        guard let downEvent = CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: start, mouseButton: cgButton) else {
            throw ComputerInputError.eventCreationFailed("Failed to allocate mouse down for drag")
        }

        state.withLock { $0.isMouseDown = true }
        downEvent.post(tap: .cghidEventTap)

        // Mouse button is guaranteed to be released even if an error or cancellation occurs
        defer {
            if let upEvent = CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: end, mouseButton: cgButton) {
                upEvent.post(tap: .cghidEventTap)
            }
            state.withLock { $0.isMouseDown = false }
        }

        // Bounded path interpolation: emit intermediate drag events
        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = max(2, min(20, Int(distance / 25.0)))
        for step in 1...steps {
            try Task.checkCancellation()
            let progress = CGFloat(step) / CGFloat(steps)
            let intermediatePoint = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            if let dragEvent = CGEvent(mouseEventSource: nil, mouseType: dragType, mouseCursorPosition: intermediatePoint, mouseButton: cgButton) {
                dragEvent.post(tap: .cghidEventTap)
            }
        }
        #endif
    }

    public func type(text: String) async throws {
        guard isAuthorized else {
            throw ComputerInputError.permissionDenied
        }
        try ComputerActionValidator.validateText(text)

        #if os(macOS)
        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var offset = 0

        while offset < utf16.count {
            let count = min(chunkSize, utf16.count - offset)
            var chunk = Array(utf16[offset..<(offset + count)])
            offset += count

            guard let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                throw ComputerInputError.eventCreationFailed("Failed to allocate CGEvent for typing")
            }

            downEvent.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            upEvent.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)

            downEvent.post(tap: .cghidEventTap)
            upEvent.post(tap: .cghidEventTap)
        }
        #endif
    }

    public func pressKey(key: String, modifiers: [String]) async throws {
        guard isAuthorized else {
            throw ComputerInputError.permissionDenied
        }
        guard modifiers.count <= ComputerActionValidator.maxModifiers else {
            throw ComputerInputError.excessiveModifiers(modifiers)
        }

        #if os(macOS)
        guard let keyCode = Self.virtualKeyCode(for: key) else {
            throw ComputerInputError.unsupportedKey(key)
        }

        var flags = CGEventFlags()
        for mod in modifiers {
            guard let modFlag = Self.modifierFlag(for: mod) else {
                throw ComputerInputError.invalidArgument("Unknown modifier '\(mod)'")
            }
            flags.insert(modFlag)
        }

        guard let downEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            throw ComputerInputError.eventCreationFailed("Failed to allocate CGEvent for key press")
        }

        downEvent.flags = flags
        upEvent.flags = flags

        state.withLock { s in
            _ = s.heldKeys.insert(key)
        }

        // Guarantee key release and modifier clearance
        defer {
            upEvent.post(tap: .cghidEventTap)
            if let clearFlagsEvent = CGEvent(source: nil) {
                clearFlagsEvent.flags = []
                clearFlagsEvent.post(tap: .cghidEventTap)
            }
            state.withLock { s in
                _ = s.heldKeys.remove(key)
            }
        }

        downEvent.post(tap: .cghidEventTap)
        #endif
    }

    public func scroll(at point: CGPoint?, deltaX: Double, deltaY: Double) async throws {
        guard isAuthorized else {
            throw ComputerInputError.permissionDenied
        }
        if let point {
            try ComputerActionValidator.validatePoint(point)
        }
        try ComputerActionValidator.validateScrollDelta(x: deltaX, y: deltaY)

        #if os(macOS)
        if let point, let moveEvent = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
            moveEvent.post(tap: .cghidEventTap)
        }

        guard let scrollEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(deltaY), wheel2: Int32(deltaX), wheel3: 0) else {
            throw ComputerInputError.eventCreationFailed("Failed to allocate CGEvent for scroll")
        }
        scrollEvent.post(tap: .cghidEventTap)
        #endif
    }

    public func releaseAllHeldInputs() async {
        #if os(macOS)
        let (held, isDown) = state.withLock { s -> (Set<String>, Bool) in
            let copy = (s.heldKeys, s.isMouseDown)
            s.heldKeys.removeAll()
            s.isMouseDown = false
            return copy
        }

        if isDown {
            if let upEvent = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: .zero, mouseButton: .left) {
                upEvent.post(tap: .cghidEventTap)
            }
        }

        for key in held {
            if let code = Self.virtualKeyCode(for: key),
               let upEvent = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) {
                upEvent.post(tap: .cghidEventTap)
            }
        }

        if let clearFlagsEvent = CGEvent(source: nil) {
            clearFlagsEvent.flags = []
            clearFlagsEvent.post(tap: .cghidEventTap)
        }
        #endif
    }

    #if os(macOS)
    private func mouseEventTypes(for button: MouseButton) -> (CGEventType, CGEventType, CGMouseButton) {
        switch button {
        case .left:
            return (.leftMouseDown, .leftMouseUp, .left)
        case .right:
            return (.rightMouseDown, .rightMouseUp, .right)
        case .middle:
            return (.otherMouseDown, .otherMouseUp, .center)
        }
    }

    public static func modifierFlag(for modifier: String) -> CGEventFlags? {
        switch modifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "cmd":
            return .maskCommand
        case "shift":
            return .maskShift
        case "option", "alt":
            return .maskAlternate
        case "control", "ctrl":
            return .maskControl
        case "fn", "function":
            return .maskSecondaryFn
        default:
            return nil
        }
    }

    public static func virtualKeyCode(for key: String) -> CGKeyCode? {
        let cleaned = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch cleaned {
        // Alphanumerics
        case "a": return CGKeyCode(kVK_ANSI_A)
        case "b": return CGKeyCode(kVK_ANSI_B)
        case "c": return CGKeyCode(kVK_ANSI_C)
        case "d": return CGKeyCode(kVK_ANSI_D)
        case "e": return CGKeyCode(kVK_ANSI_E)
        case "f": return CGKeyCode(kVK_ANSI_F)
        case "g": return CGKeyCode(kVK_ANSI_G)
        case "h": return CGKeyCode(kVK_ANSI_H)
        case "i": return CGKeyCode(kVK_ANSI_I)
        case "j": return CGKeyCode(kVK_ANSI_J)
        case "k": return CGKeyCode(kVK_ANSI_K)
        case "l": return CGKeyCode(kVK_ANSI_L)
        case "m": return CGKeyCode(kVK_ANSI_M)
        case "n": return CGKeyCode(kVK_ANSI_N)
        case "o": return CGKeyCode(kVK_ANSI_O)
        case "p": return CGKeyCode(kVK_ANSI_P)
        case "q": return CGKeyCode(kVK_ANSI_Q)
        case "r": return CGKeyCode(kVK_ANSI_R)
        case "s": return CGKeyCode(kVK_ANSI_S)
        case "t": return CGKeyCode(kVK_ANSI_T)
        case "u": return CGKeyCode(kVK_ANSI_U)
        case "v": return CGKeyCode(kVK_ANSI_V)
        case "w": return CGKeyCode(kVK_ANSI_W)
        case "x": return CGKeyCode(kVK_ANSI_X)
        case "y": return CGKeyCode(kVK_ANSI_Y)
        case "z": return CGKeyCode(kVK_ANSI_Z)
        case "0": return CGKeyCode(kVK_ANSI_0)
        case "1": return CGKeyCode(kVK_ANSI_1)
        case "2": return CGKeyCode(kVK_ANSI_2)
        case "3": return CGKeyCode(kVK_ANSI_3)
        case "4": return CGKeyCode(kVK_ANSI_4)
        case "5": return CGKeyCode(kVK_ANSI_5)
        case "6": return CGKeyCode(kVK_ANSI_6)
        case "7": return CGKeyCode(kVK_ANSI_7)
        case "8": return CGKeyCode(kVK_ANSI_8)
        case "9": return CGKeyCode(kVK_ANSI_9)

        // Navigation and control
        case "return", "enter": return CGKeyCode(kVK_Return)
        case "tab": return CGKeyCode(kVK_Tab)
        case "space": return CGKeyCode(kVK_Space)
        case "delete", "backspace": return CGKeyCode(kVK_Delete)
        case "forwarddelete": return CGKeyCode(kVK_ForwardDelete)
        case "escape", "esc": return CGKeyCode(kVK_Escape)
        case "up", "arrowup": return CGKeyCode(kVK_UpArrow)
        case "down", "arrowdown": return CGKeyCode(kVK_DownArrow)
        case "left", "arrowleft": return CGKeyCode(kVK_LeftArrow)
        case "right", "arrowright": return CGKeyCode(kVK_RightArrow)
        case "pageup": return CGKeyCode(kVK_PageUp)
        case "pagedown": return CGKeyCode(kVK_PageDown)
        case "home": return CGKeyCode(kVK_Home)
        case "end": return CGKeyCode(kVK_End)

        // Function keys
        case "f1": return CGKeyCode(kVK_F1)
        case "f2": return CGKeyCode(kVK_F2)
        case "f3": return CGKeyCode(kVK_F3)
        case "f4": return CGKeyCode(kVK_F4)
        case "f5": return CGKeyCode(kVK_F5)
        case "f6": return CGKeyCode(kVK_F6)
        case "f7": return CGKeyCode(kVK_F7)
        case "f8": return CGKeyCode(kVK_F8)
        case "f9": return CGKeyCode(kVK_F9)
        case "f10": return CGKeyCode(kVK_F10)
        case "f11": return CGKeyCode(kVK_F11)
        case "f12": return CGKeyCode(kVK_F12)

        // Symbols
        case ",", "comma": return CGKeyCode(kVK_ANSI_Comma)
        case ".", "period": return CGKeyCode(kVK_ANSI_Period)
        case "/", "slash": return CGKeyCode(kVK_ANSI_Slash)
        case ";", "semicolon": return CGKeyCode(kVK_ANSI_Semicolon)
        case "'", "quote": return CGKeyCode(kVK_ANSI_Quote)
        case "[", "bracketleft": return CGKeyCode(kVK_ANSI_LeftBracket)
        case "]", "bracketright": return CGKeyCode(kVK_ANSI_RightBracket)
        case "\\", "backslash": return CGKeyCode(kVK_ANSI_Backslash)
        case "`", "grave": return CGKeyCode(kVK_ANSI_Grave)
        case "-", "minus": return CGKeyCode(kVK_ANSI_Minus)
        case "=", "equal": return CGKeyCode(kVK_ANSI_Equal)

        default:
            return nil
        }
    }
    #endif
}

/// Offline mock implementation of ComputerInputDriving for hermetic unit testing.
public final class MockComputerInputDriver: ComputerInputDriving, @unchecked Sendable {
    public struct State: Sendable {
        public var isAuthorized: Bool = true
        public var recordedEvents: [InputEventRecord] = []
        public var currentCursorPosition: CGPoint = .zero
        public var isMouseDown: Bool = false
        public var heldKeys: Set<String> = []
        public var shouldFailNext: ComputerInputError? = nil
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(isAuthorized: Bool = true) {
        self.state = OSAllocatedUnfairLock(initialState: State(isAuthorized: isAuthorized))
    }

    public var isAuthorized: Bool {
        get { state.withLock { $0.isAuthorized } }
        set { state.withLock { $0.isAuthorized = newValue } }
    }

    public var recordedEvents: [InputEventRecord] {
        state.withLock { $0.recordedEvents }
    }

    public var currentCursorPosition: CGPoint {
        state.withLock { $0.currentCursorPosition }
    }

    public var isMouseDown: Bool {
        state.withLock { $0.isMouseDown }
    }

    public var heldKeys: Set<String> {
        state.withLock { $0.heldKeys }
    }

    public func setFailure(_ error: ComputerInputError?) {
        state.withLock { $0.shouldFailNext = error }
    }

    public func clearEvents() {
        state.withLock { $0.recordedEvents.removeAll() }
    }

    private func checkFailureAndAuthorization() throws {
        let failure = state.withLock { s -> ComputerInputError? in
            let err = s.shouldFailNext
            s.shouldFailNext = nil
            return err
        }
        if let failure {
            throw failure
        }
        guard isAuthorized else {
            throw ComputerInputError.permissionDenied
        }
    }

    public func click(at point: CGPoint, button: MouseButton, clickCount: Int) async throws {
        try checkFailureAndAuthorization()
        try ComputerActionValidator.validatePoint(point)
        guard clickCount >= 1 && clickCount <= 2 else {
            throw ComputerInputError.invalidArgument("Click count must be 1 or 2.")
        }

        state.withLock { s in
            s.currentCursorPosition = point
            s.recordedEvents.append(.move(point: point))
            s.recordedEvents.append(.click(point: point, button: button, clickCount: clickCount))
        }
    }

    public func move(to point: CGPoint) async throws {
        try checkFailureAndAuthorization()
        try ComputerActionValidator.validatePoint(point)

        state.withLock { s in
            s.currentCursorPosition = point
            s.recordedEvents.append(.move(point: point))
        }
    }

    public func drag(from start: CGPoint, to end: CGPoint, button: MouseButton) async throws {
        try checkFailureAndAuthorization()
        try ComputerActionValidator.validatePoint(start)
        try ComputerActionValidator.validatePoint(end)

        state.withLock { s in
            s.currentCursorPosition = start
            s.isMouseDown = true
            s.recordedEvents.append(.move(point: start))
        }

        defer {
            state.withLock { s in
                s.isMouseDown = false
            }
        }

        let distance = hypot(end.x - start.x, end.y - start.y)
        let steps = max(2, min(20, Int(distance / 25.0)))
        for step in 1...steps {
            try Task.checkCancellation()
            let progress = CGFloat(step) / CGFloat(steps)
            let intermediatePoint = CGPoint(
                x: start.x + (end.x - start.x) * progress,
                y: start.y + (end.y - start.y) * progress
            )
            state.withLock { s in
                s.currentCursorPosition = intermediatePoint
            }
        }

        state.withLock { s in
            s.currentCursorPosition = end
            s.recordedEvents.append(.drag(start: start, end: end, button: button))
        }
    }

    public func type(text: String) async throws {
        try checkFailureAndAuthorization()
        try ComputerActionValidator.validateText(text)

        state.withLock { s in
            s.recordedEvents.append(.type(text: text))
        }
    }

    public func pressKey(key: String, modifiers: [String]) async throws {
        try checkFailureAndAuthorization()
        guard modifiers.count <= ComputerActionValidator.maxModifiers else {
            throw ComputerInputError.excessiveModifiers(modifiers)
        }

        #if os(macOS)
        guard SystemComputerInputDriver.virtualKeyCode(for: key) != nil else {
            throw ComputerInputError.unsupportedKey(key)
        }
        for mod in modifiers {
            guard SystemComputerInputDriver.modifierFlag(for: mod) != nil else {
                throw ComputerInputError.invalidArgument("Unknown modifier '\(mod)'")
            }
        }
        #endif

        state.withLock { s in
            _ = s.heldKeys.insert(key)
        }

        state.withLock { s in
            _ = s.heldKeys.remove(key)
            s.recordedEvents.append(.key(key: key, modifiers: modifiers))
        }
    }

    public func scroll(at point: CGPoint?, deltaX: Double, deltaY: Double) async throws {
        try checkFailureAndAuthorization()
        if let point {
            try ComputerActionValidator.validatePoint(point)
        }
        try ComputerActionValidator.validateScrollDelta(x: deltaX, y: deltaY)

        state.withLock { s in
            if let point {
                s.currentCursorPosition = point
            }
            s.recordedEvents.append(.scroll(point: point, deltaX: deltaX, deltaY: deltaY))
        }
    }

    public func releaseAllHeldInputs() async {
        state.withLock { s in
            s.isMouseDown = false
            s.heldKeys.removeAll()
            s.recordedEvents.append(.releaseAll)
        }
    }
}
