import AppKit
import Carbon
import Foundation
import os
import Testing
@testable import IvyCore

/// Sends Carbon notifications only inside the test process; never types into another app or opens a mic.
@MainActor @Suite("Native global hotkey routing", .serialized)
struct NativeGlobalHotkeyTests {
    @Test("Hotkey notifications reach the driver before application-level handlers")
    func dispatcherRouting() throws {
        _ = NSApplication.shared
        let first = SystemGlobalHotkeyManager(), second = SystemGlobalHotkeyManager()
        let counts = OSAllocatedUnfairLock(initialState: [0, 0, 0, 0])
        try first.register(shortcut: HotkeyShortcut(keyCode: UInt32(kVK_F19), modifiers: [.command, .shift, .option, .control]),
                           onKeyDown: { counts.withLock { $0[0] += 1 } }, onKeyUp: { counts.withLock { $0[1] += 1 } })
        defer { first.unregister() }
        try second.register(shortcut: HotkeyShortcut(keyCode: UInt32(kVK_F20), modifiers: [.command, .shift, .option, .control]),
                            onKeyDown: { counts.withLock { $0[2] += 1 } }, onKeyUp: { counts.withLock { $0[3] += 1 } })
        defer { second.unregister() }

        // Model an application handler that consumes hotkey events before older app-level handlers.
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        var consumer: EventHandlerRef?
        #expect(InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in noErr }, 2, &types, nil, &consumer) == noErr)
        defer { if let consumer { RemoveEventHandler(consumer) } }

        try notify(first, kind: UInt32(kEventHotKeyPressed))
        try notify(first, kind: UInt32(kEventHotKeyReleased))
        #expect(counts.withLock { $0 } == [1, 1, 0, 0])
        try notify(second, kind: UInt32(kEventHotKeyPressed))
        try notify(second, kind: UInt32(kEventHotKeyReleased))
        #expect(counts.withLock { $0 } == [1, 1, 1, 1], "Other managers must not consume this manager's notification")
        first.unregister()
        try notify(first, kind: UInt32(kEventHotKeyPressed))
        #expect(counts.withLock { $0 } == [1, 1, 1, 1], "Unregistered handlers must not run")
    }

    private func notify(_ manager: SystemGlobalHotkeyManager, kind: UInt32) throws {
        var event: EventRef?
        #expect(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, UInt32(kEventAttributeNone), &event) == noErr)
        let notification = try #require(event)
        defer { ReleaseEvent(notification) }
        var identity = EventHotKeyID(signature: OSType(0x49565921), id: manager.hotKeyNumber)
        #expect(SetEventParameter(notification, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                  MemoryLayout<EventHotKeyID>.size, &identity) == noErr)
        #expect(SendEventToEventTarget(notification, GetEventDispatcherTarget()) == noErr)
    }
}
