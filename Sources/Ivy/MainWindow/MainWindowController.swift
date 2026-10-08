import AppKit
import SwiftUI
import Combine
import IvyCore

/// Routes hotkeys, the companion and notifications to the same native SwiftUI window.
@MainActor
final class MainWindowController: ObservableObject {
    static var shared: MainWindowController?
    var openWindow: (() -> Void)?
    private var promptSubscription: AnyCancellable?
    private var windowCloseSubscription: AnyCancellable?
    private weak var window: NSWindow?
    private let onBackground: () -> Void
    @Published private(set) var isWorkingInBackground = false

    init(proactive: ProactiveEngine, startsInBackground: Bool = false, onBackground: @escaping () -> Void) {
        self.onBackground = onBackground
        self.isWorkingInBackground = startsInBackground
        promptSubscription = proactive.$pendingPrompt
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !self.isWorkingInBackground else { return }
                self.show()
            }
    }

    /// Track only the workspace; Settings, the command bar and companion are independent windows.
    func register(window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // AppKit emits this on the main thread. Switch mode before SwiftUI dismisses window sheets.
        windowCloseSubscription = NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak self] _ in self?.enterBackground() }
        // macOS 14 lacks suppressed scene launch; hide its automatically created workspace.
        if isWorkingInBackground {
            window.orderOut(nil)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window, self.isWorkingInBackground else { return }
                window.orderOut(nil)
            }
        }
    }

    /// Hide UI without destroying its drafts or cancelling app-owned voice/chat/task work.
    func workInBackground() {
        enterBackground()
        window?.orderOut(nil)
    }

    private func enterBackground() {
        isWorkingInBackground = true
        onBackground()
    }

    func show() {
        isWorkingInBackground = false
        openWindow?()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// Installs the scene's native open action for routes that originate outside SwiftUI.
struct IvyWindowRoot: View {
    let environment: IvyAppEnvironment
    @ObservedObject var windowController: MainWindowController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainWindowView(
            brain: environment.brain, library: environment.library,
            voiceManager: environment.voiceManager, liveVoiceCoordinator: environment.liveCoordinator,
            proactive: environment.proactive, attachments: environment.attachments,
            tasks: environment.tasks, workspaces: environment.workspaces, router: environment.router,
            windowController: windowController
        )
        .background(WorkspaceWindowReader { windowController.register(window: $0) })
        .onAppear {
            windowController.openWindow = { openWindow(id: "main") }
            environment.router.mainWindowDidOpen()
        }
        .onDisappear { environment.router.mainWindowDidClose() }
    }
}

/// SwiftUI owns the workspace window/delegate; this noninteractive view only reports its identity.
struct WorkspaceWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> WorkspaceWindowSurface {
        let view = WorkspaceWindowSurface()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ view: WorkspaceWindowSurface, context: Context) {
        view.onWindow = onWindow
        if let window = view.window { onWindow(window) }
    }
}

@MainActor
final class WorkspaceWindowSurface: NSView {
    var onWindow: ((NSWindow) -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { onWindow?(window) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
