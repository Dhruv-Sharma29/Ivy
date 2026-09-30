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

    init() {
        // An unbundled `swift run Ivy` process starts as BackgroundOnly, which can never activate, so its
        // menu-bar window would ignore clicks. Accessory = menu-bar app (what LSUIElement gives Ivy.app).
        NSApplication.shared.setActivationPolicy(.accessory)
        // Line-buffer stdout so `[LIVE]`/`[WAKE]` diagnostics reach the log file as they happen.
        setvbuf(stdout, nil, _IOLBF, 0)
        CrashDiagnosticsCollector.shared.start()

        // Settings → credentials → restored conversation → voice → Live (idle) → hotkey. Nothing starts listening.
        let environment = IvyAppEnvironment.production()
        self._brain = StateObject(wrappedValue: environment.brain)
        self._voiceManager = StateObject(wrappedValue: environment.voiceManager)
        self._liveVoiceCoordinator = StateObject(wrappedValue: environment.liveCoordinator)
        self._settings = StateObject(wrappedValue: environment.settings)
        self._wakeWord = StateObject(wrappedValue: environment.wakeWord)
        self._library = StateObject(wrappedValue: environment.library)
        // Audible cue that Ivy woke up and is now listening for the request (like Siri's chime).
        environment.wakeWord.onWake = { NSSound(named: "Tink")?.play() }
        IvyAppDelegate.shutdown = { await environment.shutdown() }
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
                library: library
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
    }
}

/// Delays quit until Live, playback, the hotkey and any pending approval are torn down and history is saved.
final class IvyAppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var shutdown: (@MainActor () async -> Void)?

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
