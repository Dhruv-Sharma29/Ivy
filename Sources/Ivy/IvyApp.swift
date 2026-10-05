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

    init() {
        self.init(environment: IvyAppEnvironment.production(annotationPresenter: AnnotationOverlay()))
        // Line-buffer diagnostics in development and release bundles.
        setvbuf(stdout, nil, _IOLBF, 0)
        CrashDiagnosticsCollector.shared.start()
    }

    /// The same app shell can be verified with isolated credentials and storage.
    init(environment: IvyAppEnvironment) {
        NSApplication.shared.setActivationPolicy(.regular)
        if let icon = IvyLogoImage.appIcon { NSApplication.shared.applicationIconImage = icon }
        self._brain = ObservedObject(wrappedValue: environment.brain)
        self._liveVoiceCoordinator = ObservedObject(wrappedValue: environment.liveCoordinator)
        self._settings = ObservedObject(wrappedValue: environment.settings)
        self._wakeWord = ObservedObject(wrappedValue: environment.wakeWord)
        self._library = ObservedObject(wrappedValue: environment.library)
        // Audible cue that Ivy woke up and is now listening for the request (like Siri's chime).
        environment.wakeWord.onWake = { NSSound(named: "Tink")?.play() }
        IvyAppDelegate.shutdown = { await environment.shutdown() }
        MainWindowController.shared = MainWindowController(proactive: environment.proactive)
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
        IvyAppDelegate.floatingPointer = FloatingPointerController(settings: environment.settings)
        // Phase 17c: the introduction on a fresh install only (existing installs are marked done at launch).
        OnboardingWindowController.shared = OnboardingWindowController(model: environment.onboarding)
        self.environment = environment
        let commandBar = CommandBarController(environment: environment)
        IvyAppDelegate.commandBar = commandBar
        environment.onCommandBar = { commandBar.toggle() }
        let selector = ScreenQuestionController(settings: environment.settings,
            blocked: {
                environment.brain.isThinking || environment.attachments.isWorking || environment.tasks.run?.isActive == true
                    || environment.tasks.isDesktopControlActive
                    || environment.brain.pendingConfirmation != nil
                    || environment.liveCoordinator.pendingConfirmation != nil
            }, capture: { selection in
                let attachment = await environment.attachments.capture(selection: selection)
                guard !Task.isCancelled else { return }
                if let attachment { commandBar.showScreenQuestion(attachment) }
                else if environment.attachments.lastError != nil { commandBar.show() }
            }, report: { message in
                environment.attachments.reportCaptureError(message)
                commandBar.show()
            })
        IvyAppDelegate.screenQuestion = selector
        let live = environment.liveCoordinator
        var voiceSelection: ScreenRegionSelection?
        live.onPushToTalkContextBegin = { [weak environment, weak live] in
            guard let environment, environment.settings.settings.screenQuestionEnabled,
                  environment.settings.settings.screenQuestionShortcut == .pushToTalk else { return .audioOnly }
            guard live?.state.isLive == false else { return .cancel }
            return .screen
        }
        live.onPushToTalkContextReady = { [weak selector] in selector?.begin(voice: true) == true }
        live.onPushToTalkContextEnd = { [weak selector] in voiceSelection = selector?.takeSelection() }
        live.onPushToTalkContextRelease = { [weak environment, weak commandBar] in
            guard let environment, let selection = voiceSelection else { return nil }
            voiceSelection = nil
            let attachment = await environment.attachments.capture(selection: selection, stage: false)
            if attachment == nil, !Task.isCancelled, environment.attachments.lastError != nil { commandBar?.show() }
            return attachment
        }
        live.onPushToTalkContextCancel = { [weak selector] in voiceSelection = nil; selector?.cancel() }
        live.onPushToTalkContextShown = { [weak environment] attachment in
            environment?.attachments.markShown(attachment)
        }
        selector.onCancelled = { [weak live] in
            guard live?.isPushToTalkActive == true else { return }
            Task { await live?.stopSession() }
        }
        selector.onVoiceRelease = { [weak live] in Task { await live?.endPushToTalk() } }
        selector.onInvalidated = { [weak live] in
            guard live?.wasSessionStartedByPushToTalk == true, live?.state.isLive == true else { return }
            Task { await live?.stopSession() }
        }
        environment.observeSystemEvents()
        let needsOnboarding = environment.needsOnboarding
        DispatchQueue.main.async {
            if needsOnboarding { OnboardingWindowController.shared?.show() }
        }
    }

    var body: some Scene {
        Window("Ivy", id: "main") {
            IvyWindowRoot(environment: environment)
        }
        .defaultSize(width: 1080, height: 760)
        .defaultPosition(.center)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
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
            }
        }

        MenuBarExtra {
            Button("Open Ivy") { MainWindowController.shared?.show() }
                .keyboardShortcut("o")
            Button("New Conversation") {
                library.newConversation()
                MainWindowController.shared?.show()
            }
            Button("Ask about a screen area…") { IvyAppDelegate.screenQuestion?.begin() }
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
            Image(systemName: "leaf")
                .accessibilityLabel("Ivy")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsWindowView(environment: environment, settings: settings, wakeWord: wakeWord)
        }
        .windowStyle(.hiddenTitleBar)
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
    @MainActor static var floatingPointer: FloatingPointerController?
    @MainActor static var screenQuestion: ScreenQuestionController?
    @MainActor static var commandBar: CommandBarController?
    @MainActor static var openURL: (@MainActor (URL) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        // Handle one recognized destination; a URL batch must not create several empty conversations.
        if let url = urls.first(where: { AppRouter.parse($0) != nil }) { Self.openURL?(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared?.show()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let shutdown = Self.shutdown else { return .terminateNow }
        Self.shutdown = nil
        Self.floatingPointer?.stop()
        Self.floatingPointer = nil
        Self.screenQuestion?.stop()
        Self.screenQuestion = nil
        Task { @MainActor in
            await shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
