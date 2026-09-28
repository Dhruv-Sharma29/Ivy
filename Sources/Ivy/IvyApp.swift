import SwiftUI
import IvyCore

@main
struct IvyApp: App {
    @StateObject private var brain: IvyBrain
    @StateObject private var voiceManager: VoicePlaybackManager
    @StateObject private var liveVoiceCoordinator: GeminiLiveVoiceCoordinator

    init() {
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
