import SwiftUI

public struct MessageInputBar: View {
    @Binding public var text: String
    public let isThinking: Bool
    public let onSend: () -> Void

    public init(text: Binding<String>, isThinking: Bool, onSend: @escaping () -> Void) {
        self._text = text
        self.isThinking = isThinking
        self.onSend = onSend
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isThinking
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
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
