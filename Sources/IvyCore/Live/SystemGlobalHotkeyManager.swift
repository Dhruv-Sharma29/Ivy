import Foundation
import os
#if os(macOS)
import Carbon
#endif

/// Native macOS global hotkey driver using Carbon Event Manager.
/// Intercepts global keyboard shortcuts across applications without requiring Accessibility privileges.
public final class SystemGlobalHotkeyManager: GlobalHotkeyManaging, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var isRegistered: Bool = false
        var registeredShortcut: HotkeyShortcut? = nil
        var onKeyDown: (@Sendable () -> Void)? = nil
        var onKeyUp: (@Sendable () -> Void)? = nil
        #if os(macOS)
        var hotKeyRef: EventHotKeyRef? = nil
        var handlerRef: EventHandlerRef? = nil
        #endif
    }

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
        try state.withLock { s in
            if s.isRegistered {
                throw HotkeyError.alreadyRegistered
            }

            var eventTypes = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]

            let handler: EventHandlerUPP = { _, eventRef, userData in
                guard let eventRef, let userData else { return noErr }
                let manager = Unmanaged<SystemGlobalHotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                let kind = GetEventKind(eventRef)
                manager.dispatchCarbonEvent(kind: kind)
                return noErr
            }

            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            var handlerRef: EventHandlerRef? = nil
            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                handler,
                2,
                &eventTypes,
                selfPtr,
                &handlerRef
            )

            guard installStatus == noErr else {
                throw HotkeyError.eventHandlerInstallationFailed(installStatus)
            }

            let hotKeyID = EventHotKeyID(signature: OSType(0x49565921), id: 1) // 'IVY!'
            var hotKeyRef: EventHotKeyRef? = nil
            let regStatus = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers.rawValue,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            guard regStatus == noErr else {
                if let handlerRef {
                    RemoveEventHandler(handlerRef)
                }
                throw HotkeyError.registrationFailed(regStatus)
            }

            s.isRegistered = true
            s.registeredShortcut = shortcut
            s.onKeyDown = onKeyDown
            s.onKeyUp = onKeyUp
            s.hotKeyRef = hotKeyRef
            s.handlerRef = handlerRef
        }
        #else
        throw HotkeyError.unsupportedPlatform
        #endif
    }

    public func unregister() {
        #if os(macOS)
        state.withLock { s in
            guard s.isRegistered else { return }
            if let hotKeyRef = s.hotKeyRef {
                UnregisterEventHotKey(hotKeyRef)
                s.hotKeyRef = nil
            }
            if let handlerRef = s.handlerRef {
                RemoveEventHandler(handlerRef)
                s.handlerRef = nil
            }
            s.isRegistered = false
            s.registeredShortcut = nil
            s.onKeyDown = nil
            s.onKeyUp = nil
        }
        #endif
    }

    #if os(macOS)
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
    #endif
}
