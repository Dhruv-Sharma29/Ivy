import SwiftUI
import IvyCore

@main
struct IvyApp: App {
    @NSApplicationDelegateAdaptor(IvyAppDelegate.self) private var appDelegate
    @StateObject private var brain: IvyBrain
    @StateObject private var voiceManager: VoicePlaybackManager
    @StateObject private var liveVoiceCoordinator: GeminiLiveVoiceCoordinator
    @StateObject private var settings: SettingsModel
    @StateObject private var wakeWord: WakeWordController
    @StateObject private var library: ConversationLibrary
    @StateObject private var proactive: ProactiveEngine
    @StateObject private var personalization: PersonalizationModel
    private let environment: IvyAppEnvironment

    init() {
        // An unbundled `swift run Ivy` process starts as BackgroundOnly, which can never activate, so its
        // menu-bar window would ignore clicks. Accessory = menu-bar app (what LSUIElement gives Ivy.app).
        NSApplication.shared.setActivationPolicy(.accessory)
        // Line-buffer stdout so `[LIVE]`/`[WAKE]` diagnostics reach the log file as they happen.
        setvbuf(stdout, nil, _IOLBF, 0)
        CrashDiagnosticsCollector.shared.start()

        // Settings → credentials → restored conversation → voice → Live (idle) → hotkey. Nothing starts listening.
        let environment = IvyAppEnvironment.production(annotationPresenter: AnnotationOverlay())
        self._brain = StateObject(wrappedValue: environment.brain)
        self._voiceManager = StateObject(wrappedValue: environment.voiceManager)
        self._liveVoiceCoordinator = StateObject(wrappedValue: environment.liveCoordinator)
        self._settings = StateObject(wrappedValue: environment.settings)
        self._wakeWord = StateObject(wrappedValue: environment.wakeWord)
        self._library = StateObject(wrappedValue: environment.library)
        self._proactive = StateObject(wrappedValue: environment.proactive)
        self._personalization = StateObject(wrappedValue: environment.personalization)
        // Audible cue that Ivy woke up and is now listening for the request (like Siri's chime).
        environment.wakeWord.onWake = { NSSound(named: "Tink")?.play() }
        IvyAppDelegate.shutdown = { await environment.shutdown() }
        MainWindowController.shared = MainWindowController(router: environment.router, proactive: environment.proactive) {
            AnyView(MainWindowView(
                brain: environment.brain,
                library: environment.library,
                voiceManager: environment.voiceManager,
                liveVoiceCoordinator: environment.liveCoordinator,
                proactive: environment.proactive,
                attachments: environment.attachments,
                tasks: environment.tasks,
                workspaces: environment.workspaces
            ))
        }
        // The screen-help hotkey attached a capture: show it in the window, ready for the user to send.
        environment.onScreenHelp = { MainWindowController.shared?.show() }
        // Phase 17b: the on-screen companion and the ⌃⌥⌘K command bar.
        IvyAppDelegate.companion = CompanionController(environment: environment)
        // Phase 17c: the introduction on a fresh install only (existing installs are marked done at launch).
        OnboardingWindowController.shared = OnboardingWindowController(model: environment.onboarding)
        if environment.needsOnboarding {
            DispatchQueue.main.async { OnboardingWindowController.shared?.show() }
        }
        self.environment = environment
        let commandBar = CommandBarController(environment: environment)
        IvyAppDelegate.commandBar = commandBar
        environment.onCommandBar = { commandBar.toggle() }
        environment.observeSystemEvents()
    }

    var body: some Scene {
        MenuBarExtra {
            IvyPopoverView(
                brain: brain,
                voiceManager: voiceManager,
                liveVoiceCoordinator: liveVoiceCoordinator,
                settings: settings,
                wakeWord: wakeWord,
                library: library,
                proactive: proactive,
                personalization: personalization
            )
        } label: {
            // Idle shows Ivy's leaf logo; busy states keep their SF Symbols (thinking, approval, error).
            if brain.statusIcon == "sparkle" {
                Image(nsImage: IvyLogoImage.template)
            } else {
                Image(systemName: brain.statusIcon)
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsWindowView(environment: environment, settings: settings, wakeWord: wakeWord)
        }
    }
}

/// Delays quit until Live, playback, the hotkey and any pending approval are torn down and history is saved.
final class IvyAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var shutdown: (@MainActor () async -> Void)?
    /// Kept alive for the app's lifetime.
    @MainActor static var companion: CompanionController?
    @MainActor static var commandBar: CommandBarController?

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
