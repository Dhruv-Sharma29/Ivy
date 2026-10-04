import AppKit
import SwiftUI
import Combine
import IvyCore

/// Owns the companion panel: borderless, non-activating (clicking it never steals focus from the user's app),
/// on every Space, freely draggable with remembered placement. Shown only while the mood says so.
@MainActor
final class CompanionController: NSObject {
    private let environment: IvyAppEnvironment
    private let panelFactory: () -> CompanionPanel
    private var panel: CompanionPanel?
    private let presentation = CompanionPresentation()
    private var subscriptions: Set<AnyCancellable> = []
    private var mood: CompanionMood = .hidden
    /// "Hide for now": stays hidden until the mood changes to something new.
    private var hiddenMood: CompanionMood?
    private var contentFrame = CGRect(origin: .zero, size: CompanionView.panelSize)

    init(environment: IvyAppEnvironment, panelFactory: @escaping () -> CompanionPanel = {
        CompanionPanel(contentRect: CGRect(origin: .zero, size: CompanionView.panelSize),
                       styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    }) {
        self.environment = environment
        self.panelFactory = panelFactory
        super.init()
        let e = environment
        // Any of these changing can change the mood; recompute on the next main-actor turn (@Published fires early).
        let triggers: [AnyPublisher<Void, Never>] = [
            e.liveCoordinator.$state.map { _ in () }.eraseToAnyPublisher(),
            e.liveCoordinator.$pendingConfirmation.map { _ in () }.eraseToAnyPublisher(),
            e.liveCoordinator.$caption.map { _ in () }.eraseToAnyPublisher(),
            e.brain.$isThinking.map { _ in () }.eraseToAnyPublisher(),
            e.brain.$pendingConfirmation.map { _ in () }.eraseToAnyPublisher(),
            e.tasks.$run.map { _ in () }.eraseToAnyPublisher(),
            e.settings.$settings.map { _ in () }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(triggers)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.update() }
            .store(in: &subscriptions)
    }

    private func update() {
        let e = environment
        let settings = e.settings.settings
        let approval = CompanionApproval.pending(chat: e.brain.pendingConfirmation, live: e.liveCoordinator.pendingConfirmation)
        if presentation.approval != approval {
            // A fresh request must reappear even after hiding a previous approval with the same mood.
            if approval != nil { hiddenMood = nil }
            presentation.approval = approval
        }
        let next = settings.companionEnabled ? CompanionMood.resolve(
            voice: e.liveCoordinator.state,
            chatThinking: e.brain.isThinking,
            approvalPending: e.brain.pendingConfirmation != nil || e.liveCoordinator.pendingConfirmation != nil,
            task: e.tasks.run,
            showWhileIdle: settings.companionShowWhileIdle) : .hidden
        if let hiddenMood, hiddenMood != next { self.hiddenMood = nil }
        mood = next
        let displayedMood = hiddenMood == nil ? next : .hidden
        if presentation.mood != displayedMood { presentation.mood = displayedMood }
        panel?.allowsKeyboard = approval != nil
        guard mood.isVisible, hiddenMood == nil else {
            presentation.isMoving = false
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        panel.allowsKeyboard = approval != nil
        let size = CompanionView.panelSize(hasApproval: approval != nil)
        if panel.frame.size != size {
            var frame = panel.frame
            frame.size = size
            panel.setFrame(frame, display: false)
            panel.contentView?.layoutSubtreeIfNeeded()
            place(panel, corner: settings.companionCorner)
        }
        if presentation.caption != e.liveCoordinator.caption { presentation.caption = e.liveCoordinator.caption }
        if !panel.isVisible {
            place(panel, corner: settings.companionCorner)
            panel.orderFrontRegardless()
        }
    }

    private func makeContent() -> NSView {
        let e = environment
        return NSHostingView(rootView: CompanionView(
            presentation: presentation,
            meter: e.liveCoordinator.levelMeter,
            onOpen: { MainWindowController.shared?.show() },
            onEndVoice: { Task { await e.liveCoordinator.stopSession() } },
            onStopTask: { e.tasks.cancel() },
            onHide: { [weak self] in
                guard let self else { return }
                self.hiddenMood = self.mood
                self.presentation.mood = .hidden
                self.presentation.isMoving = false
                self.panel?.orderOut(nil)
            }, onDrop: { [weak self] in self?.rememberPosition() },
              onContentLayout: { [weak self] in self?.contentDidLayout($0) },
              onConfirm: { approval, approved in
                  approval.respond(approved: approved, brain: e.brain, liveCoordinator: e.liveCoordinator)
              }))
    }

    private func makePanel() -> CompanionPanel {
        let panel = panelFactory()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = false // The native drag handle distinguishes a click from a drag.
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true // The same request may also be visible in the main-window sheet.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        self.panel = panel
        panel.contentView = makeContent()
        return panel
    }

    private func place(_ panel: NSPanel, corner: CompanionCorner) {
        panel.contentView?.layoutSubtreeIfNeeded()
        if let placement = environment.settings.settings.companionPlacement {
            let savedScreen = NSScreen.screens.first { Self.displayID($0) == placement.displayID }
            if let screen = savedScreen ?? NSScreen.main {
                panel.setFrameOrigin(placement.origin(panelSize: panel.frame.size, visibleFrame: screen.visibleFrame, contentFrame: contentFrame))
                return
            }
        }
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let point = corner.origin(for: contentFrame.size, in: screen.visibleFrame)
        panel.setFrameOrigin(CGPoint(x: point.x - contentFrame.minX, y: point.y - contentFrame.minY))
    }

    /// A caption or status can change the visible width. Preserve its relative placement, not its empty margin.
    private func contentDidLayout(_ frame: CGRect) {
        guard frame != contentFrame else { return }
        contentFrame = frame
        guard let panel, panel.isVisible, !presentation.isMoving else { return }
        place(panel, corner: environment.settings.settings.companionCorner)
    }

    /// Keep the dropped location; only clamp to the usable screen area, never snap back to a corner.
    private func rememberPosition() {
        guard let panel else { return }
        let center = CGPoint(x: panel.frame.minX + contentFrame.midX, y: panel.frame.minY + contentFrame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(center) }) ?? panel.screen ?? NSScreen.main else { return }
        let placement = CompanionPlacement(origin: panel.frame.origin, panelSize: panel.frame.size,
                                           visibleFrame: screen.visibleFrame, displayID: Self.displayID(screen), contentFrame: contentFrame)
        panel.setFrameOrigin(placement.origin(panelSize: panel.frame.size, visibleFrame: screen.visibleFrame, contentFrame: contentFrame))
        environment.settings.settings.companionPlacement = placement
    }

    private static func displayID(_ screen: NSScreen) -> UInt32 {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

/// Allow deliberate keyboard review while keeping ordinary companion clicks non-activating.
class CompanionPanel: NSPanel {
    var allowsKeyboard = false
    override var canBecomeKey: Bool { allowsKeyboard }
    override var canBecomeMain: Bool { false }
}
