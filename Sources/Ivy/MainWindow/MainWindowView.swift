import SwiftUI
import UniformTypeIdentifiers
import IvyCore

struct MainWindowView: View {
    @ObservedObject var brain: IvyBrain
    @ObservedObject var library: ConversationLibrary
    @ObservedObject var voiceManager: VoicePlaybackManager
    @ObservedObject var liveVoiceCoordinator: GeminiLiveVoiceCoordinator
    @ObservedObject var proactive: ProactiveEngine
    @ObservedObject var attachments: AttachmentTray
    @ObservedObject var tasks: TaskEngine
    @ObservedObject var workspaces: WorkspaceModel
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var destination = WorkspaceDestination.home

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(library: library, brain: brain, workspaces: workspaces, tasks: tasks, destination: $destination)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            ChatPaneView(brain: brain, voiceManager: voiceManager, liveVoiceCoordinator: liveVoiceCoordinator,
                         proactive: proactive, attachments: attachments, tasks: tasks,
                         library: library, destination: destination, onShowChat: { destination = .chat })
        }
        .navigationSplitViewStyle(.balanced)
        .tint(IvyTheme.leaf)
        .frame(minWidth: 560, minHeight: 480)
        .toolbar(.hidden, for: .windowToolbar)
        .accessibilityIdentifier("ivy.mainWindow")
    }
}

struct ChatPaneView: View {
    @ObservedObject var brain: IvyBrain
    @ObservedObject var voiceManager: VoicePlaybackManager
    @ObservedObject var liveVoiceCoordinator: GeminiLiveVoiceCoordinator
    @ObservedObject var proactive: ProactiveEngine
    @ObservedObject var attachments: AttachmentTray
    @ObservedObject var tasks: TaskEngine
    var library: ConversationLibrary? = nil
    var showsHome = false
    var destination: WorkspaceDestination? = nil
    var onShowChat: (() -> Void)? = nil
    @State private var inputText = ""
    @State private var drafts: [UUID: String] = [:]
    @State private var editingInstructions = false
    @State private var instructionsDraft = ""
    @State private var instructionsError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isBlocked: Bool {
        brain.isThinking || brain.pendingConfirmation != nil || liveVoiceCoordinator.state.isLive
            || tasks.run?.isActive == true || attachments.isWorking
    }

    private var currentDestination: WorkspaceDestination { destination ?? (showsHome ? .home : .chat) }

    var body: some View {
        VStack(spacing: 0) {
            if currentDestination == .home, let library {
                IvyHomeView(library: library, brain: brain, tasks: tasks,
                            onPrompt: { inputText = $0; onShowChat?() }, onOpenConversation: { onShowChat?() },
                            onCapture: { Task { await attachments.capture(.frontWindow) } })
            } else if currentDestination != .chat && currentDestination != .home {
                WorkspacePage(destination: currentDestination, tasks: tasks,
                              blocked: isBlocked, onPrompt: { inputText = $0; onShowChat?() })
            } else {
                messages
            }
            VStack(spacing: 0) {
                if let request = liveVoiceCoordinator.pendingConfirmation {
                    ConfirmationCardView(request: request) { approved in
                        liveVoiceCoordinator.respondToPendingConfirmation(id: request.id, approved: approved)
                    }
                    .id(request.id)
                    .padding(.horizontal, 16)
                } else if let request = brain.pendingConfirmation {
                    ConfirmationCardView(request: request) { approved in
                        brain.respondToPendingConfirmation(id: request.id, approved: approved)
                    }
                    .id(request.id)
                    .padding(.horizontal, 16)
                }
                if tasks.run != nil && currentDestination != .tasks {
                    ScrollView { TaskCardView(engine: tasks) }
                        .frame(maxHeight: 200)
                }
                if case .error(let reason) = liveVoiceCoordinator.state {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 16)
                }
                if liveVoiceCoordinator.state.isLive {
                    Label("Voice session active. End voice to send a typed message.", systemImage: "waveform")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
                AttachmentBar(tray: attachments)
                MessageInputBar(text: $inputText, isThinking: isBlocked,
                                isVoiceActive: liveVoiceCoordinator.state.isLive,
                                hasAttachments: !attachments.attachments.isEmpty,
                                onToggleVoice: toggleLive, onSend: send)
            }
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .ivyWindowBackground()
        .navigationTitle(currentDestination == .chat
                         ? (brain.messages.isEmpty ? "New conversation" : brain.currentConversation.displayTitle)
                         : currentDestination.rawValue)
        .sheet(isPresented: $editingInstructions) { instructionsSheet }
        .focusedSceneValue(\.ivyChatInstructions, $editingInstructions)
        .onChange(of: editingInstructions) {
            if editingInstructions {
                instructionsDraft = brain.currentConversation.systemContext ?? ""
                instructionsError = nil
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            accept(providers)
            return true
        }
        .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg], perform: accept)
        .onAppear(perform: takeSuggestedPrompt)
        .onChange(of: attachments.suggestedPrompt) { takeSuggestedPrompt() }
        .onChange(of: proactive.pendingPrompt) { takeSuggestedPrompt() }
        .onChange(of: brain.conversationID) { old, new in
            drafts[old] = inputText
            inputText = drafts[new] ?? ""
            onShowChat?()
        }
    }

