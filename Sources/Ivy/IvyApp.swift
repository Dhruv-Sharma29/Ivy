import SwiftUI
import IvyCore

@main
struct IvyApp: App {
    @StateObject private var brain: IvyBrain
    @StateObject private var voiceManager: VoicePlaybackManager
    @StateObject private var liveVoiceCoordinator: GeminiLiveVoiceCoordinator

    init() {
        // An unbundled `swift run Ivy` process starts as BackgroundOnly, which can never activate, so its
        // menu-bar window would ignore clicks. Accessory = menu-bar app (what LSUIElement gives Ivy.app).
        NSApplication.shared.setActivationPolicy(.accessory)
        // Line-buffer stdout so `[LIVE]`/`[WAKE]` diagnostics reach the log file as they happen.
        setvbuf(stdout, nil, _IOLBF, 0)

        let brain = IvyBrain()
        let voiceManager = VoicePlaybackManager()
        let coordinator = GeminiLiveVoiceCoordinator(
            apiKey: brain.apiKey,
            hotkeyManager: SystemGlobalHotkeyManager()
        )
        self._brain = StateObject(wrappedValue: brain)
        self._voiceManager = StateObject(wrappedValue: voiceManager)
        self._liveVoiceCoordinator = StateObject(wrappedValue: coordinator)

        do {
            try coordinator.registerHotkey()
        } catch {
            #if DEBUG
            print("[HOTKEY] Failed to register global push-to-talk hotkey: \(error.localizedDescription)")
            #endif
        }
    }

    var body: some Scene {
        MenuBarExtra("Ivy", systemImage: brain.statusIcon) {
            IvyPopoverView(
                brain: brain,
                voiceManager: voiceManager,
                liveVoiceCoordinator: liveVoiceCoordinator
            )
        }
        .menuBarExtraStyle(.window)
    }
}
