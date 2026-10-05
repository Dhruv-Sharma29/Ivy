import AppKit
import Combine
import SwiftUI
import IvyCore

struct SelectionDisplay: Equatable {
    let id: UInt32
    let frame: CGRect
    static var current: [SelectionDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return SelectionDisplay(id: id, frame: screen.frame)
        }
    }
}

/// The only input-intercepting pointer surface: an explicit, cancellable screen-selection session.
@MainActor
final class ScreenQuestionController {
    private let settings: SettingsModel
    private let hotkey: any GlobalHotkeyManaging
    private let displays: () -> [SelectionDisplay]
    private let cursor: () -> CGPoint
    private let frontWindow: () -> UInt32?
    private let blocked: () -> Bool
    private let capture: (ScreenRegionSelection) async -> Void
    private let report: (String) -> Void
    private let panelFactory: () -> ScreenSelectionPanel
    private let automaticSampling: Bool
    private var subscriptions: Set<AnyCancellable> = []
    private var panels: [(SelectionDisplay, ScreenSelectionPanel, ScreenSelectionCanvas)] = []
    private var sampling: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var expectedWindow: UInt32?
    private var previousCursor = CGPoint.zero
    private var activeDisplay: SelectionDisplay?
    private var held = false
    private var voiceSelection = false
    private var stopped = false
    private var sleeping = false
    private var inactive = false
    private var registered: ScreenQuestionShortcut?
    private(set) var gesture = ScreenSelectionGesture()
    private(set) var isSelecting = false
    var onCancelled: (() -> Void)?
    var onInvalidated: (() -> Void)?
    var onVoiceRelease: (() -> Void)?

