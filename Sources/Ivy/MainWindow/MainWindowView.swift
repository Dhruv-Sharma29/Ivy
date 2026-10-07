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
    @ObservedObject var router: AppRouter
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var destination: WorkspaceDestination
    @State private var selectedTaskID: UUID?
    @State private var promptRequest: WorkspacePrompt?
    @State private var isNewTaskDraft = false

    init(brain: IvyBrain, library: ConversationLibrary, voiceManager: VoicePlaybackManager,
         liveVoiceCoordinator: GeminiLiveVoiceCoordinator, proactive: ProactiveEngine,
         attachments: AttachmentTray, tasks: TaskEngine, workspaces: WorkspaceModel, router: AppRouter = AppRouter()) {
        self.brain = brain
        self.library = library
        self.voiceManager = voiceManager
        self.liveVoiceCoordinator = liveVoiceCoordinator
        self.proactive = proactive
        self.attachments = attachments
        self.tasks = tasks
        self.workspaces = workspaces
        self.router = router
        // Seed a newly opened window from the active session; subsequent navigation stays view-owned.
        self._destination = State(initialValue: liveVoiceCoordinator.state.isLive || router.chatNavigationID != nil ? .chat : .home)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = router.navigationError {
                HStack {
                    Label(error, systemImage: "info.circle").font(.callout)
                    Spacer()
                    Button("Dismiss", action: router.dismissNavigationError)
                }
                .padding(12)
                .background(.regularMaterial)
            }
            NavigationSplitView(columnVisibility: $columns) {
                SidebarView(library: library, brain: brain, workspaces: workspaces, tasks: tasks, destination: $destination,
                            selectedTaskID: $selectedTaskID, onNewTask: {
                                selectedTaskID = nil; isNewTaskDraft = true
                                promptRequest = WorkspacePrompt(text: "/agent "); destination = .tasks
                            }, isNewTaskDraft: isNewTaskDraft)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
            } detail: {
                ChatPaneView(brain: brain, voiceManager: voiceManager, liveVoiceCoordinator: liveVoiceCoordinator,
                             proactive: proactive, attachments: attachments, tasks: tasks,
                             library: library, destination: destination, selectedTaskID: selectedTaskID, promptRequest: promptRequest,
                             onShowChat: { destination = .chat }, onShowTask: {
                                 selectedTaskID = $0; isNewTaskDraft = $0 == nil; destination = .tasks
                             })
                    .frame(minWidth: 320)
            }
            .navigationSplitViewStyle(.balanced)
        }
        .tint(IvyTheme.leaf)
        .frame(minWidth: 560, minHeight: 480)
        .toolbar(.hidden, for: .windowToolbar)
        .onChange(of: liveVoiceCoordinator.state.isLive) { _, live in
            if live { destination = .chat }
        }
        .onChange(of: router.chatNavigationID) { destination = .chat }
        .onChange(of: selectedTaskID) { if selectedTaskID != nil { isNewTaskDraft = false } }
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
    var selectedTaskID: UUID? = nil
    var promptRequest: WorkspacePrompt? = nil
    var onShowChat: (() -> Void)? = nil
    var onShowTask: ((UUID?) -> Void)? = nil
    @StateObject private var taskSession: TaskWorkspaceSession
    @State private var inputText = ""
    @State private var drafts: [UUID: String] = [:]
    @State private var editingInstructions = false
    @State private var instructionsDraft = ""
    @State private var instructionsError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(brain: IvyBrain, voiceManager: VoicePlaybackManager, liveVoiceCoordinator: GeminiLiveVoiceCoordinator,
         proactive: ProactiveEngine, attachments: AttachmentTray, tasks: TaskEngine,
         library: ConversationLibrary? = nil, showsHome: Bool = false, destination: WorkspaceDestination? = nil,
         selectedTaskID: UUID? = nil, promptRequest: WorkspacePrompt? = nil,
         onShowChat: (() -> Void)? = nil, onShowTask: ((UUID?) -> Void)? = nil) {
        self.brain = brain; self.voiceManager = voiceManager; self.liveVoiceCoordinator = liveVoiceCoordinator
        self.proactive = proactive; self.attachments = attachments; self.tasks = tasks
        self.library = library; self.showsHome = showsHome; self.destination = destination
        self.selectedTaskID = selectedTaskID; self.promptRequest = promptRequest
        self.onShowChat = onShowChat; self.onShowTask = onShowTask
        _taskSession = StateObject(wrappedValue: TaskWorkspaceSession(engine: tasks))
    }

    private var isBlocked: Bool {
        brain.isThinking || brain.pendingConfirmation != nil || liveVoiceCoordinator.state.isLive
            || tasks.run?.isActive == true || attachments.isWorking
    }

    private var currentDestination: WorkspaceDestination { destination ?? (showsHome ? .home : .chat) }

    var body: some View {
        VStack(spacing: 0) {
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
            if currentDestination == .home, let library {
                IvyHomeView(library: library, brain: brain, tasks: tasks,
                            onPrompt: routePrompt, onOpenConversation: { onShowChat?() },
                            onCapture: { Task { await attachments.capture(.frontWindow) } })
            } else if currentDestination == .library, let library {
                LibraryWorkspaceView(library: library, tasks: tasks, blocked: isBlocked,
                    onOpenConversation: { onShowChat?() }, onOpenTask: { onShowTask?($0) },
                    onPrompt: routePrompt)
            } else if currentDestination == .tasks {
                TasksWorkspaceView(tasks: tasks, session: taskSession, selectedTaskID: selectedTaskID,
                                   blocked: isBlocked, onSelect: onShowTask)
            } else {
                messages
            }
            VStack(spacing: 0) {
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
                if currentDestination == .home || currentDestination == .chat {
                    AttachmentBar(tray: attachments)
                    MessageInputBar(text: $inputText, isThinking: isBlocked,
                                    isVoiceActive: liveVoiceCoordinator.state.isLive,
                                    hasAttachments: !attachments.attachments.isEmpty,
                                    onToggleVoice: toggleLive, attachmentTray: attachments, onSend: send)
                }
            }
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
        .ivyWindowBackground()
        .navigationTitle(currentDestination == .chat
                         ? (brain.messages.isEmpty ? "New conversation" : brain.currentConversation.displayTitle)
                         : currentDestination.rawValue)
        .sheet(item: sheetPresentation) { sheet in
            switch sheet {
            case .instructions:
                instructionsSheet
            case .approval(let request, _):
                ConfirmationSheetView(request: request) { approved in
                    respond(to: sheet, approved: approved)
                }
            }
        }
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
        .onChange(of: promptRequest?.id, initial: true) {
            if let promptRequest { routePrompt(promptRequest.text) }
        }
        .onAppear(perform: takeSuggestedPrompt)
        .onChange(of: attachments.suggestedPrompt) { takeSuggestedPrompt() }
        .onChange(of: proactive.pendingPrompt) { takeSuggestedPrompt() }
        .onChange(of: brain.conversationID) { old, new in
            drafts[old] = inputText
            inputText = drafts[new] ?? ""
            onShowChat?()
        }
    }

    func routePrompt(_ prompt: String) {
        let command = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if command == "/agent" || command.hasPrefix("/agent ") {
            guard !isBlocked else { return }
            taskSession.newTask(prompt: prompt == "/agent " ? "" : prompt)
            onShowTask?(nil)
        } else {
            inputText = prompt
            onShowChat?()
        }
    }

    var presentedSheet: ChatSheet? {
        if let request = liveVoiceCoordinator.pendingConfirmation { return .approval(request, live: true) }
        if let request = brain.pendingConfirmation { return .approval(request, live: false) }
        return editingInstructions ? .instructions : nil
    }

    var sheetPresentation: Binding<ChatSheet?> {
        // Capture the displayed identity: dismissing an old sheet must never answer a newer request.
        let displayed = presentedSheet
        return Binding(get: { presentedSheet }, set: { value in
            if value == nil, let displayed { respond(to: displayed, approved: false) }
        })
    }

    func respond(to sheet: ChatSheet, approved: Bool) {
        switch sheet {
        case .instructions:
            editingInstructions = false
        case .approval(let request, let live):
            if live {
                liveVoiceCoordinator.respondToPendingConfirmation(id: request.id, approved: approved)
            } else {
                brain.respondToPendingConfirmation(id: request.id, approved: approved)
            }
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
                    if brain.messages.isEmpty {
                        emptyState
                    }
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ChatFeedView(messages: brain.messages, activity: brain.toolDispatcher.activity,
                                     voice: voiceManager, onApplyDiff: { draft in
                            inputText = DiffDraft.appending(draft, to: inputText)
                            onShowChat?()
                        })
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
        // "/agent <goal>" plans a multi-step task; nothing runs until the plan is approved.
        if trimmed.lowercased().hasPrefix("/agent ") {
            guard tasks.run?.isActive != true, !brain.isThinking, brain.pendingConfirmation == nil else { return }
            inputText = ""
            drafts[brain.conversationID] = ""
            taskSession.newTask(prompt: trimmed)
            onShowTask?(nil)
            Task { await taskSession.send() }
            return
        }
        // "/desktop <goal>" plans an adaptive desktop control task.
        if trimmed.lowercased().hasPrefix("/desktop ") {
            let commandText = String(trimmed.dropFirst("/desktop ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard tasks.run?.isActive != true, !brain.isThinking, brain.pendingConfirmation == nil else { return }
            inputText = ""
            drafts[brain.conversationID] = ""
            onShowTask?(nil)
            let (bundleID, goal) = CommandBarSession.parseDesktopCommand(commandText)
            Task {
                let targetApp: String
                if let bundleID {
                    targetApp = bundleID
                } else if let front = await attachments.capturer.frontmostOtherApp() {
                    targetApp = front
                } else {
                    targetApp = "com.apple.finder"
                }
                let scope = ComputerControlScope(bundleIdentifier: targetApp, isAuthorized: true)
                let result = await tasks.startAdaptiveDesktop(goal: goal, scope: scope)
                if result.isStarted, let id = tasks.run?.id {
                    taskSession.select(id)
                    onShowTask?(id)
                }
            }
            return
        }
        // One approval surface at a time: chat waits while a task is active.
        guard tasks.run?.isActive != true else { return }
        guard !trimmed.isEmpty || !attachments.attachments.isEmpty, !brain.isThinking, brain.pendingConfirmation == nil,
              !attachments.isWorking else { return }
        inputText = ""
        drafts[brain.conversationID] = ""
        let attached = attachments.take()
        onShowChat?()
        Task { await brain.send(trimmed, attachments: attached) }
    }

    private func accept(_ providers: [NSItemProvider]) {
        if currentDestination == .library || currentDestination == .tasks { onShowChat?() }
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

enum ChatSheet: Identifiable {
    case instructions
    case approval(ConfirmationRequest, live: Bool)

    var id: String {
        switch self {
        case .instructions: "instructions"
        case .approval(let request, let live): "\(live ? "live" : "chat")-\(request.id)"
        }
    }
}

/// Native text treatments with copy and read-aloud actions that remain keyboard reachable.
struct MessageRowView: View {
    let message: ChatMessage
    @ObservedObject var voiceManager: VoicePlaybackManager
    var onApplyDiff: ((String) -> Void)? = nil
    @State private var readClickCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                MessageBlocksView(text: message.text, onApplyDiff: onApplyDiff)
                HStack(spacing: 8) {
                    MessageCopyButton(text: message.text)
                    if !message.isError {
                        let preparing = voiceManager.isSynthesizing(messageId: message.id)
                        let reading = voiceManager.isPlaying(messageId: message.id)
                        Button {
                            readClickCount += 1
                            voiceManager.togglePlayback(for: message)
                        } label: {
                            HStack(spacing: 6) {
                                if preparing {
                                    ProgressView().controlSize(.mini).frame(width: 14, height: 14)
                                } else {
                                    Image(systemName: reading ? "stop.fill" : "speaker.wave.2")
                                        .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                                }
                                Text(preparing ? "Preparing…" : (reading ? "Stop Reading" : "Read Aloud"))
                            }
                        }
                        .modifier(MessageActionFeedback(trigger: readClickCount))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: reading)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: preparing)
                        .help(preparing ? "Cancel preparing audio" : (reading ? "Stop reading this message" : "Read this message aloud"))
                        .accessibilityLabel(preparing ? "Cancel preparing audio" : (reading ? "Stop Reading" : "Read Aloud"))
                        .accessibilityValue(preparing ? "Preparing audio" : (reading ? "Playing" : ""))
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
