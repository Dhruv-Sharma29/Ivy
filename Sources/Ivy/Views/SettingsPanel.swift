import SwiftUI
import IvyCore

/// The popover's settings: every section, stacked. The Settings window (`SettingsWindowView`) shows the same
/// sections in tabs, so there is one implementation of each control.
struct SettingsPanel: View {
    let credentials: CredentialProvider
    @ObservedObject var settings: SettingsModel
    @ObservedObject var wakeWord: WakeWordController
    let proactive: ProactiveEngine
    let personalization: PersonalizationModel
    var permissionManager: PermissionManaging = SystemPermissionManager()
    /// Reads a sample line with the current read-aloud settings.
    var onPreviewVoice: (() -> Void)? = nil
    let onCredentialsChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            KeysSection(credentials: credentials, onChange: onCredentialsChanged)
            Divider()
            HistorySettingsSection(settings: settings)
            GeneralSettingsSection(settings: settings)
            Divider()
            VoiceSettingsSection(settings: settings, wakeWord: wakeWord, onPreviewVoice: onPreviewVoice)
            Divider()
            PersonalizationPanel(model: personalization)
            Divider()
            VisionSettingsSection(settings: settings)
            Divider()
            ProactivePanel(settings: settings, proactive: proactive)
            Divider()
            PermissionsSection(permissionManager: permissionManager, types: [.microphone, .speechRecognition, .calendar])
            HStack {
                Text(IvyVersion.displayVersion)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                SettingsLink { Text("All Settings…") }
                    .font(.system(size: 11))
                Button("Quit Ivy") { NSApp.terminate(nil) }
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// A small grey heading, the same in the popover and the Settings window.
struct SectionHeading: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }
}

struct KeysSection: View {
    let credentials: CredentialProvider
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CredentialRow(key: .geminiAPIKey, credentials: credentials, onChange: onChange)
            CredentialRow(key: .elevenLabsAPIKey, credentials: credentials, onChange: onChange)
            Text("Keys go straight to the macOS Keychain. Ivy never shows them again.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

struct HistorySettingsSection: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Save conversation history", isOn: $settings.settings.persistConversationHistory)
            Toggle("Reopen last conversation on launch", isOn: $settings.settings.restoreLastConversation)
            Toggle("Name new conversations automatically (1 extra request each)", isOn: $settings.settings.autoTitleConversations)
            Toggle("Add voice sessions to the conversation as text", isOn: $settings.settings.saveVoiceTranscripts)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
    }
}

struct GeneralSettingsSection: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Always show Ivy in the Dock", isOn: $settings.settings.alwaysShowInDock)
            Toggle("Show Ivy on screen while it listens, talks or works", isOn: $settings.settings.companionEnabled)
            Toggle("Keep Ivy on screen when idle", isOn: $settings.settings.companionShowWhileIdle)
                .disabled(!settings.settings.companionEnabled)
            Toggle("Push-to-talk shortcut \u{2318}\u{21E7}Space (next launch)", isOn: $settings.settings.pushToTalkEnabled)
            Toggle("Command bar shortcut \u{2303}\u{2325}\u{2318}K (next launch)", isOn: $settings.settings.commandBarHotkeyEnabled)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
    }
}

