import AppKit
import SwiftUI
import Testing
@testable import Ivy
@testable import IvyCore

@MainActor @Suite("Native spatial-question selector", .serialized)
struct ScreenQuestionControllerTests {
    private func settle() async { for _ in 0..<20 { await Task.yield() }; try? await Task.sleep(for: .milliseconds(30)) }

    @Test func registrationAndLostRelease() async throws {
        _ = NSApplication.shared
        var preferences = IvySettings.defaults; preferences.screenQuestionShortcut = .region
        let settings = SettingsModel(store: TemporarySettingsStore(preferences)), hotkey = MockGlobalHotkeyManager()
        let source = SelectionFixture()
        var panels: [SelectionTestPanel] = [], captures: [ScreenRegionSelection] = [], errors: [String] = []
        let controller = ScreenQuestionController(settings: settings, hotkey: hotkey, displays: { source.displays },
            cursor: { source.cursor }, frontWindow: { source.window },
            panelFactory: { let panel = SelectionTestPanel(); panels.append(panel); return panel }, automaticSampling: false,
            capture: { captures.append($0) }, report: { errors.append($0) })
        defer { controller.stop() }
        #expect(hotkey.registeredShortcut == ScreenQuestionShortcut.region.hotkey)
        hotkey.simulateKeyDown(); await settle()
        #expect(controller.isSelecting && panels.count == 2)
        #expect(panels.allSatisfy { !$0.ignoresMouseEvents && $0.canBecomeKey && !$0.canBecomeMain })
        let display = source.displays[0]
        controller.stroke(CGPoint(x: 100, y: 200), display: display, start: true)
        controller.stroke(CGPoint(x: 300, y: 400), display: display, start: false)
        hotkey.setShortcutHeld(false)
        #expect(!controller.sample())
        await settle()
        #expect(captures.count == 1 && captures[0].rect == CGRect(x: 100, y: 200, width: 200, height: 200))
        #expect(panels.allSatisfy { !$0.isVisible } && errors.isEmpty)
        hotkey.simulateKeyUp(); await settle(); #expect(captures.count == 1)
        settings.settings.screenQuestionShortcut = .area; await settle()
        #expect(hotkey.registeredShortcut == ScreenQuestionShortcut.area.hotkey)
        settings.settings.screenQuestionEnabled = false; await settle()
        #expect(!hotkey.isRegistered)
        #expect(controller.begin()) // Explicit menu action still works with the shortcut disabled.
        controller.key(53)
        #expect(!controller.isSelecting && captures.count == 1)
    }

    @Test func keyboardHoverLassoAndStaleWindow() async throws {
        _ = NSApplication.shared
        let settings = SettingsModel(store: TemporarySettingsStore()), source = SelectionFixture()
        var captures: [ScreenRegionSelection] = [], errors: [String] = []
        var panels: [SelectionTestPanel] = []
        let controller = ScreenQuestionController(settings: settings, hotkey: MockGlobalHotkeyManager(), displays: { source.displays },
            cursor: { source.cursor }, frontWindow: { source.window },
            panelFactory: { let p = SelectionTestPanel(); panels.append(p); return p }, automaticSampling: false,
            capture: { captures.append($0) }, report: { errors.append($0) })
        defer { controller.stop() }
        #expect(controller.begin() && !controller.begin())
        controller.key(123); controller.key(124); controller.key(125); controller.key(126); controller.key(0)
        #expect(controller.gesture.hover == source.cursor)
        #expect(controller.sample())
        source.cursor = CGPoint(x: -300, y: 200); #expect(controller.sample())
        controller.key(123); #expect(controller.sample())
        #expect(controller.gesture.hover == CGPoint(x: -310, y: 200), "mouse polling must not undo keyboard positioning")
        controller.key(36); await settle()
        #expect(captures.first?.displayID == 2 && captures.first?.rect.minX == -430)
        #expect(!controller.sample())
        #expect(controller.begin())
        controller.setMode(.rectangle)
        controller.stroke(CGPoint(x: 200, y: 200), display: source.displays[1], start: true)
        controller.stroke(CGPoint(x: 400, y: 500), display: source.displays[1], start: false)
        source.window = 99
        controller.finish(); await settle()
        #expect(!controller.isSelecting && captures.count == 1 && !errors.isEmpty)
        #expect(controller.begin())
        source.displays = []
        #expect(!controller.sample())
        #expect(!controller.begin())
        #expect(errors.last?.contains("No display") == true)
        controller.stop(); #expect(!controller.begin())
    }

