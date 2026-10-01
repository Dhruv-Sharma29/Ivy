import AppKit
import SwiftUI
import Combine
import IvyCore

/// Owns the companion panel: borderless, non-activating (clicking it never steals focus from the user's app),
/// on every Space, snapped to a corner. Shown only while the mood says so.
@MainActor
final class CompanionController: NSObject, NSWindowDelegate {
    private let environment: IvyAppEnvironment
    private var panel: NSPanel?
    private let presentation = CompanionPresentation()
    private var subscriptions: Set<AnyCancellable> = []
    private var mood: CompanionMood = .hidden
    /// "Hide for now": stays hidden until the mood changes to something new.
    private var hiddenMood: CompanionMood?
    private var snapTask: Task<Void, Never>?
    private var isPlacing = false

    init(environment: IvyAppEnvironment) {
        self.environment = environment
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
        let next = settings.companionEnabled ? CompanionMood.resolve(
            voice: e.liveCoordinator.state,
            chatThinking: e.brain.isThinking,
            approvalPending: e.brain.pendingConfirmation != nil || e.liveCoordinator.pendingConfirmation != nil,
            task: e.tasks.run,
            showWhileIdle: settings.companionShowWhileIdle) : .hidden
        if let hiddenMood, hiddenMood != next { self.hiddenMood = nil }
        mood = next
        guard mood.isVisible, hiddenMood == nil else {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? makePanel()
        if presentation.mood != mood { presentation.mood = mood }
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
                self.panel?.orderOut(nil)
            }))
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 280, height: 150),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.delegate = self
        panel.contentView = makeContent()
        self.panel = panel
        return panel
    }

    private func place(_ panel: NSPanel, corner: CompanionCorner) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        isPlacing = true
        panel.setFrameOrigin(corner.origin(for: panel.frame.size, in: screen.visibleFrame))
        isPlacing = false
    }

    /// After a drag settles, snap to the nearest corner of that screen and remember it.
    func windowDidMove(_ notification: Notification) {
        guard !isPlacing, let panel else { return }
        snapTask?.cancel()
        snapTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let screen = panel.screen ?? NSScreen.main else { return }
            let corner = CompanionCorner.nearest(to: CGPoint(x: panel.frame.midX, y: panel.frame.midY), in: screen.visibleFrame)
            self.place(panel, corner: corner)
            if self.environment.settings.settings.companionCorner != corner {
                self.environment.settings.settings.companionCorner = corner
            }
        }
    }
}
