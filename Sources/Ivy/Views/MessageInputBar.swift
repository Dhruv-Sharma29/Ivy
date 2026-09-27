import SwiftUI

public struct MessageInputBar: View {
    @Binding public var text: String
    public let isThinking: Bool
    public let isVoiceActive: Bool
    public let onToggleVoice: (() -> Void)?
    public let onSend: () -> Void

    public init(
        text: Binding<String>,
        isThinking: Bool,
        isVoiceActive: Bool = false,
        onToggleVoice: (() -> Void)? = nil,
        onSend: @escaping () -> Void
    ) {
        self._text = text
        self.isThinking = isThinking
        self.isVoiceActive = isVoiceActive
        self.onToggleVoice = onToggleVoice
        self.onSend = onSend
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let onToggleVoice {
                Button {
                    onToggleVoice()
                } label: {
                    Image(systemName: isVoiceActive ? "mic.fill" : "mic")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(isVoiceActive ? Color.red : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(isVoiceActive ? Color.red.opacity(0.15) : Color.secondary.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(isVoiceActive ? "Stop voice conversation" : "Start live voice conversation")
                .disabled(isThinking)
                .padding(.bottom, 2)
            }

            TextField("Ask Ivy... if you must", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                )
                .onSubmit {
                    if canSend {
                        onSend()
                    }
                }

            Button {
                if canSend {
                    onSend()
                }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .resizable()
                    .frame(width: 26, height: 26)
                    .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .padding(.bottom, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
