import AppKit
import SwiftUI

/// A click stays a click; only motion beyond four points becomes a drag.
struct CompanionDragSession {
    let pointer: CGPoint
    let origin: CGPoint
    private(set) var moved = false

    mutating func update(pointer: CGPoint) -> CGPoint? {
        let dx = pointer.x - self.pointer.x
        let dy = pointer.y - self.pointer.y
        guard dx.isFinite, dy.isFinite else { return nil }
        guard moved || hypot(dx, dy) >= 4 else { return nil }
        moved = true
        return CGPoint(x: origin.x + dx, y: origin.y + dy)
    }
}

/// Native mouse tracking avoids the SwiftUI button swallowing drags or opening Ivy on release.
struct CompanionDragHandle: NSViewRepresentable {
    let onOpen: () -> Void
    let onEndVoice: () -> Void
    let onStopTask: () -> Void
    let onHide: () -> Void
    let onMoving: (Bool) -> Void
    let onDrop: () -> Void
    var onLayout: (CGRect) -> Void = { _ in }

    func makeNSView(context: Context) -> CompanionDragSurface {
        let view = CompanionDragSurface()
        view.setAccessibilityElement(false) // The enclosing SwiftUI button supplies the accessible action.
        view.toolTip = "Drag Ivy to move. Click to open. Right-click for actions."
        view.installMenu()
        return view
    }

    func updateNSView(_ view: CompanionDragSurface, context: Context) {
        view.onOpen = onOpen
        view.onEndVoice = onEndVoice
        view.onStopTask = onStopTask
        view.onHide = onHide
        view.onMoving = onMoving
        view.onDrop = onDrop
        view.onLayout = onLayout
        view.reportContentFrame()
    }
}

@MainActor
final class CompanionDragSurface: NSView {
    var onOpen: (() -> Void)?
    var onEndVoice: (() -> Void)?
    var onStopTask: (() -> Void)?
    var onHide: (() -> Void)?
    var onMoving: ((Bool) -> Void)?
    var onDrop: (() -> Void)?
    var onLayout: ((CGRect) -> Void)?
    private var drag: CompanionDragSession?
    private var reportedFrame: CGRect?

    override func layout() {
        super.layout()
        reportContentFrame()
    }

    func reportContentFrame() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let frame = convert(bounds, to: nil) // AppKit window coordinates, with a bottom-left origin.
        guard frame != reportedFrame else { return }
        reportedFrame = frame
        onLayout?(frame)
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        begin(pointer: window.convertPoint(toScreen: event.locationInWindow), origin: window.frame.origin)
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        if let origin = move(pointer: window.convertPoint(toScreen: event.locationInWindow)) {
            window.setFrameOrigin(origin)
            NSCursor.closedHand.set()
        }
    }

    override func mouseUp(with event: NSEvent) {
        finish()
        NSCursor.openHand.set()
    }

    // Factored tracking can be tested without moving the user's mouse or windows.
    func begin(pointer: CGPoint, origin: CGPoint) { drag = CompanionDragSession(pointer: pointer, origin: origin) }

    func move(pointer: CGPoint) -> CGPoint? {
        let wasMoving = drag?.moved == true
        let origin = drag?.update(pointer: pointer)
        if !wasMoving, origin != nil { onMoving?(true) }
        return origin
    }

    func finish() {
        guard let drag else { return }
        self.drag = nil
        if drag.moved { onMoving?(false); onDrop?() } else { onOpen?() }
    }

    func installMenu() {
        let menu = NSMenu()
        for (title, action) in [("Open Ivy", #selector(openIvy)), ("End Voice Session", #selector(endVoice)),
                                ("Stop Task", #selector(stopTask)), ("Hide for Now", #selector(hideIvy))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        self.menu = menu
    }

    @objc func openIvy() { onOpen?() }
    @objc func endVoice() { onEndVoice?() }
    @objc func stopTask() { onStopTask?() }
    @objc func hideIvy() { onHide?() }
}
