import SwiftUI
import IvyCore

/// The popover's settings: every section, stacked. The Settings window (`SettingsWindowView`) shows the same
/// sections in a sidebar, so there is one implementation of each control.
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
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
                SettingsLink { Text("All Settings…") }
                    .font(.body)
                Button("Quit Ivy") { NSApp.terminate(nil) }
                    .font(.body)
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
        Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
    }
}

struct KeysSection: View {
    let credentials: CredentialProvider
    let onChange: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsCard(title: "Gemini", symbol: "sparkles", subtitle: "Connect chat and live voice conversations.") {
                CredentialRow(key: .geminiAPIKey, credentials: credentials, onChange: onChange)
            }
            SettingsCard(title: "ElevenLabs", symbol: "speaker.wave.2", subtitle: "Optional. Connect a voice for reading replies aloud.") {
                CredentialRow(key: .elevenLabsAPIKey, credentials: credentials, onChange: onChange)
            }
            Text("Keys go straight to the macOS Keychain. Ivy never shows them again.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct HistorySettingsSection: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        SettingsCard(title: "Conversation history", symbol: "clock.arrow.circlepath") {
            SettingsToggle(title: "Save conversations", detail: "Keep your chats on this Mac.", isOn: $settings.settings.persistConversationHistory)
            Divider()
            SettingsToggle(title: "Continue where you left off", detail: "Open your last conversation when Ivy starts.", isOn: $settings.settings.restoreLastConversation)
            Divider()
            SettingsToggle(title: "Automatic conversation titles", detail: "Uses one extra Gemini request per conversation.", isOn: $settings.settings.autoTitleConversations)
            Divider()
            SettingsToggle(title: "Save voice transcripts", detail: "Add voice conversations to your chat history.", isOn: $settings.settings.saveVoiceTranscripts)
        }
    }
}

struct GeneralSettingsSection: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        VStack(spacing: 18) {
            SettingsCard(title: "On-screen companion", symbol: "leaf") {
                SettingsToggle(title: "Show the Ivy companion", detail: "An animated pixel-art Ivy appears while listening, speaking or working. Respects Reduce Motion.", isOn: $settings.settings.companionEnabled)
                Divider()
                SettingsToggle(title: "Keep visible when idle", isOn: $settings.settings.companionShowWhileIdle)
                    .disabled(!settings.settings.companionEnabled)
            }
            SettingsCard(title: "Keyboard shortcuts", symbol: "command", subtitle: "Command bar changes take effect after restarting Ivy.") {
                SettingsToggle(title: "Push to talk", detail: "Hold ⌘⇧Space from any app. Changes apply immediately.", isOn: $settings.settings.pushToTalkEnabled)
                Divider()
                SettingsToggle(title: "Quick command bar", detail: "Press ⌃⌥⌘K to open a quick prompt.", isOn: $settings.settings.commandBarHotkeyEnabled)
            }
        }
    }
}