    @Test func lifecycleCancellationAndVoiceRelease() async {
        _ = NSApplication.shared
        let settings = SettingsModel(store: TemporarySettingsStore()), source = SelectionFixture()
        let workspace = NotificationCenter(), notifications = NotificationCenter(), hotkey = MockGlobalHotkeyManager()
        var cancelled = 0, released = 0, captures = 0, invalidated = 0
        let controller = ScreenQuestionController(settings: settings, hotkey: hotkey, displays: { source.displays },
            cursor: { source.cursor }, frontWindow: { source.window }, blocked: { source.blocked },
            panelFactory: { SelectionTestPanel() }, workspaceNotifications: workspace, notifications: notifications,
            capture: { _ in captures += 1 }, report: { _ in })
        defer { controller.stop() }
        #expect(!hotkey.isRegistered, "voice key uses the existing PTT registration, never a competing handler")
        controller.onCancelled = { cancelled += 1 }; controller.onInvalidated = { invalidated += 1 }
        controller.onVoiceRelease = { released += 1 }
        #expect(controller.begin(voice: true))
        controller.key(76); #expect(released == 1 && controller.isSelecting)
        let selected = controller.takeSelection()
        #expect(selected != nil && !controller.isSelecting)
        #expect(controller.begin(voice: true)); controller.cancel(); #expect(cancelled == 1)
        #expect(controller.begin()); source.cursor.x += 20; await settle()
        for _ in 0..<50 {
            if controller.gesture.hover == source.cursor { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.gesture.hover == source.cursor)
        for (sleep, wake) in [(NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
                               (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)] {
            workspace.post(name: sleep, object: nil); await settle()
            #expect(!controller.isSelecting && !controller.begin())
            workspace.post(name: wake, object: nil); await settle()
            #expect(controller.begin())
        }
        notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil); await settle()
        #expect(!controller.isSelecting && invalidated >= 5 && captures == 0)
        workspace.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil); await settle()
        workspace.post(name: NSWorkspace.screensDidSleepNotification, object: nil); await settle()
        workspace.post(name: NSWorkspace.screensDidWakeNotification, object: nil); await settle()
        #expect(!controller.begin(), "display wake must not unlock the session")
        workspace.post(name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil); await settle()
        source.blocked = true; #expect(!controller.begin())
        source.blocked = false; #expect(controller.begin())
        source.blocked = true; #expect(!controller.sample())
    }

    @Test func registrationFailureAndCanvasRendering() async throws {
        _ = NSApplication.shared
        var preferences = IvySettings.defaults; preferences.screenQuestionShortcut = .region
        let hotkey = MockGlobalHotkeyManager(mockErrorOnRegister: .registrationFailed(-9878))
        var error = ""
        let controller = ScreenQuestionController(settings: SettingsModel(store: TemporarySettingsStore(preferences)),
            hotkey: hotkey, automaticSampling: false, capture: { _ in }, report: { error = $0 })
        #expect(error.contains("unavailable")); controller.stop()
        let canvas = ScreenSelectionCanvas(frame: CGRect(x: 0, y: 0, width: 900, height: 600))
        canvas.crop = CGRect(x: 100, y: 100, width: 300, height: 200)
        canvas.stroke = [CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 300), CGPoint(x: 400, y: 100)]
        var starts: [CGPoint] = [], drags: [CGPoint] = [], keys: [UInt16] = []
        canvas.onStart = { starts.append($0) }; canvas.onDrag = { drags.append($0) }; canvas.onKey = { keys.append($0) }
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: CGPoint(x: 40, y: 50), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: down); canvas.mouseDragged(with: down)
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 53))
        canvas.keyDown(with: key)
        #expect(starts.count == 1 && drags.count == 1 && keys == [53] && canvas.acceptsFirstResponder)
        let bitmap = try #require(canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds))
        canvas.cacheDisplay(in: canvas.bounds, to: bitmap)
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-ui-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("screen-selection-overlay.png"))
        for voice in [true, false] {
            let view = NSHostingView(rootView: ScreenSelectionToolbar(shortcut: "⌘⇧Space", voice: voice, onMode: { _ in }, onFinish: {}, onCancel: {}))
            view.frame = CGRect(x: 0, y: 0, width: 590, height: 84); view.layoutSubtreeIfNeeded()
            #expect(view.fittingSize.height > 0)
        }
    }
    @Test func nativeDisplayPolicyWithoutCapturingPixels() {
        _ = NSApplication.shared
        let displays = SelectionDisplay.current
        #expect(displays.count == NSScreen.screens.count)
        #expect(displays.allSatisfy { $0.frame.width > 0 && $0.frame.height > 0 })
        var captures = 0
        // Real display/cursor metadata, fake windows, and no screenshot or input synthesis.
        let controller = ScreenQuestionController(settings: SettingsModel(store: TemporarySettingsStore()),
            hotkey: MockGlobalHotkeyManager(), panelFactory: { SelectionTestPanel() }, automaticSampling: false,
            capture: { _ in captures += 1 }, report: { _ in })
        let started = controller.begin()
        #expect(started == displays.contains { $0.frame.contains(NSEvent.mouseLocation) })
        controller.cancel(); controller.stop()
        #expect(captures == 0)
    }
}

@MainActor private final class SelectionFixture {
    var displays = [SelectionDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800)),
                    SelectionDisplay(id: 2, frame: CGRect(x: -1000, y: -100, width: 1000, height: 800))]
    var cursor = CGPoint(x: 400, y: 300)
    var window: UInt32? = 42
    var blocked = false
}

/// Never displays a test selector on the user's desktop or intercepts actual mouse/keyboard input.
@MainActor private final class SelectionTestPanel: ScreenSelectionPanel {
    var shown = false
    override var isVisible: Bool { shown }
    override func makeKeyAndOrderFront(_ sender: Any?) { shown = true }
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
    override func close() { shown = false; super.close() }
}
