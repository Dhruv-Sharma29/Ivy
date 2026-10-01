import SwiftUI
import UniformTypeIdentifiers
import IvyCore

/// Settings window (⌘, while Ivy is active, or "All Settings…" in the popover). The same sections as the popover,
/// in tabs, plus diagnostics export and About.
struct SettingsWindowView: View {
    let environment: IvyAppEnvironment
    @ObservedObject var settings: SettingsModel
    @ObservedObject var wakeWord: WakeWordController
    @State private var exportMessage: String?

    var body: some View {
        TabView {
            form {
                GeneralSettingsSection(settings: settings)
                Divider()
                Button("Show the Introduction Again") {
                    environment.onboarding.restart()
                    OnboardingWindowController.shared?.show()
                }
            }
            .tabItem { Label("General", systemImage: "gearshape") }

            form {
                VoiceSettingsSection(settings: settings, wakeWord: wakeWord) {
                    environment.voiceManager.togglePlayback(for: ChatMessage(role: .model, text: "This is how I sound when I read to you."))
                }
            }
            .tabItem { Label("Voice", systemImage: "waveform") }

            form { PersonalizationPanel(model: environment.personalization) }
                .tabItem { Label("Personalization", systemImage: "person.crop.circle") }

            form { VisionSettingsSection(settings: settings) }
                .tabItem { Label("Screen", systemImage: "rectangle.dashed.badge.record") }

            form { ProactivePanel(settings: settings, proactive: environment.proactive) }
                .tabItem { Label("Proactive", systemImage: "bell") }

            form {
                SectionHeading(title: "History")
                HistorySettingsSection(settings: settings)
                Divider()
                SectionHeading(title: "Diagnostics")
                Text("A plain-text report for bug reports: versions, settings, permission states and where each key comes from (never the key), plus a redacted log tail. No conversations.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Export Diagnostics…", action: exportDiagnostics)
                    Button("Show Ivy's Data Folder") {
                        NSWorkspace.shared.open(FileConversationStore.defaultDirectory.deletingLastPathComponent())
                    }
                }
                if let exportMessage {
                    Text(exportMessage).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .tabItem { Label("Privacy & Data", systemImage: "hand.raised") }

            form {
                KeysSection(credentials: environment.credentials) { environment.brain.refreshCredentialStatus() }
            }
            .tabItem { Label("Keys", systemImage: "key") }

            form { PermissionsSection(types: PermissionType.allCases) }
                .tabItem { Label("Permissions", systemImage: "lock.shield") }

            form {
                HStack(spacing: 12) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                    VStack(alignment: .leading) {
                        Text("Ivy").font(IvyTheme.voiceFont)
                        Text(IvyVersion.displayVersion).foregroundStyle(.secondary)
                        Text("Gemini for thinking, ElevenLabs for reading aloud. Your keys stay in the Keychain.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 520)
    }

    private func form<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The report is built and redacted in IvyCore; the user picks where it goes.
    private func exportDiagnostics() {
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Ivy.log")
        let report = DiagnosticsReport.build(
            settings: settings.settings, credentials: environment.credentials, permissions: SystemPermissionManager(),
            logTail: DiagnosticsReport.tail(of: logURL), crashReportCount: CrashDiagnosticsCollector.storedReportCount,
            wakeStats: (wakeWord.wakeCount, wakeWord.unansweredWakeCount))
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Ivy Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(report.utf8).write(to: url, options: .atomic)
            exportMessage = "Saved to \(url.path)."
        } catch {
            exportMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}