    var instructionsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Chat instructions").font(.title2.weight(.semibold))
            Text("Apply to this conversation only. Ivy's safety checks still apply.")
                .foregroundStyle(.secondary)
            TextEditor(text: $instructionsDraft)
                .font(.body)
                .frame(minHeight: 140)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Instructions for this conversation")
            if let instructionsError {
                Label(instructionsError, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { editingInstructions = false }
                Button("Save", action: saveInstructions).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .ivyWindowBackground()
        .ivyGlassButtonStyle()
    }

    private func saveInstructions() {
        let text = instructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = SensitiveDataDetector.reason(text) {
            instructionsError = "Remove the \(reason) before saving."
            return
        }
        let capped = String(text.prefix(PersonalizationProfile.maxCustomInstructions))
        brain.updateConversation { $0.systemContext = capped.isEmpty ? nil : capped }
        editingInstructions = false
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let notice = brain.storageNotice {
                        HStack(alignment: .top) {
                            Label(notice, systemImage: "exclamationmark.triangle")
                            Spacer()
                            Button("Dismiss") { brain.dismissStorageNotice() }
                        }
                        .font(.callout)
                        .padding(12)
                        .ivyGlass(cornerRadius: 10)
                    }
                    if brain.messages.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 28) {
                            ForEach(brain.messages) { message in
                                MessageRowView(message: message, voiceManager: voiceManager)
                                    .id(message.id)
                            }
                            if brain.retryableMessage != nil {
                                Button { Task { await brain.retryLastFailed() } } label: {
                                    Label("Try Again", systemImage: "arrow.clockwise")
                                }
                                .buttonStyle(.bordered)
                                .disabled(isBlocked)
                            }
                            if brain.isThinking && brain.pendingConfirmation == nil {
                                HStack(spacing: 10) {
                                    ProgressView().controlSize(.small)
                                    Text("Thinking…").foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .padding(28)
                .frame(maxWidth: 800)
                .frame(maxWidth: .infinity)
                .ivyGlassGroup()
            }
            .onChange(of: brain.messages.last?.id) {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { proxy.scrollTo("latest", anchor: .bottom) }
            }
            .onChange(of: brain.conversationID) { proxy.scrollTo("latest", anchor: .bottom) }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 24) {
            IvyAppIconView().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 10) {
                Text(brain.isGeminiKeyConfigured ? "What are we working on?" : "Make yourself at home.")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                Text(brain.isGeminiKeyConfigured
                     ? "Ask a question, talk it through, or show me what's on your screen."
                     : "Connect Gemini in Settings to start chatting. Your API key stays in the macOS Keychain.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if brain.isGeminiKeyConfigured {
                VStack(spacing: 8) {
                    suggestion("Talk through an idea", symbol: "lightbulb", prompt: "Help me think through an idea.")
                    suggestion("Break down a task", symbol: "checklist", prompt: "Help me break this task into clear steps: ")
                    suggestion("Explain something", symbol: "text.bubble", prompt: "Explain this to me: ")
                }
            } else {
                SettingsLink { Label("Open Settings", systemImage: "key") }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: 440, alignment: .leading)
        .frame(maxWidth: .infinity, minHeight: 340)
        .padding(.vertical, 24)
    }

    private func suggestion(_ title: String, symbol: String, prompt: String) -> some View {
        Button { inputText = prompt } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 20).foregroundStyle(IvyTheme.moss)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.left").foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .disabled(isBlocked)
    }

    private func send() {
        guard !isBlocked else { return }
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.attachments.isEmpty else { return }
        onShowChat?()
        // "/agent <goal>" plans a multi-step task; nothing runs until the plan is approved.
        if trimmed.lowercased().hasPrefix("/agent ") {
            let goal = String(trimmed.dropFirst("/agent ".count))
            guard tasks.run?.isActive != true, !brain.isThinking, brain.pendingConfirmation == nil else { return }
            inputText = ""
            drafts[brain.conversationID] = ""
            Task { await tasks.start(goal: goal) }
            return
        }
        // One approval surface at a time: chat waits while a task is active.
        guard tasks.run?.isActive != true else { return }
        guard !trimmed.isEmpty || !attachments.attachments.isEmpty, !brain.isThinking, brain.pendingConfirmation == nil,
              !attachments.isWorking else { return }
        inputText = ""
        drafts[brain.conversationID] = ""
        let attached = attachments.take()
        Task { await brain.send(trimmed, attachments: attached) }
    }

    private func accept(_ providers: [NSItemProvider]) {
        let tray = attachments
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in await tray.addFile(url) }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in await tray.addImageData(data) }
                }
            }
        }
    }

    private func toggleLive() {
        if liveVoiceCoordinator.state.isLive {
            Task { await liveVoiceCoordinator.stopSession() }
        } else {
            voiceManager.stop()
            Task { await liveVoiceCoordinator.startSession() }
        }
    }

    /// A suggestion (proactive notification, screen-help hotkey) goes into an empty composer; it is never sent
    /// for the user.
    private func takeSuggestedPrompt() {
        guard let prompt = proactive.pendingPrompt ?? attachments.suggestedPrompt else { return }
        guard inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        inputText = prompt
        proactive.pendingPrompt = nil
        attachments.suggestedPrompt = nil
    }
}

