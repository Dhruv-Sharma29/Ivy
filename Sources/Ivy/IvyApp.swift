import SwiftUI
import IvyCore

@main
struct IvyApp: App {
    @NSApplicationDelegateAdaptor(IvyAppDelegate.self) private var appDelegate
    @ObservedObject private var brain: IvyBrain
    @ObservedObject private var liveVoiceCoordinator: GeminiLiveVoiceCoordinator
    @ObservedObject private var settings: SettingsModel
    @ObservedObject private var wakeWord: WakeWordController
    @ObservedObject private var library: ConversationLibrary
    private let environment: IvyAppEnvironment
    private let mainWindowController: MainWindowController

    init() {
        self.init(environment: IvyAppEnvironment.production(annotationPresenter: AnnotationOverlay()))
        // Line-buffer diagnostics in development and release bundles.
        setvbuf(stdout, nil, _IOLBF, 0)
        CrashDiagnosticsCollector.shared.start()
    }

    /// The same app shell can be verified with isolated credentials and storage.
    init(environment: IvyAppEnvironment) {
        NSApplication.shared.setActivationPolicy(.accessory)
        if let icon = IvyLogoImage.appIcon { NSApplication.shared.applicationIconImage = icon }
        self._brain = ObservedObject(wrappedValue: environment.brain)
        self._liveVoiceCoordinator = ObservedObject(wrappedValue: environment.liveCoordinator)
        self._settings = ObservedObject(wrappedValue: environment.settings)
        self._wakeWord = ObservedObject(wrappedValue: environment.wakeWord)
        self._library = ObservedObject(wrappedValue: environment.library)
        // Audible cue that Ivy woke up and is now listening for the request (like Siri's chime).
        environment.wakeWord.onWake = { NSSound(named: "Tink")?.play() }
        IvyAppDelegate.shutdown = { await environment.shutdown() }
        let mainWindowController = MainWindowController(proactive: environment.proactive, startsInBackground: true) {
            IvyAppDelegate.companion?.showForBackground()
        }
        self.mainWindowController = mainWindowController
        MainWindowController.shared = mainWindowController
        IvyAppDelegate.openURL = { url in
            guard AppRouter.parse(url) != nil else { return }
            let busy = environment.brain.isThinking || environment.brain.pendingConfirmation != nil
                || environment.liveCoordinator.state.isLive || environment.liveCoordinator.pendingConfirmation != nil
                || environment.tasks.run?.isActive == true || environment.attachments.isWorking
            environment.router.open(url, library: environment.library, isBusy: busy)
            MainWindowController.shared?.show()
        }
        // The screen-help hotkey attached a capture: show it in the window, ready for the user to send.
        environment.onScreenHelp = { MainWindowController.shared?.show() }
        // Phase 17b: the on-screen companion and the ⌃⌥⌘K command bar.
        IvyAppDelegate.companion = CompanionController(environment: environment)
        // Phase 17c: the introduction on a fresh install only (existing installs are marked done at launch).
        OnboardingWindowController.shared = OnboardingWindowController(model: environment.onboarding)
        self.environment = environment
        let commandBar = CommandBarController(environment: environment)
        IvyAppDelegate.commandBar = commandBar
        environment.onCommandBar = { commandBar.toggle() }
        environment.observeSystemEvents()
        let needsOnboarding = environment.needsOnboarding
        DispatchQueue.main.async {
            if needsOnboarding { OnboardingWindowController.shared?.show() }
        }
    }

    var body: some Scene {
        Window("Ivy", id: "main") {
            IvyWindowRoot(environment: environment, windowController: mainWindowController)
        }
        .defaultSize(width: 1080, height: 760)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .ivyCompanionLaunch()
        .commands {
            SidebarCommands()
            IvyConversationCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") {
                    library.newConversation()
                    MainWindowController.shared?.show()
                }
                .keyboardShortcut("n")
                Button("Open Ivy") { MainWindowController.shared?.show() }
                    .keyboardShortcut("o")
                Button("Work in Background") { MainWindowController.shared?.workInBackground() }
            }
        }

        MenuBarExtra {
            Button("Open Ivy") { MainWindowController.shared?.show() }
                .keyboardShortcut("o")
            Button("Work in Background") { MainWindowController.shared?.workInBackground() }
            Button("New Conversation") {
                library.newConversation()
                MainWindowController.shared?.show()
            }
            Divider()
            if liveVoiceCoordinator.state.isLive {
                Button("End Voice Session") { Task { await liveVoiceCoordinator.stopSession() } }
            }
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit Ivy") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            // Keep the app recognizable while requests, approvals and errors change its state.
            IvyMenuBarLabel(windowController: mainWindowController)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsWindowView(environment: environment, settings: settings, wakeWord: wakeWord)
        }
        .windowStyle(.hiddenTitleBar)
        .ivyCompanionLaunch()
    }
}

/// Install workspace routing before the workspace exists; companion/menu actions must work on first launch.
struct IvyMenuBarLabel: View {
    let windowController: MainWindowController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "leaf")
            .accessibilityLabel("Ivy")
            .onAppear { windowController.openWindow = { openWindow(id: "main") } }
    }
}

extension Scene {
    func ivyCompanionLaunch() -> some Scene {
        if #available(macOS 15, *) {
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(
                self.defaultLaunchBehavior(.suppressed).restorationBehavior(.disabled)))
        } else {
            return SceneBuilder.buildOptional(SceneBuilder.buildLimitedAvailability(self))
        }
    }
}

struct IvyConversationCommands: Commands {
    @FocusedBinding(\.ivyChatInstructions) private var editingInstructions
    var body: some Commands {
        CommandMenu("Conversation") {
            Button("Chat Instructions…") { editingInstructions = true }
                .disabled(editingInstructions == nil)
        }
    }
}

/// Delays quit until Live, playback, the hotkey and any pending approval are torn down and history is saved.
final class IvyAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var shutdown: (@MainActor () async -> Void)?
    /// Kept alive for the app's lifetime.
    @MainActor static var companion: CompanionController?
    @MainActor static var commandBar: CommandBarController?
    @MainActor static var openURL: (@MainActor (URL) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        // Handle one recognized destination; a URL batch must not create several empty conversations.
        if let url = urls.first(where: { AppRouter.parse($0) != nil }) { Self.openURL?(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        MainWindowController.shared?.workInBackground()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared?.workInBackground()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown = Self.shutdown else { return .terminateNow }
        Self.shutdown = nil
        Task { @MainActor in
            await shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
