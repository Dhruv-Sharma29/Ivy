import SwiftUI
import IvyCore

@main
struct IvyApp: App {
    @StateObject private var brain = IvyBrain()
    @StateObject private var voiceManager = VoicePlaybackManager()

    var body: some Scene {
        MenuBarExtra("Ivy", systemImage: brain.statusIcon) {
            IvyPopoverView(brain: brain, voiceManager: voiceManager)
        }
        .menuBarExtraStyle(.window)
    }
}
