import Foundation
import os

/// Modifier flags for a global keyboard shortcut.
public struct HotkeyModifiers: OptionSet, Sendable, Equatable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Command key (Carbon cmdKey = 1 << 8 = 256)
    public static let command = HotkeyModifiers(rawValue: 1 << 8)
    /// Shift key (Carbon shiftKey = 1 << 9 = 512)
    public static let shift = HotkeyModifiers(rawValue: 1 << 9)
    /// Option / Alt key (Carbon optionKey = 1 << 11 = 2048)
    public static let option = HotkeyModifiers(rawValue: 1 << 11)
    /// Control key (Carbon controlKey = 1 << 12 = 4096)
    public static let control = HotkeyModifiers(rawValue: 1 << 12)
}

/// Key combination representing a global hotkey shortcut.
public struct HotkeyShortcut: Sendable, Equatable, Hashable {
    /// Virtual keycode (e.g. 49 for Space, kVK_Space); nil means a modifier-only chord.
    public let keyCode: UInt32?
    /// Modifier key flags (e.g. [.command, .shift])
    public let modifiers: HotkeyModifiers

    public init(keyCode: UInt32?, modifiers: HotkeyModifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Default Push-to-Talk shortcut: Command + Shift + Space (Carbon, zero Accessibility permission required)
    public static let defaultPushToTalk = HotkeyShortcut(
        keyCode: 49, // kVK_Space
        modifiers: [.command, .shift]
    )

    /// "What am I looking at?": Control + Option + Command + S. Not ⌘⇧S, which is Save As in most apps and a
    /// global hotkey would take it from all of them.
    public static let defaultScreenHelp = HotkeyShortcut(
        keyCode: 1, // kVK_ANSI_S
        modifiers: [.control, .option, .command]
    )

    /// Modifier-only Push-to-Talk chord: Option + Control (requires Accessibility permission)
    public static let optionControlChord = HotkeyShortcut(
        keyCode: nil,
        modifiers: [.option, .control]
    )
}

/// Errors related to global hotkey registration and lifecycle.
public enum HotkeyError: Error, LocalizedError, Equatable, Sendable {
    case alreadyRegistered
    case registrationFailed(Int32)
    case eventHandlerInstallationFailed(Int32)
    case notRegistered
    case unsupportedPlatform
    case accessibilityPermissionRequired

    public var errorDescription: String? {
        switch self {
        case .alreadyRegistered:
            return "Global hotkey is already registered."
        case .registrationFailed(let status):
            return "Failed to register global hotkey with system (OSStatus \(status))."
        case .eventHandlerInstallationFailed(let status):
            return "Failed to install global hotkey event handler (OSStatus \(status))."
        case .notRegistered:
            return "Global hotkey is not currently registered."
        case .unsupportedPlatform:
            return "Global hotkeys are not supported on this platform."
        case .accessibilityPermissionRequired:
            return "Option + Control push-to-talk needs Accessibility access. Allow it in System Settings › Privacy & Security › Accessibility, then relaunch Ivy."
        }
    }
}

/// Protocol defining a global hotkey driver for push-to-talk interactions.
public protocol GlobalHotkeyManaging: Sendable {
    /// Whether the hotkey is currently actively registered with the system.
    var isRegistered: Bool { get }

    /// Currently registered shortcut, if any.
    var registeredShortcut: HotkeyShortcut? { get }

    /// Registers a global hotkey with separate key-down and key-up callbacks.
    func register(
        shortcut: HotkeyShortcut,
        onKeyDown: @escaping @Sendable () -> Void,
        onKeyUp: @escaping @Sendable () -> Void
    ) throws

    /// Unregisters the active hotkey and cleans up system handlers.
    func unregister()
}

extension GlobalHotkeyManaging {
    /// Convenience registration using the default shortcut (Command + Shift + Space).
    public func register(
        onKeyDown: @escaping @Sendable () -> Void,
        onKeyUp: @escaping @Sendable () -> Void
    ) throws {
        try register(shortcut: .defaultPushToTalk, onKeyDown: onKeyDown, onKeyUp: onKeyUp)
    }
}

/// Thread-safe mock implementation of `GlobalHotkeyManaging` for unit testing.
public final class MockGlobalHotkeyManager: GlobalHotkeyManaging, @unchecked Sendable {
    private struct State {
        var isRegistered: Bool = false
        var registeredShortcut: HotkeyShortcut? = nil
        var onKeyDown: (@Sendable () -> Void)? = nil
        var onKeyUp: (@Sendable () -> Void)? = nil
        var registrationCount: Int = 0
        var unregisterCount: Int = 0
        var mockErrorOnRegister: HotkeyError? = nil
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init(mockErrorOnRegister: HotkeyError? = nil) {
        state.withLock {
            $0.mockErrorOnRegister = mockErrorOnRegister
        }
    }

    public var isRegistered: Bool {
        state.withLock { $0.isRegistered }
    }

    public var registeredShortcut: HotkeyShortcut? {
        state.withLock { $0.registeredShortcut }
    }

    public var registrationCount: Int {
        state.withLock { $0.registrationCount }
    }

    public var unregisterCount: Int {
        state.withLock { $0.unregisterCount }
    }

    public func setMockErrorOnRegister(_ error: HotkeyError?) {
        state.withLock { $0.mockErrorOnRegister = error }
    }

    public func register(
        shortcut: HotkeyShortcut,
        onKeyDown: @escaping @Sendable () -> Void,
        onKeyUp: @escaping @Sendable () -> Void
    ) throws {
        try state.withLock { s in
            if let error = s.mockErrorOnRegister {
                throw error
            }
            if s.isRegistered {
                throw HotkeyError.alreadyRegistered
            }
            s.isRegistered = true
            s.registeredShortcut = shortcut
            s.onKeyDown = onKeyDown
            s.onKeyUp = onKeyUp
            s.registrationCount += 1
        }
    }

    public func unregister() {
        state.withLock { s in
            s.isRegistered = false
            s.registeredShortcut = nil
            s.onKeyDown = nil
            s.onKeyUp = nil
            s.unregisterCount += 1
        }
    }

    /// Simulates a physical global key-down event.
    public func simulateKeyDown() {
        let handler = state.withLock { $0.onKeyDown }
        handler?()
    }

    /// Simulates a physical global key-up event.
    public func simulateKeyUp() {
        let handler = state.withLock { $0.onKeyUp }
        handler?()
    }
}
