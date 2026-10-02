import SwiftUI
import UniformTypeIdentifiers
import IvyCore

/// Searchable native settings. Existing settings sections retain their storage and permission behavior.
struct SettingsWindowView: View {
    let environment: IvyAppEnvironment
    @ObservedObject var settings: SettingsModel
    @ObservedObject var wakeWord: WakeWordController
    @State private var exportMessage: String?

    @State private var selection: SettingsPane? = .general
    @State private var query = ""

    init(environment: IvyAppEnvironment, settings: SettingsModel, wakeWord: WakeWordController,
         initialPane: SettingsPane = .general) {
        self.environment = environment
        self.settings = settings
        self.wakeWord = wakeWord
        self._selection = State(initialValue: initialPane)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(SettingsPane.allCases.filter { query.isEmpty || $0.searchText.localizedStandardContains(query) }) { pane in
                    Label(pane.rawValue, systemImage: pane.symbol).tag(pane)
                        .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $query, placement: .sidebar, prompt: "Find a setting")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text((selection ?? .general).rawValue).font(.title2.weight(.semibold))
                        Text((selection ?? .general).detail).foregroundStyle(.secondary)
                    }
                    settingsContent
                }
                .font(.body)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("Ivy Settings")
        }
        .navigationSplitViewStyle(.balanced)
        .frame(width: 800, height: 600)
        .onAppear {
            if !environment.credentials.source(for: .geminiAPIKey).isUsable { selection = .keys }
        }
        .accessibilityIdentifier("ivy.settings")
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selection ?? .general {
        case .general:
            GeneralSettingsSection(settings: settings)
            Divider()
            Button("Show the Introduction Again") {
                environment.onboarding.restart()
                OnboardingWindowController.shared?.show()
            }
        case .voice:
            VoiceSettingsSection(settings: settings, wakeWord: wakeWord) {
                environment.voiceManager.togglePlayback(for: ChatMessage(role: .model, text: "This is how I sound when I read to you."))
            }
        case .personalization:
            PersonalizationPanel(model: environment.personalization)
        case .screen:
            VisionSettingsSection(settings: settings)
        case .proactive:
            ProactivePanel(settings: settings, proactive: environment.proactive)
        case .privacy:
            SectionHeading(title: "History")
            HistorySettingsSection(settings: settings)
            Divider()
            SectionHeading(title: "Diagnostics")
            Text("Export versions, settings, permission states and a redacted log for a bug report. Keys and conversations are excluded.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                Button("Export Diagnostics…", action: exportDiagnostics)
                Button("Show Ivy's Data Folder") {
                    NSWorkspace.shared.open(FileConversationStore.defaultDirectory.deletingLastPathComponent())
                }
            }
            if let exportMessage { Text(exportMessage).font(.callout).foregroundStyle(.secondary) }
        case .keys:
            KeysSection(credentials: environment.credentials) { environment.brain.refreshCredentialStatus() }
        case .permissions:
            PermissionsSection(types: PermissionType.allCases)
        case .about:
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Ivy").font(.title2.weight(.semibold))
                    Text(IvyVersion.displayVersion).foregroundStyle(.secondary)
                    Text("Gemini for thinking. ElevenLabs for reading aloud. Built for your Mac.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
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

/// Each section stays discoverable without squeezing labels into a row of tabs.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general = "General", voice = "Voice", personalization = "Personalization", screen = "Screen"
    case proactive = "Proactive", privacy = "Privacy & Data", keys = "API Keys", permissions = "Permissions", about = "About"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .voice: "waveform"
        case .personalization: "person.crop.circle"
        case .screen: "rectangle.dashed"
        case .proactive: "bell"
        case .privacy: "hand.raised"
        case .keys: "key"
        case .permissions: "lock.shield"
        case .about: "info.circle"
        }
    }
    var detail: String {
        switch self {
        case .general: "Your companion and keyboard shortcuts."
        case .voice: "Live conversations, Hey Ivy, and reading aloud."
        case .personalization: "Choose how Ivy responds and what it remembers."
        case .screen: "Choose what to share when you show Ivy your screen."
        case .proactive: "Reminders and suggestions, on your terms."
        case .privacy: "Control saved history and export diagnostics."
        case .keys: "Connect Gemini and ElevenLabs securely through the macOS Keychain."
        case .permissions: "Review microphone, speech recognition, calendar, contacts, reminders and automation access."
        case .about: "Your native Mac assistant."
        }
    }
    var searchText: String { rawValue + " " + detail }
}
