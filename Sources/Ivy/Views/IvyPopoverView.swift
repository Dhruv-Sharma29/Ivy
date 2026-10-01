import SwiftUI
import IvyCore

public struct IvyPopoverView: View {
    @ObservedObject public var brain: IvyBrain
    @ObservedObject public var voiceManager: VoicePlaybackManager
    @ObservedObject public var liveVoiceCoordinator: GeminiLiveVoiceCoordinator
    @ObservedObject public var settings: SettingsModel
    @ObservedObject public var wakeWord: WakeWordController
    @ObservedObject public var library: ConversationLibrary
    @ObservedObject public var proactive: ProactiveEngine
    public let personalization: PersonalizationModel
    @State private var inputText: String = ""
    @State private var showSettings: Bool = false
    @State private var showConversations: Bool = false
    @State private var confirmingDelete: Bool = false
    /// A search hit to bring into view once its conversation is on screen.
    @State private var scrollTarget: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        brain: IvyBrain,
        voiceManager: VoicePlaybackManager,
        liveVoiceCoordinator: GeminiLiveVoiceCoordinator,
        settings: SettingsModel,
        wakeWord: WakeWordController,
        library: ConversationLibrary,
        proactive: ProactiveEngine,
        personalization: PersonalizationModel
    ) {
        self.brain = brain
        self.voiceManager = voiceManager
        self.liveVoiceCoordinator = liveVoiceCoordinator
        self.settings = settings
        self.wakeWord = wakeWord
        self.library = library
        self.proactive = proactive
        self.personalization = personalization
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

            if let quota = brain.quotaStatus {
                quotaBanner(quota)
                Divider()
            }

            if let notice = brain.storageNotice {
                storageBanner(notice) { brain.dismissStorageNotice() }
                Divider()
            }

            if let notice = proactive.notice {
                storageBanner(notice) { proactive.dismissNotice() }
                Divider()
            }

            if showConversations {
                ConversationsPanel(library: library) { messageID in
                    voiceManager.stop()
                    scrollTarget = messageID
                    showConversations = false
                }
            } else {
                messageArea
            }
            Divider()

            if liveVoiceCoordinator.state.isLive {
                liveVoiceBar
                Divider()
            }

            if let request = liveVoiceCoordinator.pendingConfirmation {
                ConfirmationCardView(request: request) { approved in
                    liveVoiceCoordinator.respondToPendingConfirmation(id: request.id, approved: approved)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Divider()
            } else if let request = brain.pendingConfirmation {
                ConfirmationCardView(request: request) { approved in
                    brain.respondToPendingConfirmation(id: request.id, approved: approved)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                Divider()
            }

            MessageInputBar(
                text: $inputText,
                isThinking: brain.isThinking || brain.pendingConfirmation != nil || liveVoiceCoordinator.state == .toolConfirmation || liveVoiceCoordinator.state == .toolExecution,
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
        // A menu-bar-only (LSUIElement) app isn't activated when its status item opens this window,
        // so the window never becomes key and AppKit drops clicks on its buttons (gear, trash, close).
        .onAppear {
            NSApp.activate()
            takeSuggestedPrompt()
        }
        // Opening a proactive notification pre-fills its suggestion. It is never sent for the user.
        .onChange(of: proactive.pendingPrompt) { takeSuggestedPrompt() }
    }

    private func takeSuggestedPrompt() {
        guard let prompt = proactive.pendingPrompt else { return }
        proactive.pendingPrompt = nil
        showConversations = false
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = prompt
        }
    }

    // MARK: - Header
    private var headerView: some View {
        HStack {
            Image(nsImage: IvyLogoImage.template)
                .renderingMode(.template)
                .resizable()
                .frame(width: 16, height: 16)
                .foregroundStyle(Color(red: 0.231, green: 0.745, blue: 0.431))
                .accessibilityHidden(true)

            Text("Ivy")
                .font(.system(size: 14, weight: .bold))

            statusBadge

            Spacer()

            Button {
                MainWindowController.shared?.show()
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open Ivy window (⌘O)")
            .accessibilityLabel("Open Ivy window")
            .keyboardShortcut("o", modifiers: [.command])

            Button {
                showConversations.toggle()
            } label: {
                Image(systemName: showConversations ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Conversations")
            .accessibilityLabel(showConversations ? "Hide conversations" : "Show conversations")
            .keyboardShortcut("f", modifiers: [.command])

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
            .accessibilityLabel(showSettings ? "Hide settings" : "Show settings")
            .keyboardShortcut(",", modifiers: [.command])

            Button {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Delete This Conversation")
            .accessibilityLabel("Delete this conversation")
            .disabled(brain.messages.isEmpty && !liveVoiceCoordinator.state.isLive)
            .confirmationDialog("Delete this conversation?", isPresented: $confirmingDelete) {
                Button("Delete", role: .destructive) {
                    voiceManager.stop()
                    Task {
                        await liveVoiceCoordinator.stopSession()
                    }
                    brain.clearHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently removes it. Use the conversations list to archive it instead, or start a new one.")
            }
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
                    .fill(liveStateColor)
                    .frame(width: 7, height: 7)
                Text(voiceStateBadgeText)
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(liveStateColor.opacity(0.15))
            .foregroundStyle(liveStateColor)
            .clipShape(Capsule())
            .animation(.easeInOut(duration: 0.15), value: liveVoiceCoordinator.state)
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
        } else if !brain.isGeminiKeyConfigured {
            Text("Key Missing")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.2))
                .foregroundStyle(Color.orange)
                .clipShape(Capsule())
        } else if wakeWord.status == .listening {
            // The microphone is open for the wake word: always make that visible.
            Label("Say \u{201C}Hey Ivy\u{201D}", systemImage: "ear")
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15))
                .foregroundStyle(Color.green)
                .clipShape(Capsule())
                .help("Listening on-device for the wake word. Turn off in Settings.")
        }
    }

    private var voiceStateBadgeText: String {
        switch liveVoiceCoordinator.state {
        case .connecting:
            return "Connecting..."
        case .listening:
            return "Listening"
        case .thinking:
            return "Thinking"
        case .toolConfirmation:
            return "Approve?"
        case .toolExecution:
            return "Working"
        case .speaking:
            return "Speaking"
        case .interrupting:
            return "Interrupting"
        case .reconnecting:
            return "Reconnecting..."
        case .idle, .error:
            return ""
        }
    }

    // MARK: - Live Voice Bar
    private var liveVoiceBar: some View {
        HStack(spacing: 10) {
            LiveLevelIndicator(meter: liveVoiceCoordinator.levelMeter, state: liveVoiceCoordinator.state, color: liveStateColor) {
                liveStateIndicator
            }
            .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(liveVoiceDescription)
                    .font(.system(size: 11, weight: .semibold))
                if settings.settings.showLiveTranscript && !liveVoiceCoordinator.latestTranscript.isEmpty {
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
            if liveVoiceCoordinator.isMuted { return "Muted — say \"Hey Ivy\" to unmute" }
            return liveVoiceCoordinator.isHearingUser ? "Hearing you…" : "Listening — just talk"
        case .thinking:
            return "Ivy is thinking..."
        case .toolConfirmation:
            return "Approve or deny below (voice can't approve)"
        case .toolExecution:
            if let tool = liveVoiceCoordinator.executingToolName {
                return "Executing \(tool)..."
            }
            return "Executing tool..."
        case .speaking:
            return liveVoiceCoordinator.isWakePhraseAvailable
                ? "Ivy is speaking (say \"Hey Ivy\" to interrupt)"
                : "Ivy is speaking (\"Hey Ivy\" needs Ivy.app: scripts/run-ivy-app.sh)"
        case .interrupting:
            return "Stopping Ivy..."
        case .reconnecting(let attempt):
            return "Connection lost. Reconnecting (attempt \(attempt))..."
        case .idle, .error:
            return "Ivy Live disconnected"
        }
    }

    /// One color per Live state so the badge, dot, and bar icon always agree.
    private var liveStateColor: Color {
        switch liveVoiceCoordinator.state {
        case .listening: return .green
        case .speaking: return .accentColor
        case .thinking, .toolExecution: return .purple
        case .toolConfirmation, .interrupting, .reconnecting: return .orange
        case .connecting, .idle: return .secondary
        case .error: return .red
        }
    }

    @ViewBuilder
    private var liveStateIndicator: some View {
        switch liveVoiceCoordinator.state {
        case .connecting, .thinking, .toolExecution, .reconnecting:
            ProgressView()
                .controlSize(.small)
                .tint(liveStateColor)
        default:
            Image(systemName: liveStateSymbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(liveStateColor)
                .symbolEffect(.variableColor.iterative, isActive: !reduceMotion && liveVoiceCoordinator.state == .speaking)
                .symbolEffect(.pulse, isActive: !reduceMotion && liveVoiceCoordinator.state == .listening)
                .accessibilityLabel(voiceStateBadgeText)
        }
    }

    private var liveStateSymbol: String {
        switch liveVoiceCoordinator.state {
        case .speaking: return "waveform"
        case .listening where liveVoiceCoordinator.isMuted: return "mic.slash.fill"
        case .toolConfirmation: return "exclamationmark.shield.fill"
        case .interrupting: return "hand.raised.fill"
        case .error: return "exclamationmark.triangle.fill"
        default: return "mic.fill"
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

            if message.contains("denied") || message.contains("Microphone access") {
                Button("Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 10, weight: .semibold))
                .buttonStyle(.link)
            }

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
            .accessibilityLabel("Dismiss error")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Quota Banner
    /// Counts down live while Gemini is rate limiting; disappears on the next successful reply.
    private func quotaBanner(_ quota: QuotaStatus) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Image(systemName: quota.kind == .perDay ? "calendar.badge.exclamationmark" : "hourglass")
                    .foregroundStyle(.orange)
                    .font(.system(size: 12))
                Text(quota.message(now: context.date))
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: - Storage Banner
    private func storageBanner(_ notice: String, dismiss: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .foregroundStyle(.orange)
                .font(.system(size: 12))
            Text(notice)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss storage notice")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Settings Bar
    private var settingsBar: some View {
        // Scrolls: the panel is taller than the room the popover can spare.
        ScrollView {
            SettingsPanel(
                credentials: brain.credentials, settings: settings, wakeWord: wakeWord, proactive: proactive,
                personalization: personalization,
                onPreviewVoice: {
                    voiceManager.togglePlayback(for: ChatMessage(role: .model, text: "This is how I sound when I read to you."))
                }
            ) {
                brain.refreshCredentialStatus()
            }
        }
        .frame(maxHeight: 340)
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
            .onAppear {
                // Coming back from a search hit: show that message rather than the end of the chat.
                guard let target = scrollTarget else { return }
                scrollTarget = nil
                DispatchQueue.main.async { proxy.scrollTo(target, anchor: .center) }
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
        VStack(spacing: 12) {
            Spacer()
            if !brain.isGeminiKeyConfigured {
                Image(systemName: "key.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor.opacity(0.8))

                Text("Welcome to Ivy")
                    .font(.system(size: 15, weight: .semibold))

                Text("To begin pair-programming, tool automation, and voice conversations, enter your Gemini API key in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSettings = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "gearshape")
                        Text("Configure API Keys")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 4)
            } else {
                // The same leaf as the menu bar and the app icon.
                Image(nsImage: IvyLogoImage.template)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 40, height: 40)
                    .foregroundStyle(Color(red: 0.231, green: 0.745, blue: 0.431))
                    .accessibilityHidden(true)

                Text("Ivy is ready.")
                    .font(.system(size: 15, weight: .semibold))

                Text("I'm waiting. Make it interesting or don't waste my time.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
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
            Task {
                await liveVoiceCoordinator.startSession()
            }
        }
    }

    private func submitCurrentMessage() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !brain.isThinking, brain.pendingConfirmation == nil else { return }
        inputText = ""
        showConversations = false
        Task {
            await brain.send(trimmed)
        }
    }
}

/// The Live state icon inside a halo that swells with the voice: the user's while listening, Ivy's while
/// speaking. Observes the meter itself so 30 Hz level updates redraw only this view, not the whole popover.
private struct LiveLevelIndicator<Icon: View>: View {
    @ObservedObject var meter: AudioLevelMeter
    let state: VoiceSessionState
    let color: Color
    @ViewBuilder let icon: () -> Icon
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var level: CGFloat {
        switch state {
        case .listening: return CGFloat(meter.inputLevel)
        case .speaking: return CGFloat(meter.outputLevel)
        default: return 0
        }
    }

    var body: some View {
        ZStack {
            if !reduceMotion {
                Circle()
                    .fill(color.opacity(0.22))
                    .scaleEffect(0.55 + level * 0.75)
                    .animation(.linear(duration: 0.08), value: level)
                    .accessibilityHidden(true)
            }
            icon()
        }
    }
}