/// Live speaking style, wake phrase and read-aloud controls use separate, consistently aligned groups.
struct VoiceSettingsSection: View {
    @ObservedObject var settings: SettingsModel
    @ObservedObject var wakeWord: WakeWordController
    var onPreviewVoice: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            SettingsCard(title: "Live conversation", symbol: "waveform", subtitle: "Choose how Ivy speaks during a voice session.") {
                SettingsToggle(title: "Show live transcript", detail: "See your conversation as you speak.", isOn: $settings.settings.showLiveTranscript)
                Divider()
                choice("Pause tolerance", $settings.settings.voicePatience,
                       [(.short, "Short"), (.normal, "Normal"), (.long, "Long")])
                choice("Answer length", $settings.settings.voiceResponseLength,
                       [(.brief, "Brief"), (.normal, "Normal"), (.detailed, "Detailed")])
                choice("Speaking pace", $settings.settings.voiceSpeakingPace,
                       [(.slow, "Slow"), (.normal, "Normal"), (.fast, "Fast")])
                Text("Speaking preferences take effect after restarting Ivy.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            SettingsCard(title: "Hey Ivy", symbol: "ear", subtitle: "Hands-free access with an on-device wake phrase.") {
                SettingsToggle(title: "Wake with “Hey Ivy”", detail: "Keeps the microphone open. Wake detection stays on this Mac.", isOn: $settings.settings.wakeWordEnabled)
                Divider()
                SettingsToggle(title: "Pause when your Mac is locked", isOn: $settings.settings.pauseWakeWordWhenLocked)
                Divider()
                SettingsToggle(title: "Reduce audio echo", detail: "Helps Ivy hear you during playback. Restart Ivy to apply.", isOn: $settings.settings.echoCancellation)
                if let wakeStatus {
                    Label(wakeStatus.text, systemImage: "mic")
                        .font(.callout).foregroundStyle(wakeStatus.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            SettingsCard(title: "Read aloud", symbol: "speaker.wave.2", subtitle: "Fine-tune the voice used to read chat replies.") {
                slider("Reading speed", $settings.settings.ttsSpeed, ElevenLabsVoiceSettings.speedRange)
                slider("Voice consistency", $settings.settings.ttsStability, 0...1)
                slider("Expressiveness", $settings.settings.ttsStyle, 0...1)
                Text("Higher consistency sounds steadier. More expressiveness adds emphasis.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let onPreviewVoice {
                    Button(action: onPreviewVoice) { Label("Preview voice", systemImage: "play.fill") }
                        .ivyGlassButtonStyle()
                        .controlSize(.regular)
                }
            }
        }
        .font(.body)
    }

    private func choice<Value: Hashable>(_ label: String, _ value: Binding<Value>, _ options: [(Value, String)]) -> some View {
        SettingsControlRow(title: label) {
            SettingsSegmentedPicker(title: label, selection: value, options: options)
        }
    }

    private func slider(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        SettingsControlRow(title: label) {
            HStack(spacing: 12) {
                Slider(value: value, in: range).accessibilityLabel(label)
                Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                    .font(.callout).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }

    private var wakeStatus: (text: String, color: Color)? {
        switch wakeWord.status {
        case .off: return nil
        case .listening: return ("Listening for “Hey Ivy”.", IvyTheme.moss)
        case .paused: return ("Paused while a voice session is active.", .secondary)
        case .unavailable(let reason): return (reason, .orange)
        }
    }
}

/// What Ivy may see, and how. Capture only ever happens on a user action.
struct VisionSettingsSection: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        VStack(spacing: 18) {
            SettingsCard(title: "Screen sharing", symbol: "rectangle.dashed", subtitle: "Ivy only captures your screen when you ask.") {
                SettingsToggle(title: "Screen-help shortcut", detail: "Press ⌃⌥⌘S. Restart Ivy after changing this shortcut.", isOn: $settings.settings.screenHelpHotkeyEnabled)
                Divider()
                SettingsToggle(title: "Share text only", detail: "Send recognized text instead of image pixels.", isOn: $settings.settings.visionTextOnly)
                Divider()
                SettingsToggle(title: "Hide keys and tokens", detail: "Mask text that looks like a secret before sharing.", isOn: $settings.settings.visionMaskSecrets)
                Divider()
                SettingsToggle(title: "Save recognized text", detail: "Keep text from images in conversation history.", isOn: $settings.settings.visionKeepTextFromImages)
            }
            SettingsCard(title: "Excluded apps", symbol: "eye.slash", subtitle: "Never capture while any of these apps is in front.") {
                TextField("App names, separated by commas", text: Binding(
                    get: { settings.settings.visionExcludedApps.joined(separator: ", ") },
                    set: { settings.settings.visionExcludedApps = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Excluded apps")
                Text("Text recognition happens on this Mac. Images are never saved in history.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Permission states with a deep link for anything denied; re-read when the user comes back from System Settings.
struct PermissionsSection: View {
    var permissionManager: PermissionManaging = SystemPermissionManager()
    let types: [PermissionType]
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Privacy permissions").font(.body.weight(.medium))
                Spacer()
                Button("Privacy Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption)
                .buttonStyle(.link)
            }
            ForEach(types, id: \.self) { type in
                Divider()
                PermissionRow(type: type, state: permissionManager.status(for: type))
                    .frame(minHeight: 28)
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
                .font(.body)
            Spacer()
            if state == .denied || state == .restricted, let url = type.settingsURL {
                Button("Open Settings") { NSWorkspace.shared.open(url) }
                    .font(.callout)
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
            Text("Allowed").font(.callout.weight(.medium)).foregroundStyle(.green)
        case .denied:
            Text("Denied").font(.callout.weight(.medium)).foregroundStyle(.red)
        case .restricted:
            Text("Restricted").font(.callout.weight(.medium)).foregroundStyle(.orange)
        case .notDetermined:
            Text("Not requested").font(.callout).foregroundStyle(.secondary)
        case .unsupported:
            Text("Unsupported").font(.callout).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(key.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                statusLabel
            }
            HStack(spacing: 6) {
                SecureField(source == .missing ? "Paste key" : "Paste a new key to replace", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.body)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if source == .keychain {
                    Button("Remove", role: .destructive, action: remove)
                }
            }
            .font(.body)
            if let errorText {
                Text(errorText)
                    .font(.caption)
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
                .font(.caption)
        case .environment:
            Label("From environment", systemImage: "terminal").foregroundStyle(.orange)
                .font(.caption)
        case .missing:
            Label("Not set", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .font(.caption)
        case .keychainInaccessible:
            Label("Keychain access denied. Paste the key again to fix", systemImage: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.red)
                .font(.caption)
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
