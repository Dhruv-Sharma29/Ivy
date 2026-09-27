import SwiftUI
import IvyCore

public struct ChatBubbleView: View {
    public let message: ChatMessage
    @ObservedObject public var voiceManager: VoicePlaybackManager

    public init(message: ChatMessage, voiceManager: VoicePlaybackManager? = nil) {
        self.message = message
        self._voiceManager = ObservedObject(wrappedValue: voiceManager ?? VoicePlaybackManager())
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

                HStack(spacing: 8) {
                    Text(formattedTime(message.timestamp))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)

                    if !isUser && !message.isError && !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            voiceManager.togglePlayback(for: message)
                        } label: {
                            if voiceManager.isSynthesizing(messageId: message.id) {
                                ProgressView()
                                    .controlSize(.mini)
                            } else if voiceManager.isPlaying(messageId: message.id) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.accentColor)
                            } else {
                                Image(systemName: "speaker.wave.2")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .help(voiceManager.isPlaying(messageId: message.id) ? "Stop playback" : "Read response aloud")
                        .accessibilityLabel(
                            voiceManager.isSynthesizing(messageId: message.id) ? "Synthesizing speech" :
                            (voiceManager.isPlaying(messageId: message.id) ? "Stop audio playback" : "Read message aloud")
                        )
                    }
                }
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
