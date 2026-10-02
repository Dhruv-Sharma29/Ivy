import SwiftUI

public struct MessageInputBar: View {
    @Binding public var text: String
    public let isThinking: Bool
    public let isVoiceActive: Bool
    public let hasAttachments: Bool
    public let onToggleVoice: (() -> Void)?
    public let onSend: () -> Void
    @FocusState private var isFocused: Bool

    public init(
        text: Binding<String>, isThinking: Bool, isVoiceActive: Bool = false,
        hasAttachments: Bool = false, onToggleVoice: (() -> Void)? = nil,
        onSend: @escaping () -> Void
    ) {
        self._text = text
        self.isThinking = isThinking
        self.isVoiceActive = isVoiceActive
        self.hasAttachments = hasAttachments
        self.onToggleVoice = onToggleVoice
        self.onSend = onSend
    }

    var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments) && !isThinking
    }

    var canToggleVoice: Bool { isVoiceActive || !isThinking }

    func submit() {
        guard canSend else { return }
        onSend()
    }

    func handleReturn(shiftPressed: Bool) -> KeyPress.Result {
        guard !shiftPressed else { return .ignored }
        submit()
        return .handled
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Message Ivy…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(2...7)
                .focused($isFocused)
                .accessibilityLabel("Message Ivy")
                .accessibilityIdentifier("ivy.composer")
                .onSubmit(submit)
                .onKeyPress(keys: [.return], phases: .down) { press in
                    handleReturn(shiftPressed: press.modifiers.contains(.shift))
                }

            HStack(spacing: 10) {
                if let onToggleVoice {
                    Button(action: onToggleVoice) {
                        Label(isVoiceActive ? "End Voice" : "Voice", systemImage: isVoiceActive ? "stop.circle" : "waveform")
                    }
                    .ivyGlassButtonStyle()
                    .controlSize(.regular)
                    .disabled(!canToggleVoice)
                    .help(isVoiceActive ? "End the live voice session" : "Start a live voice conversation")
                    .accessibilityIdentifier("ivy.voice")
                }
                Spacer(minLength: 0)
                Text("⇧ Return for a new line")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(action: submit) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.semibold))
                        .frame(width: 20, height: 20)
                }
                .ivyGlassButtonStyle(prominent: true)
                .controlSize(.regular)
                .disabled(!canSend)
                .help("Send message (Return)")
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("ivy.send")
            }
        }
        .tint(IvyTheme.leaf)
        .padding(14)
        .ivyGlass(cornerRadius: 16)
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isFocused ? IvyTheme.leaf : Color(nsColor: .separatorColor), lineWidth: 1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
