import AppKit
import SwiftUI
import Combine
import IvyCore

/// Owns Ivy's main window. AppKit-managed so it opens only on request (a SwiftUI `Window` scene would open at
/// launch on macOS 14) and so opening/closing it drives the Dock icon through `AppRouter`.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    static var shared: MainWindowController?

    private let router: AppRouter
    private let makeRoot: () -> AnyView
    private var window: NSWindow?
    private var promptSubscription: AnyCancellable?

    init(router: AppRouter, proactive: ProactiveEngine, makeRoot: @escaping () -> AnyView) {
        self.router = router
        self.makeRoot = makeRoot
        super.init()
        router.applyPresence = { presence in
            NSApp.setActivationPolicy(presence == .regular ? .regular : .accessory)
        }
        if router.presence == .regular {
            NSApp.setActivationPolicy(.regular)
        }
        // Opening a proactive notification that carries a suggestion brings the window up to show it.
        promptSubscription = proactive.$pendingPrompt
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.show() }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        if !window.isVisible {
            router.mainWindowDidOpen()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Ivy"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: makeRoot())
        window.minSize = NSSize(width: 420, height: 420)
        if !window.setFrameUsingName("IvyMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("IvyMainWindow")
        window.delegate = self
        self.window = window
        return window
    }

    func windowWillClose(_ notification: Notification) {
        router.mainWindowDidClose()
    }
}
