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
        let first = SystemGlobalHotkeyManager(exclusive: true), second = SystemGlobalHotkeyManager()
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
        #expect(first.isShortcutHeld == nil, "A Carbon press without physical key-state evidence must stay unknown, not released")
        try notify(first, kind: UInt32(kEventHotKeyReleased))
        #expect(first.isShortcutHeld == false, "Carbon release is authoritative even if physical state is unavailable")
        #expect(counts.withLock { $0 } == [1, 1, 0, 0])
        try notify(second, kind: UInt32(kEventHotKeyPressed))
        try notify(second, kind: UInt32(kEventHotKeyReleased))
        #expect(counts.withLock { $0 } == [1, 1, 1, 1], "Other managers must not consume this manager's notification")
        first.unregister()
        try notify(first, kind: UInt32(kEventHotKeyPressed))
        #expect(counts.withLock { $0 } == [1, 1, 1, 1], "Unregistered handlers must not run")
    }

    @Test("Physical release recovery requires evidence of a hold in this press")
    func physicalObservation() {
        var hold = SystemGlobalHotkeyManager.PhysicalHoldObservation()
        #expect(hold.observe(keyIsDown: false, modifiersHeld: false) == nil)
        #expect(hold.observe(keyIsDown: false, modifiersHeld: false) == nil)
        #expect(hold.observe(keyIsDown: true, modifiersHeld: true) == true)
        #expect(hold.observe(keyIsDown: true, modifiersHeld: true) == true)
        #expect(hold.observe(keyIsDown: false, modifiersHeld: true) == false)
        hold = SystemGlobalHotkeyManager.PhysicalHoldObservation()
        #expect(hold.observe(keyIsDown: true, modifiersHeld: true) == true)
        #expect(hold.observe(keyIsDown: true, modifiersHeld: false) == false)
        hold = SystemGlobalHotkeyManager.PhysicalHoldObservation()
        #expect(hold.observe(keyIsDown: false, modifiersHeld: true) == nil)
        #expect(hold.observe(keyIsDown: false, modifiersHeld: false) == false,
                "Releasing verified modifiers recovers even when the keyed state was never readable")
        hold = SystemGlobalHotkeyManager.PhysicalHoldObservation()
        #expect(hold.observe(keyIsDown: true, modifiersHeld: false) == nil)
        #expect(hold.observe(keyIsDown: false, modifiersHeld: false) == false)
    }

    @Test("A recovered physical release unlocks the next native press and resets evidence")
    func releaseThenPress() throws {
        _ = NSApplication.shared
        let manager = SystemGlobalHotkeyManager(exclusive: true)
        let shortcut = HotkeyShortcut(keyCode: UInt32(kVK_F19), modifiers: [.command, .shift, .option, .control])
        let counts = OSAllocatedUnfairLock(initialState: [0, 0])
        #expect(manager.observePhysicalHold(shortcut: shortcut, keyIsDown: false, modifiersHeld: false) == nil)
        try manager.register(shortcut: shortcut, onKeyDown: { counts.withLock { $0[0] += 1 } },
                             onKeyUp: { counts.withLock { $0[1] += 1 } })
        defer { manager.unregister() }
        try notify(manager, kind: UInt32(kEventHotKeyPressed))
        #expect(manager.observePhysicalHold(shortcut: shortcut, keyIsDown: false, modifiersHeld: false) == nil)
        #expect(manager.observePhysicalHold(shortcut: shortcut, keyIsDown: true, modifiersHeld: true) == true)
        #expect(manager.observePhysicalHold(shortcut: shortcut, keyIsDown: false, modifiersHeld: true) == false)
        // Deliberately omit Carbon release, as with a lost key-up.
        try notify(manager, kind: UInt32(kEventHotKeyPressed))
        #expect(counts.withLock { $0 } == [2, 0])
        #expect(manager.observePhysicalHold(shortcut: shortcut, keyIsDown: false, modifiersHeld: false) == nil,
                "Evidence from the previous press cannot cancel a fresh press")
        try notify(manager, kind: UInt32(kEventHotKeyReleased))
        #expect(manager.observePhysicalHold(shortcut: shortcut, keyIsDown: true, modifiersHeld: true) == false)
        #expect(counts.withLock { $0 } == [2, 1])
        // Stop can cancel polling before a missing release is detected. A later press must
        // still be delivered; session-level idempotency handles any repeat while recording.
        try notify(manager, kind: UInt32(kEventHotKeyPressed))
        #expect(manager.observePhysicalHold(shortcut: shortcut, keyIsDown: true, modifiersHeld: true) == true)
        try notify(manager, kind: UInt32(kEventHotKeyPressed))
        #expect(counts.withLock { $0 } == [4, 1])
        #expect(manager.observePhysicalHold(shortcut: shortcut, keyIsDown: false, modifiersHeld: false) == nil)
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
