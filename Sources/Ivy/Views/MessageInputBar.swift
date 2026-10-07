import SwiftUI
import IvyCore

public struct MessageInputBar: View {
    @Binding public var text: String
    public let isThinking: Bool
    public let isVoiceActive: Bool
    public let hasAttachments: Bool
    public let onToggleVoice: (() -> Void)?
    public let onSend: () -> Void
    public let attachmentTray: AttachmentTray?
    public let placeholder: String

    public init(
        text: Binding<String>, isThinking: Bool, isVoiceActive: Bool = false,
        hasAttachments: Bool = false, onToggleVoice: (() -> Void)? = nil,
        attachmentTray: AttachmentTray? = nil,
        placeholder: String = "Message Ivy…",
        onSend: @escaping () -> Void
    ) {
        self._text = text
        self.isThinking = isThinking
        self.isVoiceActive = isVoiceActive
        self.hasAttachments = hasAttachments
        self.onToggleVoice = onToggleVoice
        self.onSend = onSend
        self.attachmentTray = attachmentTray
        self.placeholder = placeholder
    }

    var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments) && !isThinking
    }

    var canToggleVoice: Bool { isVoiceActive || !isThinking }

    func submit() {
        guard canSend else { return }
        onSend()
    }

    public var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if let attachmentTray {
                AttachmentMenu(tray: attachmentTray)
            }
            ComposerTextEditor(text: $text, onSend: submit)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .leading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .font(.body).foregroundStyle(.secondary)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            if let onToggleVoice {
                Button(action: onToggleVoice) {
                    Image(systemName: isVoiceActive ? "stop.circle.fill" : "mic")
                        .font(.system(size: 18))
                        .frame(width: 36, height: 36)
                        .foregroundStyle(isVoiceActive ? IvyTheme.leaf : Color.primary)
                        .background(isVoiceActive ? IvyTheme.leaf.opacity(0.14) : Color.clear, in: Circle())
                }
                .buttonStyle(ComposerControlStyle())
                .disabled(!canToggleVoice)
                .help(isVoiceActive ? "End the live voice session" : "Start a live voice conversation")
                .accessibilityLabel(isVoiceActive ? "End Voice" : "Voice")
                .accessibilityIdentifier("ivy.voice")
            }
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(canSend ? IvyTheme.canvas : Color.secondary)
                    .frame(width: 36, height: 36)
                    .background(IvyTheme.leaf.opacity(canSend ? 1 : 0.16), in: Circle())
            }
            .buttonStyle(ComposerControlStyle())
            .disabled(!canSend)
            .help("Send message (Return)")
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("ivy.send")
        }
        .tint(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .ivyGlass(cornerRadius: 26)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Quiet icon controls share one target size and immediate pointer feedback.
struct ComposerControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ComposerControlLabel(configuration: configuration)
    }
}

private struct ComposerControlLabel: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .frame(width: 36, height: 36)
            .background(Color.primary.opacity(isEnabled ? (configuration.isPressed ? 0.14 : (isHovering ? 0.08 : 0)) : 0),
                        in: Circle())
            .opacity(isEnabled ? 1 : 0.55)
            .contentShape(Circle())
            .onHover { isHovering = $0 }
    }
}