    init(settings: SettingsModel, hotkey: any GlobalHotkeyManaging = SystemGlobalHotkeyManager(),
         displays: @escaping () -> [SelectionDisplay] = { SelectionDisplay.current },
         cursor: @escaping () -> CGPoint = { NSEvent.mouseLocation },
         frontWindow: @escaping () -> UInt32? = { ScreenQuestionController.frontOtherWindowID() },
         blocked: @escaping () -> Bool = { false },
         panelFactory: @escaping () -> ScreenSelectionPanel = { ScreenSelectionPanel() },
         automaticSampling: Bool = true,
         workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
         notifications: NotificationCenter = .default,
         capture: @escaping (ScreenRegionSelection) async -> Void, report: @escaping (String) -> Void) {
        self.settings = settings; self.hotkey = hotkey; self.displays = displays; self.cursor = cursor
        self.frontWindow = frontWindow; self.blocked = blocked; self.panelFactory = panelFactory
        self.automaticSampling = automaticSampling; self.capture = capture; self.report = report
        settings.$settings.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.refreshShortcut() }.store(in: &subscriptions)
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspaceNotifications.publisher(for: name).receive(on: DispatchQueue.main).sink { [weak self] _ in
                switch name {
                case NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification: self?.sleeping = true
                case NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification: self?.sleeping = false
                case NSWorkspace.sessionDidResignActiveNotification: self?.inactive = true
                default: self?.inactive = false // The remaining observed event is sessionDidBecomeActive.
                }
                self?.invalidate()
            }.store(in: &subscriptions)
        }
        notifications.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.invalidate() }.store(in: &subscriptions)
        refreshShortcut()
    }

    deinit { sampling?.cancel(); captureTask?.cancel(); hotkey.unregister() }

    static func frontOtherWindowID() -> UInt32? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return windows.first {
            $0[kCGWindowLayer as String] as? Int == 0 && $0[kCGWindowOwnerPID as String] as? Int != Int(ProcessInfo.processInfo.processIdentifier)
        }?[kCGWindowNumber as String] as? UInt32
    }

    func refreshShortcut() {
        guard !stopped else { return }
        let desired = settings.settings.screenQuestionEnabled ? settings.settings.screenQuestionShortcut : nil
        guard desired != registered else { return }
        invalidate(); hotkey.unregister(); registered = nil
        guard let desired, desired != .pushToTalk else { registered = desired; return }
        do {
            try hotkey.register(shortcut: desired.hotkey, onKeyDown: { [weak self] in
                Task { @MainActor in self?.begin(held: true) }
            }, onKeyUp: { [weak self] in Task { @MainActor in self?.release() } })
            registered = desired
        } catch { report("Screen-question shortcut unavailable: \(error.localizedDescription). Use Select area in Ivy's menu.") }
    }

    @discardableResult
    func begin(held: Bool = false, voice: Bool = false) -> Bool {
        guard !stopped, !sleeping, !inactive, !isSelecting else { return false }
        guard !blocked() else { report("Finish or stop Ivy's current request before selecting a screen area."); return false }
        cancel()
        let available = displays(), point = cursor()
        guard let active = available.first(where: { $0.frame.contains(point) }) else {
            report("No display is available for selection."); return false
        }
        expectedWindow = frontWindow(); activeDisplay = active; self.held = held
        voiceSelection = voice
        gesture = ScreenSelectionGesture(); gesture.move(point); previousCursor = point; isSelecting = true
        for display in available {
            let panel = panelFactory(), canvas = ScreenSelectionCanvas(frame: CGRect(origin: .zero, size: display.frame.size))
            canvas.onStart = { [weak self] point in self?.stroke(point, display: display, start: true) }
            canvas.onDrag = { [weak self] point in self?.stroke(point, display: display, start: false) }
            canvas.onKey = { [weak self] key in self?.key(key) }
            let hud = NSHostingView(rootView: ScreenSelectionToolbar(
                shortcut: settings.settings.screenQuestionShortcut.label, voice: voice,
                onMode: { [weak self] mode in self?.setMode(mode) },
                onFinish: { [weak self] in self?.finish() }, onCancel: { [weak self] in self?.cancel() }))
            hud.frame = canvas.toolbarFrame
            canvas.addSubview(hud)
            panel.contentView = canvas; panel.setFrame(display.frame, display: false)
            panels.append((display, panel, canvas))
            if display == active { panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(canvas) }
            else { panel.orderFrontRegardless() }
        }
        render()
        if automaticSampling {
            sampling = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(40)) } catch { return }
                    guard self?.sample() == true else { return }
                }
            }
        }
        return true
    }

    @discardableResult
    func sample() -> Bool {
        guard isSelecting else { return false }
        guard !blocked(), panels.map(\.0) == displays() else { cancel(); return false }
        // A lost Carbon key-up must never leave an overlay blocking the user's desktop.
        if held, hotkey.isShortcutHeld == false { finish(); return false }
        if gesture.points.isEmpty, cursor() != previousCursor {
            let point = cursor()
            previousCursor = point
            if let display = displays().first(where: { $0.frame.contains(point) }),
               let canvas = panels.first(where: { $0.0 == display })?.2 {
                let local = CGPoint(x: point.x - display.frame.minX, y: point.y - display.frame.minY)
                if !canvas.toolbarFrame.contains(local) { activeDisplay = display; gesture.move(point) }
            }
            render()
        }
        return true
    }

    func stroke(_ point: CGPoint, display: SelectionDisplay, start: Bool) {
        guard isSelecting, panels.contains(where: { $0.0 == display }) else { return }
        let global = CGPoint(x: point.x + display.frame.minX, y: point.y + display.frame.minY)
        if start { activeDisplay = display; gesture.begin(global) }
        else if activeDisplay == display { gesture.drag(global) }
        render()
    }

    func setMode(_ mode: ScreenSelectionGesture.Mode) {
        let hover = gesture.hover
        gesture = ScreenSelectionGesture(); gesture.mode = mode; gesture.move(hover); render()
    }

    func key(_ code: UInt16) {
        switch code {
        case 53: cancel()
        case 36, 76: finish()
        case 123, 124, 125, 126:
            guard isSelecting else { return }
            var point = gesture.hover
            if code == 123 { point.x -= 10 }; if code == 124 { point.x += 10 }
            if code == 125 { point.y -= 10 }; if code == 126 { point.y += 10 }
            gesture.move(point); render()
        default: break // Selection consumes other keys; none are forwarded to the target app.
        }
    }

    func release() { if held && isSelecting { finish() } }

    func finish() {
        if voiceSelection, isSelecting { onVoiceRelease?(); return }
        guard let selection = takeSelection() else { return }
        captureTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await capture(selection)
        }
    }

    /// Voice owns capture/submission after this closes the selector; text stages the crop in Quick chat.
    func takeSelection() -> ScreenRegionSelection? {
        guard isSelecting, let display = activeDisplay else { return nil }
        guard !blocked(), displays() == panels.map(\.0), frontWindow() == expectedWindow,
              let selection = ScreenRegionSelection(displayID: display.id, screen: display.frame, rect: gesture.crop(in: display.frame)) else {
            cancel(); report("The screen changed. Select the area again."); return nil
        }
        closeSelection()
        return selection
    }

    func cancel() {
        let wasSelecting = isSelecting
        captureTask?.cancel(); captureTask = nil; closeSelection()
        if wasSelecting { onCancelled?() }
    }
    private func invalidate() { cancel(); onInvalidated?() }
    func stop() { stopped = true; cancel(); hotkey.unregister(); registered = nil; subscriptions.removeAll() }

    private func closeSelection() {
        isSelecting = false; held = false; voiceSelection = false; sampling?.cancel(); sampling = nil
        for (_, panel, _) in panels { panel.orderOut(nil); panel.close() }
        panels = []; activeDisplay = nil; expectedWindow = nil
    }

    private func render() {
        for (display, _, canvas) in panels {
            canvas.crop = display == activeDisplay ? gesture.crop(in: display.frame).offsetBy(dx: -display.frame.minX, dy: -display.frame.minY) : nil
            canvas.stroke = display == activeDisplay && gesture.mode == .freehand ? gesture.points.map {
                CGPoint(x: $0.x - display.frame.minX, y: $0.y - display.frame.minY)
            } : []
            canvas.needsDisplay = true
        }
    }
}

class ScreenSelectionPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false; isOpaque = false; backgroundColor = .clear; hasShadow = false
        animationBehavior = .none
        level = .screenSaver; hidesOnDeactivate = false; acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class ScreenSelectionCanvas: NSView {
    var crop: CGRect?
    var stroke: [CGPoint] = []
    var onStart: (CGPoint) -> Void = { _ in }
    var onDrag: (CGPoint) -> Void = { _ in }
    var onKey: (UInt16) -> Void = { _ in }
    var toolbarFrame: CGRect { CGRect(x: max(12, (bounds.width - 590) / 2), y: bounds.height - 100, width: min(590, bounds.width - 24), height: 84) }
    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { onStart(convert(event.locationInWindow, from: nil)) }
    override func mouseDragged(with event: NSEvent) { onDrag(convert(event.locationInWindow, from: nil)) }
    override func keyDown(with event: NSEvent) { onKey(event.keyCode) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.12).setFill(); bounds.fill()
        if let crop {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(roundedRect: crop, xRadius: 8, yRadius: 8)
            outline.lineWidth = 2; outline.setLineDash([6, 4], count: 2, phase: 0); outline.stroke()
        }
        if let first = stroke.first {
            let path = NSBezierPath(); path.move(to: first)
            stroke.dropFirst().forEach { path.line(to: $0) }
            path.lineWidth = 3; NSColor.white.setStroke(); path.stroke()
        }
    }
}

struct ScreenSelectionToolbar: View {
    let shortcut: String
    var voice = false
    let onMode: (ScreenSelectionGesture.Mode) -> Void
    let onFinish: () -> Void
    let onCancel: () -> Void
    var body: some View {
        VStack(spacing: 8) {
            Label(voice ? "Point or draw while speaking · release the voice key to ask" : "Hover or draw · Return attaches · Esc cancels", systemImage: "leaf")
                .font(.callout).foregroundStyle(.white)
            HStack {
                Button("Freehand") { onMode(.freehand) }
                Button("Rectangle") { onMode(.rectangle) }
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.escape, modifiers: [])
                Button(voice ? "Ask now" : "Attach area", action: onFinish).keyboardShortcut(.return, modifiers: [])
            }
            .controlSize(.small)
        }
        .padding(12).background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Ivy screen selection. Dashed bounds show the entire crop.")
        .preferredColorScheme(.dark)
    }
}
