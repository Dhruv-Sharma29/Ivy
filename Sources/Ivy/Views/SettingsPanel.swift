import SwiftUI
import IvyCore

/// API keys (write-only, Keychain-backed) and persisted preferences.
struct SettingsPanel: View {
    let credentials: CredentialProvider
    @ObservedObject var settings: SettingsModel
    @ObservedObject var wakeWord: WakeWordController
    var permissionManager: PermissionManaging = SystemPermissionManager()
    let onCredentialsChanged: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CredentialRow(key: .geminiAPIKey, credentials: credentials, onChange: onCredentialsChanged)
            CredentialRow(key: .elevenLabsAPIKey, credentials: credentials, onChange: onCredentialsChanged)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Toggle("Save conversation history", isOn: $settings.settings.persistConversationHistory)
                Toggle("Reopen last conversation on launch", isOn: $settings.settings.restoreLastConversation)
                Toggle("Show live transcript", isOn: $settings.settings.showLiveTranscript)
                Toggle("Echo cancellation for \"Hey Ivy\" (next launch)", isOn: $settings.settings.echoCancellation)
                Toggle("Push-to-talk shortcut (next launch)", isOn: $settings.settings.pushToTalkEnabled)
                Toggle("Wake with \u{201C}Hey Ivy\u{201D} (keeps the mic open, on-device only)", isOn: $settings.settings.wakeWordEnabled)
                if let wakeStatus {
                    Text(wakeStatus.text)
                        .font(.system(size: 10))
                        .foregroundStyle(wakeStatus.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 11))

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Permissions")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Privacy Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .font(.system(size: 10))
                    .buttonStyle(.link)
                }

                PermissionRow(title: "Microphone", state: permissionManager.status(for: .microphone))
                PermissionRow(title: "Speech Recognition", state: permissionManager.status(for: .speechRecognition))
                PermissionRow(title: "Calendar", state: permissionManager.status(for: .calendar))
            }

            HStack {
                Text(IvyVersion.displayVersion)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Quit Ivy") { NSApp.terminate(nil) }
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

extension SettingsPanel {
    fileprivate var wakeStatus: (text: String, color: Color)? {
        switch wakeWord.status {
        case .off: return nil
        case .listening: return ("Listening for \u{201C}Hey Ivy\u{201D}.", .green)
        case .paused: return ("Paused while a voice session is active.", .secondary)
        case .unavailable(let reason): return (reason, .orange)
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let state: PermissionState

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10))
            Spacer()
            badge
        }
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
private struct CredentialRow: View {
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
