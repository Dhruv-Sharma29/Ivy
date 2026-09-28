import Foundation
import os
#if os(macOS)
import AppKit
import Carbon
#endif

/// Native macOS global hotkey driver.
/// Keyed shortcuts use the Carbon Event Manager (no permissions needed). Modifier-only chords
/// (e.g. Option + Control) use NSEvent flagsChanged monitors, which require Accessibility access.
public final class SystemGlobalHotkeyManager: GlobalHotkeyManaging, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var isRegistered: Bool = false
        var registeredShortcut: HotkeyShortcut? = nil
        var onKeyDown: (@Sendable () -> Void)? = nil
        var onKeyUp: (@Sendable () -> Void)? = nil
        var isChordDown: Bool = false
        #if os(macOS)
        var hotKeyRef: EventHotKeyRef? = nil
        var handlerRef: EventHandlerRef? = nil
        var eventMonitors: [Any] = []
        #endif
    }

    /// Carbon refs and NSEvent monitor tokens aren't Sendable; they only cross into/out of the lock, never shared unguarded.
    private struct Box<T>: @unchecked Sendable { let value: T }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    deinit {
        unregister()
    }

    public var isRegistered: Bool {
        state.withLock { $0.isRegistered }
    }

    public var registeredShortcut: HotkeyShortcut? {
        state.withLock { $0.registeredShortcut }
    }

    public func register(
        shortcut: HotkeyShortcut,
        onKeyDown: @escaping @Sendable () -> Void,
        onKeyUp: @escaping @Sendable () -> Void
    ) throws {
        #if os(macOS)
        if state.withLock({ $0.isRegistered }) {
            throw HotkeyError.alreadyRegistered
        }
        if let keyCode = shortcut.keyCode {
            try registerCarbon(keyCode: keyCode, modifiers: shortcut.modifiers)
        } else {
            try registerModifierChord()
        }
        state.withLock { s in
            s.isRegistered = true
            s.registeredShortcut = shortcut
            s.onKeyDown = onKeyDown
            s.onKeyUp = onKeyUp
            s.isChordDown = false
        }
        #else
        throw HotkeyError.unsupportedPlatform
        #endif
    }

    public func unregister() {
        #if os(macOS)
        let monitors = state.withLock { s -> Box<[Any]> in
            guard s.isRegistered else { return Box(value: []) }
            if let hotKeyRef = s.hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
                s.hotKeyRef = nil
            }
            if let handlerRef = s.handlerRef {
                RemoveEventHandler(handlerRef)
                s.handlerRef = nil
            }
            let monitors = s.eventMonitors
            s.eventMonitors = []
            s.isRegistered = false
            s.registeredShortcut = nil
            s.onKeyDown = nil
            s.onKeyUp = nil
            s.isChordDown = false
            return Box(value: monitors)
        }
        monitors.value.forEach(NSEvent.removeMonitor)
        #endif
    }

    #if os(macOS)
    /// Exact match on the four chord modifiers, so e.g. Command + Option + Control does not trigger Option + Control.
    static func chordHeld(_ flags: NSEvent.ModifierFlags, required: HotkeyModifiers) -> Bool {
        var held: HotkeyModifiers = []
        if flags.contains(.command) { held.insert(.command) }
        if flags.contains(.shift) { held.insert(.shift) }
        if flags.contains(.option) { held.insert(.option) }
        if flags.contains(.control) { held.insert(.control) }
        return held == required
    }

    private func registerCarbon(keyCode: UInt32, modifiers: HotkeyModifiers) throws {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        let handler: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return noErr }
            let manager = Unmanaged<SystemGlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.dispatchCarbonEvent(kind: GetEventKind(eventRef))
            return noErr
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        var handlerRef: EventHandlerRef? = nil
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), handler, 2, &eventTypes, selfPtr, &handlerRef)
        guard installStatus == noErr else {
            throw HotkeyError.eventHandlerInstallationFailed(installStatus)
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x49565921), id: 1) // 'IVY!'
        var hotKeyRef: EventHotKeyRef? = nil
        let regStatus = RegisterEventHotKey(keyCode, modifiers.rawValue, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard regStatus == noErr else {
            if let handlerRef {
                RemoveEventHandler(handlerRef)
            }
            throw HotkeyError.registrationFailed(regStatus)
        }

        let refs = Box(value: (hotKeyRef, handlerRef))
        state.withLock { s in
            s.hotKeyRef = refs.value.0
            s.handlerRef = refs.value.1
        }
    }

    private func registerModifierChord() throws {
        // Prompts once; macOS only delivers other apps' key events to trusted processes.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw HotkeyError.accessibilityPermissionRequired
        }

        let handle: @Sendable (NSEvent.ModifierFlags) -> Void = { [weak self] flags in
            self?.dispatchFlagsChanged(flags)
        }
        let monitors = MainActor.assumeIsolated {
            Box(value: [
                NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { handle($0.modifierFlags) },
                NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    handle(event.modifierFlags)
                    return event
                }
            ].compactMap { $0 })
        }
        state.withLock { $0.eventMonitors = monitors.value }
    }

    private func dispatchCarbonEvent(kind: UInt32) {
        let (downHandler, upHandler) = state.withLock { s in
            (s.onKeyDown, s.onKeyUp)
        }

        if kind == UInt32(kEventHotKeyPressed) {
            downHandler?()
        } else if kind == UInt32(kEventHotKeyReleased) {
            upHandler?()
        }
    }

    private func dispatchFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        let handler = state.withLock { s -> (@Sendable () -> Void)? in
            guard let required = s.registeredShortcut?.modifiers else { return nil }
            let held = Self.chordHeld(flags, required: required)
            guard held != s.isChordDown else { return nil }
            s.isChordDown = held
            return held ? s.onKeyDown : s.onKeyUp
        }
        handler?()
    }
    #endif
}
