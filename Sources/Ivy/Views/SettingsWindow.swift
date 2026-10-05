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
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    IvyAppIconView().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ivy").font(.headline)
                        Text("Settings").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(18)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Find a setting", text: $query)
                        .textFieldStyle(.plain)
                        .accessibilityIdentifier("ivy.settings.search")
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .accessibilityLabel("Clear search")
                    }
                }
                .padding(10)
                .ivyGlass(cornerRadius: 10)
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
                List(selection: $selection) {
                ForEach(SettingsPane.allCases.filter { query.isEmpty || $0.searchText.localizedStandardContains(query) }) { pane in
                    Label {
                        Text(pane.rawValue)
                    } icon: {
                        Image(systemName: pane.symbol).foregroundStyle(IvyTheme.moss)
                    }
                    .tag(pane)
                    .padding(.vertical, 6)
                }
            }
            .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
            .modifier(IvySidebarBackground())
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text((selection ?? .general).rawValue).font(.largeTitle.weight(.semibold))
                        Text((selection ?? .general).detail).font(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 2)
                    settingsContent
                }
                .font(.body)
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .ivyGlassGroup()
            }
            .ivyWindowBackground()
            .ivyGlassButtonStyle()
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(.hidden, for: .windowToolbar)
        .frame(minWidth: 780, idealWidth: 900, minHeight: 600, idealHeight: 700)
        .tint(IvyTheme.leaf)
        .onAppear {
            if !environment.credentials.source(for: .geminiAPIKey).isUsable { selection = .keys }
        }
        .accessibilityIdentifier("ivy.settings")
    }

    @ViewBuilder
    private var settingsContent: some View {
        switch selection ?? .general {
        case .general:
            GeneralSettingsSection(settings: settings, shortcutStatus: environment.pushToTalkShortcutStatus)
            SettingsCard(title: "Getting started", symbol: "sparkles", subtitle: "Revisit the basics whenever you need a refresher.") {
                Button("Show introduction") {
                    environment.onboarding.restart()
                    OnboardingWindowController.shared?.show()
                }
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
            HistorySettingsSection(settings: settings)
            SettingsCard(title: "Diagnostics & data", symbol: "externaldrive", subtitle: "Export a report to help troubleshoot Ivy. Keys and conversations are excluded.") {
                HStack(spacing: 12) {
                    Button("Export diagnostics…", action: exportDiagnostics)
                    Button("Show data folder") {
                        NSWorkspace.shared.open(FileConversationStore.defaultDirectory.deletingLastPathComponent())
                    }
                }
                if let exportMessage { Text(exportMessage).font(.callout).foregroundStyle(.secondary) }
            }
        case .keys:
            KeysSection(credentials: environment.credentials) { environment.brain.refreshCredentialStatus() }
        case .permissions:
            SettingsCard(title: "System access", symbol: "lock.shield", subtitle: "You control access through macOS System Settings.") {
                PermissionsSection(types: PermissionType.allCases)
            }
        case .about:
            SettingsCard(title: "Made for your Mac", symbol: "leaf") {
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
