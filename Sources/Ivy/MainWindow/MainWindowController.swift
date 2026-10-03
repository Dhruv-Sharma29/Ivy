import AppKit
import SwiftUI
import Combine
import IvyCore

/// Routes hotkeys, the companion and notifications to the same native SwiftUI window.
@MainActor
final class MainWindowController {
    static var shared: MainWindowController?
    var openWindow: (() -> Void)?
    private var promptSubscription: AnyCancellable?

    init(proactive: ProactiveEngine) {
        promptSubscription = proactive.$pendingPrompt
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.show() }
    }

    func show() {
        openWindow?()
        NSApp.activate()
    }
}

/// Installs the scene's native open action for routes that originate outside SwiftUI.
struct IvyWindowRoot: View {
    let environment: IvyAppEnvironment
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainWindowView(
            brain: environment.brain, library: environment.library,
            voiceManager: environment.voiceManager, liveVoiceCoordinator: environment.liveCoordinator,
            proactive: environment.proactive, attachments: environment.attachments,
            tasks: environment.tasks, workspaces: environment.workspaces, router: environment.router
        )
        .onAppear {
            MainWindowController.shared?.openWindow = { openWindow(id: "main") }
            environment.router.mainWindowDidOpen()
        }
        .onDisappear { environment.router.mainWindowDidClose() }
    }
}
