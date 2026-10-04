import AppKit
import Combine
import SwiftUI
import IvyCore

/// Owns a tiny click-through window. No event monitor, input synthesis or accessibility permission.
@MainActor
final class FloatingPointerController {
    private let settings: SettingsModel
    private let cursor: () -> CGPoint
    private let screens: () -> [CGRect]
    private let reduceMotion: () -> Bool
    private let panelFactory: () -> FloatingPointerPanel
    private let automaticSampling: Bool
    private var subscriptions: Set<AnyCancellable> = []
    private var panel: FloatingPointerPanel?
    private var placement = FloatingPointerPlacement()
    private var sampling: Task<Void, Never>?
    private var color: FloatingPointerColor?
    private var sleeping = false
    private var inactive = false
    private var stopped = false
    private(set) var isTracking = false

    init(settings: SettingsModel, cursor: @escaping () -> CGPoint = { NSEvent.mouseLocation },
         screens: @escaping () -> [CGRect] = { NSScreen.screens.map(\.frame) },
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         panelFactory: @escaping () -> FloatingPointerPanel = {
             FloatingPointerPanel(contentRect: CGRect(origin: .zero, size: FloatingPointerPlacement.size),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
         }, automaticSampling: Bool = true,
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         notifications: NotificationCenter = .default) {
        self.settings = settings
        self.cursor = cursor
        self.screens = screens
        self.reduceMotion = reduceMotion
        self.panelFactory = panelFactory
        self.automaticSampling = automaticSampling
        settings.$settings.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification,
                     NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
            workspaceNotifications.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.workspaceChanged(name)
            }.store(in: &subscriptions)
        }
        notifications.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refresh() }
            .store(in: &subscriptions)
        refresh()
    }

    deinit { sampling?.cancel() }

    /// Explicit teardown disconnects observers as well as the sampling loop.
    func stop() {
        stopped = true
        subscriptions.removeAll()
        hide()
        panel?.close()
        panel = nil
    }

    private func workspaceChanged(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification: sleeping = true
        case NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification: sleeping = false
        case NSWorkspace.sessionDidResignActiveNotification: inactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification: inactive = false
        default: break // Display accessibility changes are handled by refresh below.
        }
        refresh()
    }

    func refresh() {
        guard sample() else { return }
        guard automaticSampling, sampling == nil else { return }
        sampling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(33)) }
                catch { return } // Cancellation is the normal stop/hide path.
                guard !Task.isCancelled, self?.sample() == true else { return }
            }
        }
    }

    @discardableResult
    func sample() -> Bool {
        let preferences = settings.settings
        guard !stopped, !sleeping, !inactive, preferences.companionEnabled,
              preferences.floatingPointerEnabled, !reduceMotion(),
              let frame = placement.update(cursor: cursor(), screens: screens(), reduceMotion: false) else {
            hide()
            return false
        }
        let window = panel ?? makePanel()
        if color != preferences.floatingPointerColor {
            color = preferences.floatingPointerColor
            window.contentView = NSHostingView(rootView: FloatingPointerView(color: preferences.floatingPointerColor))
        }
        if window.frame != frame { window.setFrame(frame, display: false) }
        if !window.isVisible { window.orderFrontRegardless() }
        isTracking = true
        return true
    }

    private func hide() {
        sampling?.cancel()
        sampling = nil
        isTracking = false
        placement.reset()
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingPointerPanel {
        let window = panelFactory()
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel = window
        return window
    }
}

class FloatingPointerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct FloatingPointerView: View {
    let color: FloatingPointerColor
    var body: some View {
        FloatingPointerGlyph()
            .fill(color.tint)
            .overlay(FloatingPointerGlyph().stroke(.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.65), radius: 2, y: 1)
            .frame(width: 32, height: 32)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct FloatingPointerGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            // A folded leaf with a directional tip, rather than a second standard mouse cursor.
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.18))
            path.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.86, y: rect.midY),
                              control: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.08))
            path.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.82),
                              control: CGPoint(x: rect.minX + rect.width * 0.76, y: rect.minY + rect.height * 0.92))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.midY))
            path.closeSubpath()
        }
    }
}

extension FloatingPointerColor {
    var title: String {
        switch self {
        case .blue: "Blue"
        case .green: "Green"
        case .amber: "Amber"
        case .red: "Red"
        }
    }
    var tint: Color {
        switch self {
        case .blue: .blue
        case .green: .green
        case .amber: .orange
        case .red: .red
        }
    }
}
