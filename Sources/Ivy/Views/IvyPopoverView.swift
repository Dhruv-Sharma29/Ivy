import SwiftUI
import IvyCore

public struct IvyPopoverView: View {
    @ObservedObject public var brain: IvyBrain
    @ObservedObject public var voiceManager: VoicePlaybackManager
    @StateObject public var liveVoiceCoordinator: GeminiLiveVoiceCoordinator
    @State private var inputText: String = ""
    @State private var showSettings: Bool = false

    public init(
        brain: IvyBrain,
        voiceManager: VoicePlaybackManager? = nil,
        liveVoiceCoordinator: GeminiLiveVoiceCoordinator? = nil
    ) {
        self.brain = brain
        self.voiceManager = voiceManager ?? VoicePlaybackManager()
        self._liveVoiceCoordinator = StateObject(
            wrappedValue: liveVoiceCoordinator ?? GeminiLiveVoiceCoordinator(apiKey: brain.apiKey)
        )
    }

    public var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()

            if showSettings {
                settingsBar
                Divider()
            }

            if case .error(let msg) = liveVoiceCoordinator.state {
                voiceErrorBanner(message: msg)
                Divider()
            }

            if let ttsError = voiceManager.errorMessage {
                ttsErrorBanner(message: ttsError)
                Divider()
            }

            messageArea
            Divider()

            if liveVoiceCoordinator.state.isLive {
                liveVoiceBar
                Divider()
            }

            if let request = brain.pendingConfirmation {
                ConfirmationCardView(request: request) { approved in
                    brain.respondToPendingConfirmation(id: request.id, approved: approved)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Divider()
            }

            MessageInputBar(
                text: $inputText,
                isThinking: brain.isThinking || brain.pendingConfirmation != nil,
                isVoiceActive: liveVoiceCoordinator.state.isLive,
                onToggleVoice: {
                    toggleLiveVoice()
                }
            ) {
                submitCurrentMessage()
            }
        }
        .frame(width: 380, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: brain.apiKey) { _, newKey in
            liveVoiceCoordinator.updateApiKey(newKey)
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack {
            Image(systemName: "sparkle")
                .foregroundStyle(Color.accentColor)
                .font(.system(size: 14, weight: .semibold))

            Text("Ivy")
                .font(.system(size: 14, weight: .bold))

            statusBadge

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSettings.toggle()
                }
            } label: {
                Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Configure API Keys")

            Button {
                voiceManager.stop()
                Task {
                    await liveVoiceCoordinator.stopSession()
                }
                brain.clearHistory()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear Conversation")
            .disabled(brain.messages.isEmpty && !liveVoiceCoordinator.state.isLive)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    // MARK: - Status Badge
    @ViewBuilder
    private var statusBadge: some View {
        if liveVoiceCoordinator.state.isLive {
            HStack(spacing: 4) {
                Circle()
                    .fill(liveVoiceCoordinator.state == .speaking ? Color.accentColor : Color.green)
                    .frame(width: 7, height: 7)
                Text(voiceStateBadgeText)
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(liveVoiceCoordinator.state == .speaking ? Color.accentColor.opacity(0.15) : Color.green.opacity(0.15))
            .foregroundStyle(liveVoiceCoordinator.state == .speaking ? Color.accentColor : Color.green)
            .clipShape(Capsule())
        } else if brain.pendingConfirmation != nil {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text("Approval Required")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        } else if brain.isThinking {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text("Thinking...")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        } else if brain.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text("Key Missing")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.2))
                .foregroundStyle(Color.orange)
                .clipShape(Capsule())
        }
    }

    private var voiceStateBadgeText: String {
        switch liveVoiceCoordinator.state {
        case .connecting:
            return "Connecting..."
        case .listening:
            return "Ivy Live"
        case .thinking:
            return "Thinking"
        case .speaking:
            return "Speaking"
        case .interrupting:
            return "Interrupting"
        case .idle, .error:
            return ""
        }
    }

    // MARK: - Live Voice Bar
    private var liveVoiceBar: some View {
        HStack(spacing: 10) {
            Image(systemName: liveVoiceCoordinator.state == .speaking ? "waveform" : "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(liveVoiceCoordinator.state == .speaking ? Color.accentColor : Color.green)

            VStack(alignment: .leading, spacing: 1) {
                Text(liveVoiceDescription)
                    .font(.system(size: 11, weight: .semibold))
                if !liveVoiceCoordinator.latestTranscript.isEmpty {
                    Text(liveVoiceCoordinator.latestTranscript)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                Task {
                    await liveVoiceCoordinator.stopSession()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "phone.down.fill")
                    Text("End")
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.15))
                .foregroundStyle(.red)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var liveVoiceDescription: String {
        switch liveVoiceCoordinator.state {
        case .connecting:
            return "Connecting to Ivy Live..."
        case .listening:
            return "Ivy Live connected"
        case .thinking:
            return "Ivy is thinking..."
        case .speaking:
            return "Ivy is speaking (say \"Hey Ivy\" to interrupt)"
        case .interrupting:
            return "Interrupting..."
        case .idle, .error:
            return "Ivy Live disconnected"
        }
    }

    // MARK: - Voice Error Banner
    private func voiceErrorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer()

            Button {
                Task {
                    await liveVoiceCoordinator.stopSession()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - TTS Error Banner
    private func ttsErrorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.badge.exclamationmark.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 12))

            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)

            Spacer()

            Button {
                voiceManager.clearError()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Settings Bar
    private var settingsBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Gemini API Key")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack {
                    SecureField("Enter Gemini API key", text: $brain.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    if !brain.apiKey.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 13))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("ElevenLabs API Key")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack {
                    SecureField("Enter ElevenLabs API key", text: $voiceManager.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    if !voiceManager.apiKey.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 13))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Messages Area
    private var messageArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if brain.messages.isEmpty {
                    emptyStateView
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(brain.messages) { message in
                            ChatBubbleView(message: message, voiceManager: voiceManager)
                                .id(message.id)
                        }

                        if brain.isThinking && brain.pendingConfirmation == nil {
                            HStack {
                                Text("Ivy is formulating a sharp reply...")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .italic()
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.secondary.opacity(0.1))
                                    .clipShape(Capsule())
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .id("thinkingIndicator")
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 8)
                }
            }
            .onChange(of: brain.messages.count) {
                if let lastMessage = brain.messages.last {
                    withAnimation {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: brain.isThinking) {
                if brain.isThinking {
                    withAnimation {
                        proxy.scrollTo("thinkingIndicator", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Empty State
    private var emptyStateView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor.opacity(0.8))

            Text("Ivy is ready.")
                .font(.system(size: 15, weight: .semibold))

            Text("I'm waiting. Make it interesting or don't waste my time.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private func toggleLiveVoice() {
        if liveVoiceCoordinator.state.isLive {
            Task {
                await liveVoiceCoordinator.stopSession()
            }
        } else {
            voiceManager.stop()
            liveVoiceCoordinator.updateApiKey(brain.apiKey)
            Task {
                await liveVoiceCoordinator.startSession()
            }
        }
    }

    private func submitCurrentMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !brain.isThinking, brain.pendingConfirmation == nil else { return }
        inputText = ""
        Task {
            await brain.send(trimmed)
        }
    }
}