/// Live (Kore) speaking style, "Hey Ivy", and the ElevenLabs read-aloud voice. None of this changes which voice is used.
struct VoiceSettingsSection: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var wakeWord: WakeWordController
    var onPreviewVoice: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeading(title: "Voice")
            Group {
                Toggle("Show live transcript", isOn: $settings.settings.showLiveTranscript)
                Toggle("Echo cancellation for \"Hey Ivy\" (next launch)", isOn: $settings.settings.echoCancellation)
                Toggle("Wake with \u{201C}Hey Ivy\u{201D} (keeps the mic open, on-device only)", isOn: $settings.settings.wakeWordEnabled)
                Toggle("Pause \u{201C}Hey Ivy\u{201D} while the screen is locked", isOn: $settings.settings.pauseWakeWordWhenLocked)
            }
            .toggleStyle(.checkbox)
            if let wakeStatus {
                Text(wakeStatus.text)
                    .font(.system(size: 10))
                    .foregroundStyle(wakeStatus.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            choice("Wait through pauses", $settings.settings.voicePatience,
                   [(.short, "Short"), (.normal, "Normal"), (.long, "Long")])
            choice("Answer length", $settings.settings.voiceResponseLength,
                   [(.brief, "Brief"), (.normal, "Normal"), (.detailed, "Detailed")])
            choice("Speaking pace", $settings.settings.voiceSpeakingPace,
                   [(.slow, "Slow"), (.normal, "Normal"), (.fast, "Fast")])
            Text("Ivy Live voice options apply from the next launch.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            slider("Read-aloud speed", $settings.settings.ttsSpeed, ElevenLabsVoiceSettings.speedRange)
            slider("Stability", $settings.settings.ttsStability, 0...1)
            slider("Style", $settings.settings.ttsStyle, 0...1)
            if let onPreviewVoice {
                Button("Preview read-aloud voice", action: onPreviewVoice)
                    .font(.system(size: 11))
            }
        }
        .font(.system(size: 11))
    }

    private func choice<Value: Hashable>(_ label: String, _ value: Binding<Value>, _ options: [(Value, String)]) -> some View {
        Picker(label, selection: value) {
            ForEach(options, id: \.0) { option in
                Text(option.1).tag(option.0)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
                .controlSize(.small)
                .accessibilityLabel(label)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
    }

    private var wakeStatus: (text: String, color: Color)? {
        switch wakeWord.status {
        case .off: return nil
        case .listening: return ("Listening for \u{201C}Hey Ivy\u{201D}.", .green)
        case .paused: return ("Paused while a voice session is active.", .secondary)
        case .unavailable(let reason): return (reason, .orange)
        }
    }
}

/// What Ivy may see, and how. Capture only ever happens on a user action.
struct VisionSettingsSection: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionHeading(title: "Screen & images")
            Toggle("\u{201C}What am I looking at?\u{201D} shortcut \u{2303}\u{2325}\u{2318}S (next launch)", isOn: $settings.settings.screenHelpHotkeyEnabled)
            Toggle("Send text only, never pixels", isOn: $settings.settings.visionTextOnly)
            Toggle("Hide text that looks like a key or token", isOn: $settings.settings.visionMaskSecrets)
            Toggle("Keep the text from images in history", isOn: $settings.settings.visionKeepTextFromImages)
            TextField("Never capture while these apps are in front", text: Binding(
                get: { settings.settings.visionExcludedApps.joined(separator: ", ") },
                set: { settings.settings.visionExcludedApps = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ))
            .textFieldStyle(.roundedBorder)
            Text("Text is read on this Mac. Images are never saved; history keeps a placeholder.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11))
    }
}

/// Permission states with a deep link for anything denied; re-read when the user comes back from System Settings.
struct PermissionsSection: View {
    var permissionManager: PermissionManaging = SystemPermissionManager()
    let types: [PermissionType]
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionHeading(title: "Permissions")
                Spacer()
                Button("Privacy Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 10))
                .buttonStyle(.link)
            }
            ForEach(types, id: \.self) { type in
                PermissionRow(type: type, state: permissionManager.status(for: type))
            }
        }
        .id(refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh += 1
        }
    }
}

struct PermissionRow: View {
    let type: PermissionType
    let state: PermissionState

    var body: some View {
        HStack {
            Text(type.displayName)
                .font(.system(size: 10))
            Spacer()
            if state == .denied || state == .restricted, let url = type.settingsURL {
                Button("Open Settings") { NSWorkspace.shared.open(url) }
                    .font(.system(size: 9))
                    .buttonStyle(.link)
                    .accessibilityLabel("Open \(type.displayName) settings")
            }
            badge
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var badge: some View {
        switch state {
        case .authorized:
            Text("Allowed").font(.system(size: 9, weight: .medium)).foregroundStyle(.green)
        case .denied:
            Text("Denied").font(.system(size: 9, weight: .medium)).foregroundStyle(.red)
        case .restricted:
            Text("Restricted").font(.system(size: 9, weight: .medium)).foregroundStyle(.orange)
        case .notDetermined:
            Text("Not requested").font(.system(size: 9)).foregroundStyle(.secondary)
        case .unsupported:
            Text("Unsupported").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

/// Paste-and-save field. The stored key is never displayed or kept in view state after saving.
struct CredentialRow: View {
    let key: CredentialKey
    let credentials: CredentialProvider
    let onChange: () -> Void

    @State private var draft = ""
    @State private var source: CredentialSource = .missing
    @State private var errorText: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(key.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                statusLabel
            }
            HStack(spacing: 6) {
                SecureField(source == .missing ? "Paste key" : "Paste a new key to replace", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if source == .keychain {
                    Button("Remove", role: .destructive, action: remove)
                }
            }
            .font(.system(size: 11))
            if let errorText {
                Text(errorText)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
            }
        }
        .onAppear { source = credentials.source(for: key) }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch source {
        case .keychain:
            Label("Saved in Keychain", systemImage: "lock.fill").foregroundStyle(.green)
                .font(.system(size: 10))
        case .environment:
            Label("From environment", systemImage: "terminal").foregroundStyle(.orange)
                .font(.system(size: 10))
        case .missing:
            Label("Not set", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .font(.system(size: 10))
        case .keychainInaccessible:
            Label("Keychain access denied. Paste the key again to fix", systemImage: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.red)
                .font(.system(size: 10))
        }
    }

    private func save() {
        do {
            try credentials.store(draft, for: key)
            errorText = nil
        } catch {
            errorText = "Couldn't save: \(error.localizedDescription)"
        }
        draft = ""
        refresh()
    }

    private func remove() {
        do {
            try credentials.remove(key)
            errorText = nil
        } catch {
            errorText = "Couldn't remove: \(error.localizedDescription)"
        }
        refresh()
    }

    private func refresh() {
        source = credentials.source(for: key)
        onChange()
    }
}
