import SwiftUI
import IvyCore

@main
struct IvyApp: App {
    var body: some Scene {
        MenuBarExtra("Ivy", systemImage: "sparkle") {
            Text("Ivy is waking up...")
                .padding()
        }
        .menuBarExtraStyle(.window)
    }
}
