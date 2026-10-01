import SwiftUI
import UniformTypeIdentifiers
import IvyCore

/// Ivy's main window: conversation sidebar + chat. Same brain, library and voice objects as the popover, so
/// both always show the same conversation and the same (single) approval state.
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

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(library: library, brain: brain, workspaces: workspaces, tasks: tasks)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            ChatPaneView(brain: brain, voiceManager: voiceManager, liveVoiceCoordinator: liveVoiceCoordinator, proactive: proactive,
                         attachments: attachments, tasks: tasks, columns: $columns)
        }
        // Compact mode: narrow the window (down to 420 pt) and hide the sidebar.
        .frame(minWidth: 420, minHeight: 420)
    }
}

/// The conversation itself: header, messages as blocks, the approval card when one is pending, and the composer.
struct ChatPaneView: View {
    @ObservedObject var brain: IvyBrain
    @ObservedObject var voiceManager: VoicePlaybackManager
    @ObservedObject var liveVoiceCoordinator: GeminiLiveVoiceCoordinator
    @ObservedObject var proactive: ProactiveEngine
    @ObservedObject var attachments: AttachmentTray
    @ObservedObject var tasks: TaskEngine
    @Binding var columns: NavigationSplitViewVisibility
    @State private var inputText = ""
    @State private var editingInstructions = false
    @State private var instructionsDraft = ""
    @State private var instructionsError: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            if let request = liveVoiceCoordinator.pendingConfirmation {
                ConfirmationCardView(request: request) { approved in
                    liveVoiceCoordinator.respondToPendingConfirmation(id: request.id, approved: approved)
                }
                .padding(12)
                Divider()
            } else if let request = brain.pendingConfirmation {
                ConfirmationCardView(request: request) { approved in
                    brain.respondToPendingConfirmation(id: request.id, approved: approved)
                }
                .padding(12)
                Divider()
            }
            TaskCardView(engine: tasks)
            AttachmentBar(tray: attachments)
            MessageInputBar(
                text: $inputText,
                isThinking: brain.isThinking || brain.pendingConfirmation != nil || liveVoiceCoordinator.state == .toolConfirmation,
                isVoiceActive: liveVoiceCoordinator.state.isLive,
                onToggleVoice: toggleLive
            ) {
                send()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // Dropped files and pasted images become attachments (images and PDFs only).
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            accept(providers)
            return true
        }
        .onPasteCommand(of: [.fileURL, .png, .tiff, .jpeg]) { providers in
            accept(providers)
        }
        .onAppear(perform: takeSuggestedPrompt)
        .onChange(of: attachments.suggestedPrompt) { takeSuggestedPrompt() }
        .onChange(of: proactive.pendingPrompt) { takeSuggestedPrompt() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help("Show or hide conversations (⌃⌘S)")
            .accessibilityLabel(columns == .detailOnly ? "Show conversations" : "Hide conversations")
            Text(brain.messages.isEmpty ? "New conversation" : brain.currentConversation.displayTitle)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            if brain.isThinking {
                ProgressView().controlSize(.small)
            }
            if let context = brain.currentConversation.systemContext, !context.isEmpty {
                Label("Custom", systemImage: "text.badge.star")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(IvyTheme.moss)
                    .help("This chat has its own instructions: \(context)")
            }
            Spacer()
            Button {
                instructionsDraft = brain.currentConversation.systemContext ?? ""
                instructionsError = nil
                editingInstructions = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Instructions for this chat only")
            .accessibilityLabel("Instructions for this chat")
            if liveVoiceCoordinator.state.isLive {
                Label(liveVoiceCoordinator.state == .toolConfirmation ? "Approve below" : "Ivy Live", systemImage: "waveform")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(IvyTheme.leaf)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .alert("Instructions for This Chat", isPresented: $editingInstructions) {
            TextField("e.g. Answer in British English; I'm debugging Swift", text: $instructionsDraft)
            Button("Save") { saveInstructions() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(instructionsError ?? "Added to Ivy's instructions in this conversation only. They can't change what Ivy may do.")
        }
    }

    /// Same rules as custom instructions: sensitive-looking text is refused, length is capped.
    private func saveInstructions() {
        let text = instructionsDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if let reason = SensitiveDataDetector.reason(text) {
            instructionsError = "Not saved: this looks like \(reason)."
            editingInstructions = true
            return
        }
        let capped = String(text.prefix(PersonalizationProfile.maxCustomInstructions))
        brain.updateConversation { $0.systemContext = capped.isEmpty ? nil : capped }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if brain.messages.isEmpty {
                    VStack(spacing: 10) {
                        Image(nsImage: IvyLogoImage.template)
                            .renderingMode(.template)
                            .resizable()
                            .frame(width: 44, height: 44)
                            .foregroundStyle(IvyTheme.leaf)
                            .accessibilityHidden(true)
                        Text("Ivy is ready.").font(IvyTheme.voiceFont)
                        Text(brain.isGeminiKeyConfigured
                             ? "Ask something. Make it interesting. Start with /agent for a multi-step task."
                             : "Add your Gemini API key in the menu-bar settings first. I can't think without it.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                } else {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(brain.messages) { message in
                            MessageRowView(message: message, voiceManager: voiceManager)
                                .id(message.id)
                        }
                        if brain.retryableMessage != nil {
                            Button {
                                Task { await brain.retryLastFailed() }
                            } label: {
                                Label("Try again", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.bordered)
                            .tint(IvyTheme.leaf)
                            .help("Send the last message again")
                        }
                        if brain.isThinking && brain.pendingConfirmation == nil {
                            Text("Ivy is formulating a sharp reply…")
                                .font(.system(size: 12))
                                .italic()
                                .foregroundStyle(.secondary)
                                .id("thinking")
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
            }
            .onChange(of: brain.messages.count) {
                if let last = brain.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onAppear {
                if let last = brain.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func send() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        // "/agent <goal>" plans a multi-step task; nothing runs until the plan is approved.
        if trimmed.lowercased().hasPrefix("/agent ") {
            let goal = String(trimmed.dropFirst("/agent ".count))
            guard tasks.run?.isActive != true, !brain.isThinking, brain.pendingConfirmation == nil else { return }
            inputText = ""
            Task { await tasks.start(goal: goal) }
            return
        }
        // One approval surface at a time: chat waits while a task is active.
        guard tasks.run?.isActive != true else { return }
        guard !trimmed.isEmpty || !attachments.attachments.isEmpty, !brain.isThinking, brain.pendingConfirmation == nil,
              !attachments.isWorking else { return }
        inputText = ""
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
        proactive.pendingPrompt = nil
        attachments.suggestedPrompt = nil
        if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            inputText = prompt
        }
    }
}

/// One chat line: the user's as a bubble; Ivy's as Markdown/code/diff blocks with read-aloud; errors as before.
private struct MessageRowView: View {
    let message: ChatMessage
    @ObservedObject var voiceManager: VoicePlaybackManager

    var body: some View {
        if message.role == .user || message.isError {
            VStack(alignment: .trailing, spacing: 4) {
                ChatBubbleView(message: message, voiceManager: voiceManager)
                if !message.attachments.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(message.attachments) { attachment in
                            AttachmentChip(attachment: attachment, onRemove: nil)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            HStack(alignment: .top, spacing: 10) {
                Image(nsImage: IvyLogoImage.template)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(IvyTheme.leaf)
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    MessageBlocksView(text: message.text)
                    HStack(spacing: 10) {
                        Text(message.timestamp.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Button {
                            voiceManager.togglePlayback(for: message)
                        } label: {
                            Image(systemName: voiceManager.isPlaying(messageId: message.id) ? "stop.fill" : "speaker.wave.2")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(voiceManager.isPlaying(messageId: message.id) ? "Stop reading aloud" : "Read aloud")
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc").font(.system(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Copy reply")
                    }
                }
                Spacer(minLength: 40)
            }
            .padding(10)
            .background(IvyTheme.sprout.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: IvyTheme.bubbleRadius, style: .continuous))
        }
    }
}