/// Native text treatments with copy and read-aloud actions that remain keyboard reachable.
struct MessageRowView: View {
    let message: ChatMessage
    @ObservedObject var voiceManager: VoicePlaybackManager

    var body: some View {
        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 10) {
            HStack(spacing: 8) {
                if message.role != .user {
                    Image(systemName: message.isError ? "exclamationmark.triangle" : "leaf")
                        .foregroundStyle(message.isError ? Color.red : IvyTheme.moss)
                }
                Text(message.role == .user ? "You" : "Ivy")
                    .font(.callout.weight(.semibold))
                Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if message.role == .user {
                if !message.text.isEmpty {
                    Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .padding(14)
                    .ivyGlass(cornerRadius: 16, tinted: true)
                }
                if !message.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(message.attachments) { AttachmentChip(attachment: $0, onRemove: nil) }
                        }
                    }
                }
            } else {
                MessageBlocksView(text: message.text)
                HStack(spacing: 8) {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.text, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                    if !message.isError {
                        Button { voiceManager.togglePlayback(for: message) } label: {
                            Label(voiceManager.isPlaying(messageId: message.id) ? "Stop Reading" : "Read Aloud",
                                  systemImage: voiceManager.isPlaying(messageId: message.id) ? "stop.fill" : "speaker.wave.2")
                        }
                    }
                }
                .ivyGlassButtonStyle()
                .controlSize(.regular)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .accessibilityElement(children: .contain)
    }
}

private struct ChatInstructionsKey: FocusedValueKey { typealias Value = Binding<Bool> }
extension FocusedValues {
    var ivyChatInstructions: Binding<Bool>? {
        get { self[ChatInstructionsKey.self] }
        set { self[ChatInstructionsKey.self] = newValue }
    }
}
