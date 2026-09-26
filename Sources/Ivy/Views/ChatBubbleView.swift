import SwiftUI
import IvyCore

public struct ChatBubbleView: View {
    public let message: ChatMessage

    public init(message: ChatMessage) {
        self.message = message
    }

    private var isUser: Bool {
        message.role == .user
    }

    public var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                Spacer(minLength: 40)
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                Text(message.text)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(isUser ? Color.white : Color.primary)
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                Text(formattedTime(message.timestamp))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            if !isUser {
                Spacer(minLength: 40)
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if isUser {
            Color.accentColor
        } else if message.isError {
            Color.red.opacity(0.15)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.red.opacity(0.3), lineWidth: 1)
                )
        } else {
            Color(nsColor: .controlBackgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                )
        }
    }

    private func formattedTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}
