import AppKit
import SwiftUI
import Testing
@testable import Ivy
@testable import IvyCore

@MainActor
@Suite("Native floating pointer", .serialized)
struct FloatingPointerControllerTests {
    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(predicate())
    }

    @Test("opt-in, color updates and hide preserve click-through non-activating input")
    func settingsLifecycle() async throws {
        _ = NSApplication.shared
        let settings = SettingsModel(store: TemporarySettingsStore())
        let panel = PointerTestPanel()
        let source = PointerSource()
        var creations = 0
        let controller = FloatingPointerController(settings: settings, cursor: { source.point }, screens: { source.screens },
            reduceMotion: { source.reduced }, panelFactory: { creations += 1; return panel }, automaticSampling: false)
        defer { controller.stop() }
        // NSPanel starts with an empty native content view; factory calls prove no pointer was created.
        #expect(!controller.isTracking && !panel.isVisible && creations == 0)
        settings.settings.floatingPointerEnabled = true
        try await waitFor { controller.isTracking }
        #expect(panel.isVisible && panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain)
        #expect(!panel.isOpaque && !panel.hasShadow && !panel.hidesOnDeactivate && panel.level == .statusBar)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.frame.size == FloatingPointerPlacement.size)
        #expect(!panel.frame.contains(source.point))
        let initial = panel.frame
        #expect(controller.sample() && panel.frame == initial)
        for color in FloatingPointerColor.allCases {
            settings.settings.floatingPointerColor = color
            try await waitFor { (panel.contentView as? NSHostingView<FloatingPointerView>)?.rootView.color == color }
        }
        source.point = CGPoint(x: 500, y: 500)
        #expect(controller.sample() && panel.frame != initial)
        settings.settings.companionEnabled = false
        try await waitFor { !controller.isTracking && !panel.isVisible }
        settings.settings.companionEnabled = true
        try await waitFor { controller.isTracking }
        settings.settings.floatingPointerEnabled = false
        try await waitFor { !controller.isTracking && !panel.isVisible }
        settings.settings.floatingPointerEnabled = true
        try await waitFor { controller.isTracking }
        controller.stop()
        controller.refresh()
        #expect(!controller.sample() && !panel.isVisible && panel.closed)
        settings.settings.floatingPointerEnabled = false
    }

    @Test("sleep, session changes, Reduce Motion and missing displays stop following and can recover")
    func systemLifecycle() async throws {
        _ = NSApplication.shared
        var preferences = IvySettings.defaults
        preferences.floatingPointerEnabled = true
        let settings = SettingsModel(store: TemporarySettingsStore(preferences))
        let panel = PointerTestPanel()
        let source = PointerSource()
        let workspace = NotificationCenter(), notifications = NotificationCenter()
        let controller = FloatingPointerController(settings: settings, cursor: { source.point }, screens: { source.screens },
            reduceMotion: { source.reduced }, panelFactory: { panel }, automaticSampling: false,
            workspaceNotifications: workspace, notifications: notifications)
        defer { controller.stop() }
        #expect(controller.isTracking)
        for (sleep, wake) in [(NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification),
                              (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification),
                              (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification)] {
            workspace.post(name: sleep, object: nil)
            try await waitFor { !controller.isTracking && !panel.isVisible }
            workspace.post(name: wake, object: nil)
            try await waitFor { controller.isTracking && panel.isVisible }
        }
        source.reduced = true
        workspace.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        try await waitFor { !controller.isTracking && !panel.isVisible }
        source.reduced = false
        workspace.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        try await waitFor { controller.isTracking }
        source.screens = []
        #expect(!controller.sample())
        source.screens = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        notifications.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await waitFor { controller.isTracking }
    }

    @Test("the real sampling loop cancels while hidden and restarts only after enabling")
    func samplingLoop() async throws {
        _ = NSApplication.shared
        var preferences = IvySettings.defaults
        preferences.floatingPointerEnabled = true
        let settings = SettingsModel(store: TemporarySettingsStore(preferences))
        let panel = PointerTestPanel(), source = PointerSource()
        var reads = 0
        var controller: FloatingPointerController? = FloatingPointerController(settings: settings,
            cursor: { reads += 1; return source.point }, screens: { source.screens }, reduceMotion: { false }, panelFactory: { panel })
        source.point = CGPoint(x: 500, y: 500)
        try await waitFor { panel.frame.minX > 300 && reads > 2 }
        settings.settings.floatingPointerEnabled = false
        try await waitFor { controller?.isTracking == false }
        let hiddenReads = reads
        try await Task.sleep(for: .milliseconds(90))
        #expect(reads == hiddenReads, "hidden idle must not sample the cursor")
        settings.settings.floatingPointerEnabled = true
        try await waitFor { controller?.isTracking == true && reads > hiddenReads }
        source.screens = []
        try await waitFor { controller?.isTracking == false }
        let missingReads = reads
        try await Task.sleep(for: .milliseconds(90))
        #expect(reads == missingReads)
        source.screens = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
        controller?.refresh()
        try await waitFor { controller?.isTracking == true }
        controller?.stop()
        controller = nil
        let stoppedReads = reads
        try await Task.sleep(for: .milliseconds(90))
        #expect(reads == stoppedReads && !panel.isVisible)
    }

    @Test("pointer geometry and color previews render as original vector shapes")
    func vectorRendering() {
        _ = NSApplication.shared
        let rect = CGRect(x: 0, y: 0, width: 32, height: 32)
        let path = FloatingPointerGlyph().path(in: rect)
        #expect(rect.contains(path.boundingRect) && !path.isEmpty)
        #expect(Set(FloatingPointerColor.allCases.map(\.title)) == ["Blue", "Green", "Amber", "Red"])
        for color in FloatingPointerColor.allCases {
            let host = NSHostingView(rootView: FloatingPointerView(color: color))
            host.frame = rect
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize == FloatingPointerPlacement.size)
            #expect(host.bitmapImageRepForCachingDisplay(in: rect) != nil)
        }
    }
}

@MainActor
private final class PointerSource {
    var point = CGPoint(x: 200, y: 300)
    var screens = [CGRect(x: 0, y: 0, width: 1000, height: 800)]
    var reduced = false
}

/// Records native window policy without putting a fixture on the user's desktop.
@MainActor
private final class PointerTestPanel: FloatingPointerPanel {
    private var shown = false
    var closed = false
    init() {
        super.init(contentRect: CGRect(origin: .zero, size: FloatingPointerPlacement.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }
    override var isVisible: Bool { shown }
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
    override func close() { closed = true; shown = false; super.close() }
}
