import SwiftUI
import IvyCore

@main
struct IvyApp: App {
    @StateObject private var brain = IvyBrain()

    var body: some Scene {
        MenuBarExtra("Ivy", systemImage: brain.statusIcon) {
            IvyPopoverView(brain: brain)
        }
        .menuBarExtraStyle(.window)
    }
}
