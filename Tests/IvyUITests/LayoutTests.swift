import AppKit
import SwiftUI
import QuartzCore
import Testing
import os
@testable import Ivy
@testable import IvyCore

@MainActor
@Suite("Native interface layouts", .serialized)
struct LayoutTests {
    @Test("late voice tool cards render below their triggering question in light and dark chat")
    func lateVoiceToolOrdering() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-feed-order-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let request = ChatMessage(role: .user, text: "Open DBS MS folder", timestamp: Date(timeIntervalSince1970: 5))
        let reply = ChatMessage(role: .model, text: "I couldn't find that folder. Please check its location.", timestamp: Date(timeIntervalSince1970: 6))
        let activity = ToolActivity()
        let id = activity.begin(FunctionCall(name: "finder", args: ["action": "open", "path": "~/Documents/DBS MS"]),
            now: Date(timeIntervalSince1970: 1), requestMessageID: request.id)
        activity.complete(id, response: FunctionResponse(name: "finder", response: ["success": false, "error": "Folder not found."]))
        let voice = VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: MockAudioPlayer())
        #expect(ChatFeedTimeline.items(messages: [request, reply], records: activity.records).map(\.id) ==
            ["message-\(request.id)", "tool-\(id)", "message-\(reply.id)"])
        for scheme in [ColorScheme.light, .dark] {
            try await snapshot(ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ChatFeedView(messages: [request, reply], activity: activity, voice: voice, onApplyDiff: nil)
                }.padding(24)
            }.environment(\.ivyOpaqueSurfaces, true).background(IvyTheme.canvas), scheme: scheme,
                size: NSSize(width: 720, height: 430), url: directory.appendingPathComponent("chat-order-\(scheme).png"))
        }
    }

    @Test("Task conversation stays in Tasks and real step flows render at narrow/wide widths")
    func taskConversationsAndFlows() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-task-ui-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = InMemoryTaskStore()
        let statuses: [StepStatus] = [.succeeded, .running, .failed("Couldn't read a file."), .skipped("Skipped after review."), .cancelled, .pending]
        let steps = statuses.enumerated().map { index, status in
            var step = TaskStep(id: String(index + 1), title: "Review stage \(index + 1)", tool: index == 0 ? "ui_type" : "file_op",
                arguments: index == 0 ? ["text": AnyCodable("private fixture text")] : ["path": AnyCodable("/tmp/fixture.txt")],
                dependsOn: index == 0 ? [] : [String(index)])
            step.status = status; step.output = "Fixture output for stage \(index + 1)."
            return step
        }
        var saved = TaskRun(plan: TaskPlan(goal: "Review my project and explain the next steps", steps: steps),
                            phase: .finished(.failed), createdAt: .distantPast, origin: .taskWorkspace)
        saved.report = "The review found one unavailable file. **No files were changed.**"
        try store.save(saved)
        let environment = IvyAppEnvironment(settingsStore: LayoutSettingsStore(),
            credentials: FixedCredentialProvider([.geminiAPIKey: "fixture-not-a-real-key"]),
            conversationStore: FileConversationStore(directory: directory.appendingPathComponent("history-" + UUID().uuidString)), geminiClient: LayoutOfflineClient(),
            taskPlanner: LayoutFlowPlanner(), taskStore: store) { _, _ in
                GeminiLiveVoiceCoordinator(session: MockGeminiLiveSession(), audioCapture: MockAudioCapture(), audioPlayer: MockLiveAudioPlayer())
            }
        let session = TaskWorkspaceSession(engine: environment.tasks)
        var selections: [UUID?] = []
        let actions = TasksWorkspaceView(tasks: environment.tasks, session: session, blocked: false, onSelect: { selections.append($0) })
        actions.draft("/agent Review my folder")
        #expect(session.draft == "Review my folder" && environment.tasks.run == nil && selections.count == 1)
        actions.newTask()
        var blocked = actions; blocked = TasksWorkspaceView(tasks: environment.tasks, session: session, blocked: true)
        blocked.draft("Prepare the next task"); blocked.newTask()
        #expect(session.draft == "Prepare the next task" && session.isNewTask)
        blocked.send()
        for _ in 0..<10 { await Task.yield() }
        #expect(environment.tasks.run == nil, "Drafting while busy must not plan or execute")
        var chatNavigations = 0, taskNavigations = 0
        await environment.liveCoordinator.beginPushToTalk()
        #expect(environment.liveCoordinator.state.isLive)
        let pane = ChatPaneView(brain: environment.brain, voiceManager: environment.voiceManager,
            liveVoiceCoordinator: environment.liveCoordinator, proactive: environment.proactive,
            attachments: environment.attachments, tasks: environment.tasks, destination: .tasks,
            promptRequest: WorkspacePrompt(text: "/agent "), onShowChat: { chatNavigations += 1 },
            onShowTask: { _ in taskNavigations += 1 })
        try await snapshot(pane.environment(\.ivyOpaqueSurfaces, true).background(IvyTheme.canvas), scheme: .dark,
            size: NSSize(width: 760, height: 800), url: directory.appendingPathComponent("task-new-dark.png"))
        #expect(taskNavigations == 1 && chatNavigations == 0 && environment.brain.messages.isEmpty)
        #expect(environment.liveCoordinator.isPushToTalkActive, "Opening a task draft cannot interrupt voice")
        await environment.liveCoordinator.stopSession()
        session.draft = "Review this project"
        actions.send()
        for _ in 0..<1000 where environment.tasks.run?.phase != .awaitingApproval { await Task.yield() }
        #expect(environment.tasks.run?.phase == .awaitingApproval)
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(350), 840] {
                try await snapshot(TasksWorkspaceView(tasks: environment.tasks, session: session, blocked: true)
                    .environment(\.ivyOpaqueSurfaces, true).background(IvyTheme.canvas), scheme: scheme,
                    size: NSSize(width: width, height: 800), url: directory.appendingPathComponent("task-review-\(scheme)-\(Int(width)).png"))
            }
            try await snapshot(ScrollView { TaskFlowDiagram(steps: steps, expandedDetails: true).padding(20) }
                .environment(\.ivyOpaqueSurfaces, true).background(IvyTheme.canvas), scheme: scheme,
                size: NSSize(width: 700, height: 1400), url: directory.appendingPathComponent("task-flow-details-\(scheme).png"))
            try await snapshot(VStack(spacing: 16) {
                TaskFlowDiagram(steps: [], phase: .planning)
                TaskFlowDiagram(steps: [], phase: .finished(.failed))
                TaskFlowDiagram(steps: [])
            }.padding(20).environment(\.ivyOpaqueSurfaces, true).background(IvyTheme.canvas), scheme: scheme,
                size: NSSize(width: 650, height: 740), url: directory.appendingPathComponent("task-flow-empty-\(scheme).png"))
            let historySession = TaskWorkspaceSession(engine: environment.tasks)
            try await snapshot(TasksWorkspaceView(tasks: environment.tasks, session: historySession,
                selectedTaskID: saved.id, blocked: true).environment(\.ivyOpaqueSurfaces, true).background(IvyTheme.canvas),
                scheme: scheme, size: NSSize(width: 840, height: 1050), url: directory.appendingPathComponent("task-history-\(scheme).png"))
        }
        environment.tasks.cancel()
    }

    @Test("push-to-talk registration failures and alternate shortcut remain visible in General")
    func pushToTalkRegistrationFeedback() async throws {
        let status = PushToTalkShortcutStatus()
        let settings = SettingsModel(store: LayoutSettingsStore())
        settings.settings.pushToTalkEnabled = true
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-ui-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            settings.settings.pushToTalkShortcut = .commandShiftSpace
            status.error = HotkeyError.registrationFailed(-9878).localizedDescription
            try await snapshot(GeneralSettingsSection(settings: settings, shortcutStatus: status)
                .environment(\.ivyOpaqueSurfaces, true).padding(20).background(IvyTheme.canvas), scheme: scheme,
                size: NSSize(width: 580, height: 600), url: directory.appendingPathComponent("ptt-conflict-\(scheme).png"))
            settings.settings.pushToTalkShortcut = .controlOptionCommandSpace
            status.error = nil
            try await snapshot(GeneralSettingsSection(settings: settings, shortcutStatus: status)
                .environment(\.ivyOpaqueSurfaces, true).padding(20).background(IvyTheme.canvas), scheme: scheme,
                size: NSSize(width: 580, height: 600), url: directory.appendingPathComponent("ptt-ready-\(scheme).png"))
            settings.settings.pushToTalkEnabled = false
            try await snapshot(GeneralSettingsSection(settings: settings, shortcutStatus: status)
                .environment(\.ivyOpaqueSurfaces, true).padding(20).background(IvyTheme.canvas), scheme: scheme,
                size: NSSize(width: 580, height: 600), url: directory.appendingPathComponent("ptt-off-\(scheme).png"))
            settings.settings.pushToTalkEnabled = true
        }
    }

    @Test("settings search finds voice, credentials and permission sections")
    func settingsSearch() {
        #expect(SettingsPane.allCases.count == 9)
        #expect(SettingsPane.allCases.filter { $0.searchText.localizedStandardContains("Gemini") } == [.keys])
        #expect(SettingsPane.allCases.filter { $0.searchText.localizedStandardContains("microphone") } == [.permissions])
        #expect(SettingsPane.allCases.filter { $0.searchText.localizedStandardContains("Hey Ivy") } == [.voice])
        #expect(Set(SettingsPane.allCases.map(\.symbol)).count == 9)
        #expect(SettingsPane.allCases.allSatisfy { $0.rawValue != "Pointer" })
        #expect(SettingsPane.allCases.filter { $0.searchText.localizedStandardContains("cursor") }.isEmpty)
        #expect(!IvyAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test("chat, settings and composers render at compact and expanded sizes in both appearances")
    func layouts() async throws {
        _ = NSApplication.shared
        let icon = try #require(IvyLogoImage.appIcon, "the professional icon must load from the packaged resource bundle")
        #expect(icon.size.width > 100 && icon.size.height > 100)
        #expect(IvyLogoImage.template.isTemplate)
        #expect(IvyLogoImage.template.size == NSSize(width: 18, height: 18))
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-ui-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileConversationStore(directory: directory.appendingPathComponent("history-" + UUID().uuidString))
        let now = Date(timeIntervalSince1970: 1_790_920_800)
        var conversation = Conversation(id: UUID(), createdAt: now, chatMessages: [
            ChatMessage(role: .user, text: "Why is this Swift task racing?", timestamp: now),
            ChatMessage(role: .model, text: "The response arrives after the view changes. Keep the state on the main actor and cancel work when its owner disappears.\n\n```swift\n.task {\n    await model.load()\n}\n```\n\nStart with the smallest fix, then run the tests.", timestamp: now.addingTimeInterval(5))
        ])
        conversation.isPinned = true
        try store.save(conversation)
        let recentFixture = Conversation(id: UUID(), createdAt: now.addingTimeInterval(-30),
            chatMessages: [ChatMessage(role: .user, text: "Help me organize a busy week with meetings, errands and a very long conversation title")])
        try store.save(recentFixture)
        var archivedFixture = Conversation(id: UUID(), createdAt: now.addingTimeInterval(-60),
            chatMessages: [ChatMessage(role: .user, text: "Archived fixture")])
        archivedFixture.archivedAt = now
        try store.save(archivedFixture)
        #expect(HomeShortcut.allCases.count == 6)
        #expect(HomeShortcut.allCases.allSatisfy { !$0.prompt.isEmpty && !$0.detail.isEmpty && !$0.symbol.isEmpty })
        #expect(HomeShortcut.plan.prompt == "/agent ")
        let credentials = FixedCredentialProvider([.geminiAPIKey: "fixture-not-a-real-key"])
        let taskStore = InMemoryTaskStore()
        let statuses: [StepStatus] = [.succeeded, .failed("A file was unavailable."), .skipped("Skipped by you."), .cancelled, .pending, .running]
        let steps = statuses.enumerated().map { index, status in
            var step = TaskStep(id: String(index), title: "Review step \(index + 1)", tool: "file_op")
            step.status = status
            return step
        }
        var savedTask = TaskRun(plan: TaskPlan(goal: "Review my weekly files", steps: steps), phase: .finished(.cancelled), createdAt: now)
        savedTask.finishedAt = now.addingTimeInterval(30)
        savedTask.report = "Reviewed the folder. **No files were moved.**\n\nThe task was stopped before the remaining steps."
        try taskStore.save(savedTask)
        let environment = IvyAppEnvironment(
            settingsStore: LayoutSettingsStore(), credentials: credentials, conversationStore: store,
            geminiClient: LayoutOfflineClient(), taskPlanner: LayoutTaskPlanner(), taskStore: taskStore, now: { now }
        ) { _, _ in
            GeminiLiveVoiceCoordinator(session: MockGeminiLiveSession(), audioCapture: MockAudioCapture(),
                                       audioPlayer: MockLiveAudioPlayer())
        }
        environment.brain.load(conversation)
        let app = IvyApp(environment: environment)
        _ = app.body
        #expect(NSApplication.shared.activationPolicy() == .accessory)
        #expect(MainWindowController.shared != nil)
        IvyAppDelegate().applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        #expect(MainWindowController.shared?.isWorkingInBackground == true)
        var opened = 0
        MainWindowController.shared?.openWindow = { opened += 1 }
        #expect(!IvyAppDelegate().applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        #expect(opened == 0 && MainWindowController.shared?.isWorkingInBackground == true)
        MainWindowController.shared?.show()
        #expect(opened == 1)
        environment.proactive.pendingPrompt = "Fixture suggestion"
        try await Task.sleep(for: .milliseconds(30))
        #expect(opened == 2)
        environment.proactive.pendingPrompt = nil
        let delegate = IvyAppDelegate()
        let savedLink = try #require(URL(string: "ivy://conversation/\(conversation.id)"))
        delegate.application(NSApplication.shared, open: [try #require(URL(string: "ivy://run_shell/rm")), savedLink])
        #expect(opened == 3 && environment.router.selectedConversationID == conversation.id)
        delegate.application(NSApplication.shared, open: [try #require(URL(string: "ivy://new")), savedLink])
        #expect(opened == 4 && environment.brain.messages.isEmpty)
        #expect(environment.brain.conversationID != conversation.id, "only the first recognized URL in a batch is handled")
        delegate.application(NSApplication.shared, open: [try #require(URL(string: "ivy://new?prompt=run"))])
        #expect(opened == 4, "unexpected parameters cannot act or navigate")
        delegate.application(NSApplication.shared, open: [try #require(URL(string: "ivy://conversation/\(UUID())"))])
        #expect(opened == 5 && environment.router.navigationError != nil)
        try await snapshot(IvyWindowRoot(environment: environment, windowController: try #require(MainWindowController.shared)), scheme: .dark,
            size: NSSize(width: 1080, height: 760), url: directory.appendingPathComponent("missing-conversation-link.png"))
        MainWindowController.shared?.openWindow = { opened += 1 }
        delegate.application(NSApplication.shared, open: [savedLink])
        #expect(opened == 6 && environment.brain.conversationID == conversation.id)
        #expect(environment.router.navigationError == nil)
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .light ? "light" : "dark"
            let reply = ChatMessage(role: .model, text: "Here is the answer, ready to copy or read aloud.")
            let synthesizer = MockSpeechSynthesizer(delayDuration: 10)
            let player = MockAudioPlayer()
            player.playbackDuration = 10
            let playback = VoicePlaybackManager(synthesizer: synthesizer, player: player)
            playback.togglePlayback(for: reply)
            #expect(playback.isSynthesizing(messageId: reply.id))
            try await snapshot(MessageRowView(message: reply, voiceManager: playback).padding(16),
                scheme: scheme, size: NSSize(width: 460, height: 180),
                url: directory.appendingPathComponent("reply-preparing-\(name).png"))
            playback.togglePlayback(for: reply)
            #expect(!playback.isPlaying(messageId: reply.id), "preparing audio remains cancellable")
            await Task.yield()
            synthesizer.delayDuration = 0
            playback.togglePlayback(for: reply)
            for _ in 0..<20 where !player.isPlaying { await Task.yield() }
            #expect(player.isPlaying)
            try await snapshot(MessageRowView(message: reply, voiceManager: playback).padding(16),
                scheme: scheme, size: NSSize(width: 460, height: 180),
                url: directory.appendingPathComponent("reply-playing-\(name).png"))
            playback.stop()
            #expect(!player.isPlaying)
            for expanded in [false, true] {
                let folder = ArchivedFolder(isExpanded: .constant(expanded)) {
                    Text("Archived fixture").padding(.vertical, 8)
                }
                .padding(12)
                try await snapshot(folder, scheme: scheme, size: NSSize(width: 240, height: 160),
                    url: directory.appendingPathComponent("archive-\(expanded ? "expanded" : "collapsed")-\(name).png"))
            }
            for width in [CGFloat(560), 1080] {
                let view = IvyWindowRoot(environment: environment, windowController: try #require(MainWindowController.shared))
                try await snapshot(view, scheme: scheme, size: NSSize(width: width, height: 760),
                                   url: directory.appendingPathComponent("chat-\(name)-\(Int(width)).png"))
            }
            let home = IvyHomeView(library: environment.library, brain: environment.brain, tasks: environment.tasks,
                                   onPrompt: { _ in }, onOpenConversation: {}, onCapture: {})
            try await snapshot(home.ivyWindowBackground(), scheme: scheme, size: NSSize(width: 860, height: 1000),
                               url: directory.appendingPathComponent("home-\(name).png"))
            try await snapshot(home.environment(\.ivyOpaqueSurfaces, true).background(IvyTheme.canvas),
                               scheme: scheme, size: NSSize(width: 860, height: 1000),
                               url: directory.appendingPathComponent("home-opaque-\(name).png"))
            try await snapshot(home.environment(\.ivyOpaqueSurfaces, true).background(IvyTheme.canvas),
                               scheme: scheme, size: NSSize(width: 350, height: 1050),
                               url: directory.appendingPathComponent("home-compact-\(name).png"))
            for destination in WorkspaceDestination.allCases where destination != .home && destination != .chat {
                let page = ChatPaneView(brain: environment.brain, voiceManager: environment.voiceManager,
                                       liveVoiceCoordinator: environment.liveCoordinator, proactive: environment.proactive,
                                       attachments: environment.attachments, tasks: environment.tasks,
                                       library: environment.library, destination: destination)
                try await snapshot(page, scheme: scheme, size: NSSize(width: 650, height: 740),
                                   url: directory.appendingPathComponent("workspace-\(destination.id)-\(name).png"))
                try await snapshot(page.environment(\.ivyOpaqueSurfaces, true).background(IvyTheme.canvas),
                                   scheme: scheme, size: NSSize(width: 650, height: 740),
                                   url: directory.appendingPathComponent("workspace-opaque-\(destination.id)-\(name).png"))
            }
            for category in [LibraryCategory.all, .pinned, .reports, .archived] {
                let libraryPage = LibraryWorkspaceView(library: environment.library, tasks: environment.tasks, blocked: false,
                    category: category, layout: .list, onOpenConversation: {}, onOpenTask: { _ in }, onPrompt: { _ in })
                try await snapshot(libraryPage, scheme: scheme, size: NSSize(width: 350, height: 640),
                    url: directory.appendingPathComponent("library-\(category.id)-list-compact-\(name).png"))
            }
            let emptyLibrary = ConversationLibrary(store: FileConversationStore(directory: directory.appendingPathComponent("empty-" + UUID().uuidString)),
                                                   brain: environment.brain)
            try await snapshot(LibraryWorkspaceView(library: emptyLibrary, tasks: environment.tasks, blocked: false,
                category: .conversations, onOpenConversation: {}, onOpenTask: { _ in }, onPrompt: { _ in }),
                scheme: scheme, size: NSSize(width: 350, height: 640),
                url: directory.appendingPathComponent("library-empty-\(name).png"))
            try await snapshot(TasksWorkspaceView(tasks: environment.tasks, session: TaskWorkspaceSession(engine: environment.tasks), selectedTaskID: savedTask.id, blocked: false),
                scheme: scheme, size: NSSize(width: 350, height: 740),
                url: directory.appendingPathComponent("task-report-compact-\(name).png"))
            let region = SystemRegionalPreferences(locale: Locale(identifier: "en_GB"), timeZone: .gmt)
            try await snapshot(RegionalPreferencesView(region: region).padding(20), scheme: scheme,
                               size: NSSize(width: 420, height: 200),
                               url: directory.appendingPathComponent("system-region-\(name).png"))
            let solid = RegionalPreferencesView(region: region).padding(20).ivyGlass(forceOpaque: true)
            try await snapshot(solid, scheme: scheme, size: NSSize(width: 420, height: 240),
                               url: directory.appendingPathComponent("glass-solid-\(name).png"))
            try await snapshot(RegionalPreferencesView(region: region).padding(20).ivyGlass(), scheme: scheme,
                               size: NSSize(width: 420, height: 240),
                               url: directory.appendingPathComponent("glass-contrast-\(name).png"), increasedContrast: true)
            let expanded = DisclosureGroup("About you", isExpanded: .constant(true)) {
                TextField("Name", text: .constant("Fixture"))
            }
            .disclosureGroupStyle(SettingsDisclosureStyle()).padding(20)
            try await snapshot(expanded, scheme: scheme, size: NSSize(width: 420, height: 160),
                               url: directory.appendingPathComponent("expanded-row-\(name).png"))
            for pane in SettingsPane.allCases {
                environment.settings.settings.proactiveEnabled = pane == .proactive
                environment.settings.settings.proactiveCalendar = pane == .proactive
                environment.settings.settings.proactiveBriefing = pane == .proactive
                let settings = SettingsWindowView(environment: environment, settings: environment.settings,
                                                  wakeWord: environment.wakeWord, initialPane: pane)
                try await snapshot(settings, scheme: scheme, size: NSSize(width: 800, height: 600),
                                   url: directory.appendingPathComponent("settings-\(pane.id)-\(name).png"))
            }
            let voice = VoiceSettingsSection(settings: environment.settings, wakeWord: environment.wakeWord, onPreviewVoice: {})
            try await snapshot(voice.padding(20).background(IvyTheme.canvas).tint(IvyTheme.leaf), scheme: scheme,
                               size: NSSize(width: 600, height: 1380), url: directory.appendingPathComponent("voice-full-\(name).png"))
            environment.brain.startNewConversation()
            let empty = ChatPaneView(brain: environment.brain, voiceManager: environment.voiceManager,
                                     liveVoiceCoordinator: environment.liveCoordinator, proactive: environment.proactive,
                                     attachments: environment.attachments, tasks: environment.tasks)
            try await snapshot(empty, scheme: scheme, size: NSSize(width: 560, height: 650),
                               url: directory.appendingPathComponent("empty-\(name).png"))
            try await snapshot(empty.instructionsSheet, scheme: scheme, size: NSSize(width: 480, height: 340),
                               url: directory.appendingPathComponent("instructions-\(name).png"))
            let errorReply = MessageRowView(message: ChatMessage(role: .model, text: "Open Settings and connect Gemini, then try again.", isError: true),
                                            voiceManager: environment.voiceManager)
            try await snapshot(errorReply.padding(24), scheme: scheme, size: NSSize(width: 560, height: 180),
                               url: directory.appendingPathComponent("error-\(name).png"))
            environment.brain.load(conversation)
        }
        await environment.liveCoordinator.startSession()
        #expect(environment.liveCoordinator.state.isLive)
        try await snapshot(IvyWindowRoot(environment: environment, windowController: try #require(MainWindowController.shared)), scheme: .dark,
                           size: NSSize(width: 1080, height: 760), url: directory.appendingPathComponent("active-voice-chat.png"))
        await environment.liveCoordinator.stopSession()
        let multilineComposer = MessageInputBar(text: .constant("First line\nSecond line\nThird line"),
                                                 isThinking: false, onToggleVoice: {}) {}
        try await snapshot(multilineComposer, scheme: .dark, size: NSSize(width: 600, height: 160),
                           url: directory.appendingPathComponent("multiline-composer.png"))
        // The reference-style bar must keep its controls visible when narrow, blocked or live.
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(350), 700] {
                for state in ["empty", "draft", "blocked", "voice"] {
                    let bar = MessageInputBar(text: .constant(state == "draft" ? "Hello Ivy" : ""),
                        isThinking: state == "blocked", isVoiceActive: state == "voice",
                        onToggleVoice: {}, attachmentTray: environment.attachments) {}
                    try await snapshot(bar, scheme: scheme, size: NSSize(width: width, height: 100),
                        url: directory.appendingPathComponent("composer-\(state)-\(scheme == .light ? "light" : "dark")-\(Int(width)).png"))
                }
            }
        }
        // Attachment import failures must remain visible above the compact composer.
        _ = await environment.attachments.addImageData(Data(), name: "invalid fixture")
        #expect(environment.attachments.lastError != nil)
        try await snapshot(AttachmentBar(tray: environment.attachments), scheme: .light,
                           size: NSSize(width: 600, height: 100), url: directory.appendingPathComponent("attachment-error.png"))
        environment.attachments.dismissError()
        #expect(environment.attachments.lastError == nil)
        let approvalBrain = IvyBrain(client: LayoutApprovalClient(), apiKey: "fixture-not-a-real-key")
        let approvalTurn = Task { await approvalBrain.send("Propose a fixture shell action") }
        for _ in 0..<100 where approvalBrain.pendingConfirmation == nil { await Task.yield() }
        let request = try #require(approvalBrain.pendingConfirmation)
        await environment.tasks.start(goal: "Review a folder")
        #expect(environment.tasks.run?.phase == .awaitingApproval)
        let busyConversationID = environment.brain.conversationID
        delegate.application(NSApplication.shared, open: [try #require(URL(string: "ivy://new"))])
        #expect(environment.brain.conversationID == busyConversationID)
        #expect(environment.router.navigationError != nil)
        #expect(environment.tasks.run?.phase == .awaitingApproval, "external links cannot dismiss a task approval")
        environment.router.dismissNavigationError()
        for scheme in [ColorScheme.light, .dark] {
            try await snapshot(TasksWorkspaceView(tasks: environment.tasks, session: TaskWorkspaceSession(engine: environment.tasks), blocked: true),
                scheme: scheme, size: NSSize(width: 650, height: 740),
                url: directory.appendingPathComponent("task-awaiting-plan-\(scheme).png"))
            try await snapshot(SidebarView(library: environment.library, brain: environment.brain,
                workspaces: environment.workspaces, tasks: environment.tasks, destination: .constant(.tasks),
                selectedTaskID: .constant(savedTask.id), onNewTask: {}),
                scheme: scheme, size: NSSize(width: 280, height: 740),
                url: directory.appendingPathComponent("task-sidebar-\(scheme).png"))
        }
        #expect(environment.tasks.run?.phase == .awaitingApproval, "rendering a plan never executes it")
        environment.tasks.cancel()
        let approvalView = ChatPaneView(brain: approvalBrain, voiceManager: environment.voiceManager,
                                       liveVoiceCoordinator: environment.liveCoordinator, proactive: environment.proactive,
                                       attachments: environment.attachments, tasks: environment.tasks)
        try await snapshot(approvalView, scheme: .light, size: NSSize(width: 680, height: 760),
                           url: directory.appendingPathComponent("pending-approval.png"), expectsApproval: true)
        let homeApproval = ChatPaneView(brain: approvalBrain, voiceManager: environment.voiceManager,
            liveVoiceCoordinator: environment.liveCoordinator, proactive: environment.proactive,
            attachments: environment.attachments, tasks: environment.tasks, library: environment.library, destination: .home)
        try await snapshot(homeApproval, scheme: .dark, size: NSSize(width: 560, height: 480),
            url: directory.appendingPathComponent("pending-home-approval-compact.png"), expectsApproval: true)
        let longRequest = ConfirmationRequest(toolName: "run_applescript", title: "AppleScript Execution",
            prompt: String(repeating: "Review this action before running it. ", count: 50),
            detail: String(repeating: "-- Long script fixture\n", count: 100))
        for scheme in [ColorScheme.light, .dark] {
            try await snapshot(ConfirmationSheetView(request: longRequest, onConfirm: { _ in }), scheme: scheme,
                size: NSSize(width: 460, height: 400),
                url: directory.appendingPathComponent("approval-long-\(scheme == .light ? "light" : "dark").png"))
            // The user requested full details in the app only. Preserve compact companion fixtures
            // and all identity/cancellation assertions while exercising long and empty app payloads.
            try await snapshot(ConfirmationCardView(request: longRequest, compact: true, onConfirm: { _ in }),
                scheme: scheme, size: NSSize(width: 240, height: 96),
                url: directory.appendingPathComponent("approval-reason-long-\(scheme).png"))
            try await snapshot(ConfirmationSheetView(request: ConfirmationRequest(
                toolName: "open_app", title: "Open Calculator", prompt: "Open Calculator?", detail: ""),
                onConfirm: { _ in }), scheme: scheme, size: NSSize(width: 460, height: 300),
                url: directory.appendingPathComponent("approval-reason-empty-\(scheme).png"))
        }
        let calendarRequest = ConfirmationRequest(toolName: "calendar_event", title: "Create Calendar Event",
            prompt: "Add ‘Project review’ to your calendar on 2026-10-09 at 10:00?",
            detail: "Action: Create Calendar Event\nTitle: Project review\nDate/Time: 2026-10-09 10:00\nDuration: 1 hour")
        for scheme in [ColorScheme.light, .dark] {
            try await snapshot(ConfirmationSheetView(request: calendarRequest, onConfirm: { _ in
                Issue.record("Rendering an approval must not answer it")
            }), scheme: scheme, size: NSSize(width: 460, height: 400),
                url: directory.appendingPathComponent("approval-calendar-\(scheme).png"))
        }
        #expect(approvalBrain.pendingConfirmation?.id == request.id, "rendering must never approve an action")
        #expect(approvalView.presentedSheet?.id == ChatSheet.approval(request, live: false).id)
        // A stale sheet's response must leave the real pending action untouched.
        approvalView.respond(to: .approval(longRequest, live: false), approved: true)
        #expect(approvalBrain.pendingConfirmation?.id == request.id)
        approvalView.sheetPresentation.wrappedValue = nil
        await approvalTurn.value
        #expect(approvalBrain.pendingConfirmation == nil)
        #expect(approvalView.presentedSheet == nil)
        approvalView.respond(to: .instructions, approved: false)
        approvalView.respond(to: .approval(longRequest, live: true), approved: false)
        await environment.shutdown()
    }

    @Test("companion approvals replace the status bubble below the character without intercepting controls")
    func companionApprovals() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-ui-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let requests = [
            ConfirmationRequest(toolName: "calendar", title: "Create Calendar Event",
                prompt: "Create the reviewed event?", detail: "Calendar fixture only."),
            ConfirmationRequest(toolName: "run_applescript", title: "AppleScript Execution",
                prompt: "Review this action before running it.",
                detail: "tell application \"Safari\"\n    activate\n    open location \"https://www.youtube.com\"\nend tell"),
            ConfirmationRequest(toolName: "file_op", title: "Write a file with a long title for review",
                prompt: String(repeating: "Existing content may be replaced. ", count: 20),
                detail: String(repeating: "Long action preview\n", count: 100)),
        ]
        for (index, request) in requests.enumerated() {
            let presentation = CompanionPresentation()
            presentation.mood = .needsApproval
            presentation.approval = CompanionApproval(request: request, isLive: false)
            var responses: [Bool] = []
            var visibleBounds: CGRect = .zero
            let view = CompanionView(presentation: presentation, meter: AudioLevelMeter(),
                onOpen: {}, onEndVoice: {}, onStopTask: {}, onHide: {}, motionDisabled: true,
                onContentLayout: { visibleBounds = $0 }, onConfirm: { _, answer in responses.append(answer) })
            let size = CompanionView.panelSize(hasApproval: true)
            for scheme in [ColorScheme.light, .dark] {
                try await snapshot(view.environment(\.ivyOpaqueSurfaces, true), scheme: scheme, size: size,
                    url: directory.appendingPathComponent("companion-approval-\(index)-\(scheme).png"),
                    expectsCompanionApproval: true)
                #expect(CGRect(origin: .zero, size: size).contains(visibleBounds))
                #expect(visibleBounds.width >= 228 && visibleBounds.height >= 190,
                        "placement must include the review card, not only the character")
                #expect(visibleBounds.width <= 228 && visibleBounds.height <= 224,
                        "approval must replace the status pill and stay compact even for long previews")
                #expect(responses.isEmpty, "rendering or layout cannot approve an action")
            }
        }
    }

    @Test("native companion layout reports visible bounds without transparent panel margins")
    func companionContentBounds() {
        let surface = CompanionDragSurface()
        var reports: [CGRect] = []
        surface.onLayout = { reports.append($0) }
        surface.reportContentFrame()
        #expect(reports.isEmpty)
        let size = CompanionView.panelSize
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10000, y: 0), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let root = NSView(frame: CGRect(origin: .zero, size: size))
        window.contentView = root
        root.addSubview(surface)
        let content = CGRect(x: 164, y: 8, width: 108, height: 125)
        surface.frame = content
        surface.reportContentFrame()
        surface.reportContentFrame()
        #expect(reports == [content], "unchanged layout must not trigger repositioning")
        surface.frame = CGRect(x: 8, y: 8, width: 264, height: 208)
        surface.layout()
        #expect(reports == [content, surface.frame], "a wider caption must update the drag boundary")
    }

    @Test("glass and opaque accessibility previews keep readable content and correct click routing")
    func glassAccessibility() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-ui-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = VStack(alignment: .leading, spacing: 20) {
            Text("Ivy").font(.largeTitle.weight(.semibold))
            SettingsCard(title: "Everyday assistance", symbol: "sparkles", subtitle: "Clear text on a native glass surface.") {
                HStack {
                    Button("Research") {}.ivyGlassButtonStyle()
                    Button("Send") {}.ivyGlassButtonStyle(prominent: true)
                    Button("Unavailable") {}.ivyGlassButtonStyle().disabled(true)
                }
                Text("Static information stays still.").padding(12).ivyGlass(tinted: true)
                Text("Interactive control").padding(12).ivyGlass(interactive: true)
                Text("Embedded content").ivyGlass(enabled: false)
            }
            Text("Opaque fallback").padding(12).ivyGlass(forceOpaque: true)
        }
        .padding(28)
        .ivyWindowBackground()
        .ivyGlassGroup(spacing: 20)
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .light ? "light" : "dark"
            try await snapshot(fixture, scheme: scheme, size: NSSize(width: 620, height: 440),
                               url: directory.appendingPathComponent("glass-system-\(name).png"), expectsWindowMaterial: true)
            // macOS supplies read-only accessibility environment values; the shared preview override
            // exercises the same opaque rendering path without changing the user's system preferences.
            try await snapshot(fixture.environment(\.ivyOpaqueSurfaces, true), scheme: scheme,
                               size: NSSize(width: 620, height: 440),
                               url: directory.appendingPathComponent("glass-reduced-transparency-\(name).png"), expectsWindowMaterial: false)
            try await snapshot(fixture.environment(\.ivyOpaqueSurfaces, true), scheme: scheme,
                               size: NSSize(width: 620, height: 440),
                               url: directory.appendingPathComponent("glass-increased-contrast-\(name).png"),
                               increasedContrast: true, expectsWindowMaterial: false)
        }
    }

    @Test("settings controls keep one aligned column and reflow at narrow widths")
    func controlAlignment() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-ui-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [CGFloat(300), 560] {
            let frames = OSAllocatedUnfairLock(initialState: [String: CGRect]())
            let rows = VStack(spacing: 20) {
                ForEach(["Pause tolerance", "Answer length", "Speed"], id: \.self) { title in
                    SettingsControlRow(title: title) {
                        SettingsSegmentedPicker(title: title, selection: .constant(1),
                            options: title == "Answer length" ? [(0, "Brief"), (1, "Balanced"), (2, "Detailed")] : [(0, "Short"), (1, "Normal"), (2, "Long")])
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(key: ControlFrames.self,
                                                       value: [title: geometry.frame(in: .named("controls"))])
                            }
                        }
                    }
                }
            }
            .coordinateSpace(name: "controls")
            .onPreferenceChange(ControlFrames.self) { value in frames.withLock { $0 = value } }
            try await snapshot(rows, scheme: .light, size: NSSize(width: width, height: 260),
                               url: directory.appendingPathComponent("alignment-\(Int(width)).png"))
            let measured = frames.withLock { $0 }
            #expect(measured.count == 3)
            let first = try #require(measured["Pause tolerance"])
            for frame in measured.values {
                #expect(abs(frame.minX - first.minX) < 1, "all controls must start at the same column")
                #expect(abs(frame.width - first.width) < 1, "different labels must not change picker width")
                #expect(abs(frame.height - first.height) < 1, "all pickers must have the same height")
                #expect(frame.minX >= 0 && frame.maxX <= width + 1, "controls must stay inside the window")
                #expect(frame.width >= 200 && frame.height >= 18)
            }
            #expect(width == 300 ? first.minX < 1 : first.minX >= 140, "narrow rows must stack their label above the control")
        }
    }

    @Test("Voice preference cards save selections, support bounded arrow navigation and reflow")
    func voiceChoiceCards() async throws {
        let store = LayoutSettingsStore()
        let model = SettingsModel(store: store)
        let choices = SettingsChoiceCards(title: "Answer length", detail: "How much detail to include in a reply.",
            selection: Binding(get: { model.settings.voiceResponseLength }, set: { model.settings.voiceResponseLength = $0 }),
            options: [(.brief, "Brief", "Just the essentials"), (.normal, "Normal", "Enough context"), (.detailed, "Detailed", "More explanation")])
        choices.select(.detailed)
        #expect(store.load().voiceResponseLength == .detailed)
        #expect(choices.moveSelection(by: -1) && model.settings.voiceResponseLength == .normal)
        #expect(choices.moveSelection(by: -1) && model.settings.voiceResponseLength == .brief)
        #expect(choices.moveSelection(by: -1) && model.settings.voiceResponseLength == .brief)
        #expect(choices.moveSelection(by: 1) && store.load().voiceResponseLength == .normal)
        let restored = SettingsModel(store: store)
        #expect(restored.settings.voiceResponseLength == .normal)
        var value = 1
        let empty = SettingsChoiceCards(title: "Empty fixture", detail: "", selection: Binding(get: { value }, set: { value = $0 }),
            options: [(value: Int, title: String, detail: String)]())
        empty.select(2)
        #expect(!empty.moveSelection(by: 1) && value == 1)
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-voice-style-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(300), 600] {
                try await snapshot(SettingsCard(title: "Live conversation", symbol: "waveform",
                    subtitle: "Choose how Ivy speaks during a voice session.") {
                        SettingsChoiceCards(title: "Pause tolerance", detail: "How long Ivy waits when you pause.",
                            selection: .constant(VoicePatience.normal),
                            options: [(.short, "Short", "Quick turns"), (.normal, "Normal", "Natural pauses"), (.long, "Long", "More time to think")])
                        choices
                        SettingsChoiceCards(title: "Speaking pace", detail: "The rhythm of Ivy’s spoken replies.",
                            selection: .constant(VoiceSpeakingPace.normal),
                            options: [(.slow, "Slow", "Unhurried"), (.normal, "Normal", "Natural rhythm"), (.fast, "Fast", "Quicker delivery")])
                    }.padding(20).environment(\.ivyOpaqueSurfaces, true).background(IvyTheme.canvas),
                    scheme: scheme, size: NSSize(width: width, height: width == 300 ? 1080 : 520),
                    url: directory.appendingPathComponent("voice-cards-\(scheme)-\(Int(width)).png"),
                    increasedContrast: width == 300)
            }
        }
    }

    @Test("Personalization cards preserve saved personality and answer length and render adaptively")
    func personalizationChoiceCards() async throws {
        let store = InMemoryPersonalizationStore()
        let model = PersonalizationModel(store: store)
        let panel = PersonalizationPanel(model: model)
        for value in 0...3 {
            panel.personalityChoices.select(value)
            #expect(PersonalizationModel(store: store).profile.sass == value)
        }
        #expect(panel.personalityChoices.moveSelection(by: 1) && model.profile.sass == 3)
        #expect(panel.personalityChoices.moveSelection(by: -1) && model.profile.sass == 2)
        panel.personalityChoices.select(99)
        #expect(model.profile.sass == 2)
        panel.answerLengthChoices.select(.detailed)
        #expect(PersonalizationModel(store: store).profile.responseLength == .detailed)
        #expect(panel.answerLengthChoices.moveSelection(by: -1) && model.profile.responseLength == .balanced)
        #expect(store.load().sass == 2, "answer length must not replace personality")
        let before = model.profile
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-personality-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(340), 720] {
                try await snapshot(ScrollView {
                    panel.padding(20)
                }.environment(\.ivyOpaqueSurfaces, true).background(IvyTheme.canvas),
                    scheme: scheme, size: NSSize(width: width, height: 900),
                    url: directory.appendingPathComponent("personality-\(scheme)-\(Int(width)).png"),
                    increasedContrast: width == 340)
                #expect(model.profile == before, "rendering preferences must not change stored values")
            }
        }
    }

    @Test("personal assistant navigation keeps essential destinations and actions only draft prompts")
    func navigationDestinations() {
        #expect(WorkspaceDestination.railDestinations == [.home, .library, .tasks])
        #expect(WorkspaceDestination.allCases.map(\.rawValue) == ["Home", "Chat", "Library", "Tasks"])
        #expect(Set(WorkspaceDestination.allCases.map(\.id)).count == 4)
        #expect(Set(WorkspaceDestination.allCases.map(\.symbol)).count == 4)
        #expect(WorkspaceDestination.tasks.shortcuts == [.plan])
        #expect(WorkspaceDestination.chat.shortcuts.isEmpty)
        #expect(HomeShortcut.allCases.map(\.rawValue) == ["Research", "Summarize", "Write", "Files", "Explain", "Plan a task"])
        for destination in WorkspaceDestination.allCases {
            #expect(!destination.detail.isEmpty)
            for action in destination.shortcuts {
                #expect(!action.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    @Test("brand text accents remain readable in light, dark and increased contrast appearances")
    func paletteContrast() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try #require(NSAppearance(named: name))
            for background in [IvyTheme.canvas, IvyTheme.surface, IvyTheme.sidebar] {
                for foreground in [IvyTheme.moss, IvyTheme.sectionAccent] {
                    let a = luminance(foreground, appearance: appearance)
                    let b = luminance(background, appearance: appearance)
                    #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
                }
            }
        }
    }

    @Test("native segmented selection updates its binding and ignores an invalid segment")
    func segmentedSelection() {
        var selected = 1
        let picker = SettingsSegmentedPicker(title: "Fixture", selection: Binding(get: { selected }, set: { selected = $0 }),
                                             options: [(0, "Brief"), (1, "Normal"), (2, "Detailed")])
        let coordinator = picker.makeCoordinator()
        let control = NSSegmentedControl(labels: ["Brief", "Normal", "Detailed"], trackingMode: .selectOne, target: nil, action: nil)
        control.selectedSegment = 2
        coordinator.choose(control)
        #expect(selected == 2)
        control.selectedSegment = -1
        coordinator.choose(control)
        #expect(selected == 2)
    }

    @Test("pixel companion selects real activity poses and disables all motion for accessibility")
    func companionAnimation() {
        let cases: [(CompanionMood, Int)] = [(.hidden, 0), (.idle, 0), (.listening, 2), (.thinking, 4),
                                            (.speaking, 6), (.working(0.5), 8), (.needsApproval, 10), (.error("Offline"), 12)]
        for (mood, frame) in cases {
            for time in [0.0, 0.4, 2.0, 4.7, 1000.0] {
                let still = CompanionAnimationSample.sample(mood: mood, elapsed: time, level: 1, reduceMotion: true)
                #expect(still == CompanionAnimationSample(frame: frame, verticalOffset: 0, scale: 1))
                let moving = CompanionAnimationSample.sample(mood: mood, elapsed: time, level: 0.5, reduceMotion: false)
                #expect((0..<16).contains(moving.frame))
                #expect(abs(moving.verticalOffset) <= 2.4 && moving.scale >= 1 && moving.scale <= 1.025)
                #expect(abs(moving.rotationDegrees) <= 1.5)
            }
        }
        func frame(_ mood: CompanionMood, _ time: Double, _ level: Float = 0) -> Int {
            CompanionAnimationSample.sample(mood: mood, elapsed: time, level: level, reduceMotion: false).frame
        }
        #expect(frame(.idle, 0.1) == 14 && frame(.idle, 0.4) == 15, "a short greeting appears once on arrival")
        #expect(frame(.idle, 2) == 0 && frame(.idle, 4.7) == 1, "idle is calm with occasional blinking")
        #expect(frame(.needsApproval, 4.7) == 11)
        #expect(frame(.speaking, 2, 0) == 6 && frame(.speaking, 2, 0.5) == 7, "mouth movement follows playback")
        #expect(frame(.working(0.5), 0.1) == 8 && frame(.working(0.5), 0.6) == 9)
        #expect(frame(.listening, 1.3) == 3 && frame(.thinking, 1.3) == 5 && frame(.error("x"), 1.3) == 13)
        let invalid = CompanionAnimationSample.sample(mood: .speaking, elapsed: .infinity, level: .nan, reduceMotion: false)
        #expect(invalid == CompanionAnimationSample(frame: 6, verticalOffset: 0, scale: 1))
        #expect(CompanionPose.allCases.count == 8)
    }

    @Test("random idle moments are brief, reproducible, spaced apart and safe at invalid times")
    func companionIdleSchedule() {
        #expect(CompanionIdleActivity.allCases == [.phone, .laptop, .blush])
        var activities: Set<Int> = []
        var starts: Set<Double> = []
        for seed in UInt64(0)..<64 {
            for cycle in [0.0, 48.0, 96.0] {
                let samples = (0..<48).compactMap { second -> (Double, CompanionIdleMoment)? in
                    let time = cycle + Double(second)
                    guard let sample = CompanionIdleMoment.sample(elapsed: time, seed: seed) else { return nil }
                    #expect(sample == CompanionIdleMoment.sample(elapsed: time, seed: seed))
                    #expect(sample.elapsed >= 0 && sample.elapsed < sample.activity.duration)
                    #expect((16..<24).contains(sample.animation.frame) || (28..<32).contains(sample.animation.frame))
                    #expect(sample.animation.verticalOffset == (sample.activity == .blush ? -4 : 0))
                    #expect(sample.animation.scale == (sample.activity == .blush ? 0.88 : 1))
                    #expect(sample.animation.rotationDegrees == 0)
                    return (time, sample)
                }
                #expect(!samples.isEmpty)
                if let first = samples.first, let last = samples.last {
                    activities.insert(first.1.activity.rawValue)
                    starts.insert(first.0 - cycle)
                    #expect(first.0 - cycle >= 12 && first.0 - cycle <= 24)
                    #expect(samples.count == Int(first.1.activity.duration))
                    #expect(CompanionIdleMoment.sample(elapsed: first.0 - 0.01, seed: seed) == nil)
                    #expect(CompanionIdleMoment.sample(elapsed: last.0 + 1, seed: seed) == nil)
                    #expect(last.0 - cycle < 35)
                }
            }
        }
        #expect(activities == Set(CompanionIdleActivity.allCases.map(\.rawValue)))
        #expect(starts.count > 1)
        for time in [-1.0, .infinity, -.infinity, .nan] {
            #expect(CompanionIdleMoment.sample(elapsed: time, seed: 0) == nil)
        }
        // Extreme but finite elapsed values cannot overflow an integer conversion.
        _ = CompanionIdleMoment.sample(elapsed: 1e300, seed: .max)
    }

    @Test("idle activities yield immediately to real states, dragging, hiding and Reduce Motion")
    func companionIdleInterruption() throws {
        let time = 12.5 // Seed zero selects the phone at 12 seconds.
        let idle = CompanionAnimationSample.sample(mood: .idle, elapsed: time, level: 0, reduceMotion: false, idleSeed: 0)
        #expect((16..<20).contains(idle.frame))
        for activity in CompanionIdleActivity.allCases {
            let frames = Set((0..<4).map {
                CompanionIdleMoment(activity: activity, elapsed: Double($0) * (activity == .blush ? 0.65 : 0.4)).animation.frame
            })
            #expect(frames == Set(activity.firstFrame..<(activity.firstFrame + 4)))
            let events = (UInt64(0)..<64).lazy.compactMap { seed -> (UInt64, Double)? in
                (12..<35).first { CompanionIdleMoment.sample(elapsed: Double($0), seed: seed)?.activity == activity }
                    .map { (seed, Double($0)) }
            }
            let candidate = events.first
            let event = try #require(candidate)
            let active = CompanionAnimationSample.sample(mood: .idle, elapsed: event.1, level: 0, reduceMotion: false, idleSeed: event.0)
            #expect(frames.contains(active.frame))
            for mood in [CompanionMood.hidden, .listening, .thinking, .speaking, .working(0.5), .needsApproval, .error("Offline")] {
                let actual = CompanionAnimationSample.sample(mood: mood, elapsed: event.1, level: 0.5, reduceMotion: false, idleSeed: event.0)
                let original = CompanionAnimationSample.sample(mood: mood, elapsed: event.1, level: 0.5, reduceMotion: false)
                #expect(actual == original && actual.frame < 16)
            }
            let reduced = CompanionAnimationSample.sample(mood: .idle, elapsed: event.1, level: 1, reduceMotion: true, idleSeed: event.0)
            #expect(reduced == CompanionAnimationSample(frame: 0, verticalOffset: 0, scale: 1))
            let moving = CompanionAnimationSample.sample(mood: .idle, elapsed: event.1, level: 0, reduceMotion: false, isMoving: true, idleSeed: event.0)
            #expect([14, 15].contains(moving.frame))
        }
        for mood in [CompanionMood.hidden, .listening, .thinking, .speaking, .working(0.5), .needsApproval, .error("Offline")] {
            let actual = CompanionAnimationSample.sample(mood: mood, elapsed: time, level: 0.5, reduceMotion: false, idleSeed: 0)
            let original = CompanionAnimationSample.sample(mood: mood, elapsed: time, level: 0.5, reduceMotion: false)
            #expect(actual == original && actual.frame < 16)
        }
        let reduced = CompanionAnimationSample.sample(mood: .idle, elapsed: time, level: 1, reduceMotion: true, idleSeed: 0)
        #expect(reduced == CompanionAnimationSample(frame: 0, verticalOffset: 0, scale: 1))
        let dragged = CompanionAnimationSample.sample(mood: .idle, elapsed: time, level: 0, reduceMotion: false, isMoving: true, idleSeed: 0)
        #expect([14, 15].contains(dragged.frame))
    }

    @Test("all idle artwork frames load transparently and render at companion size")
    func companionIdleArtwork() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-idle-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(CompanionSpriteSheet.idleFrames.count == 8)
        #expect(CompanionSpriteSheet.blushFrames.count == 4)
        #expect(CompanionSpriteSheet.image(for: -1) == nil && CompanionSpriteSheet.image(for: 32) == nil)
        for retiredFrame in 24..<28 { #expect(CompanionSpriteSheet.image(for: retiredFrame) == nil) }
        #expect(CompanionSpriteSheet.image(for: 0) === CompanionSpriteSheet.frames[0])
        for index in Array(16..<24) + Array(28..<32) {
            let frame = try #require(CompanionSpriteSheet.image(for: index))
            let cg = try #require(frame.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let bitmap = NSBitmapImageRep(cgImage: cg)
            #expect(bitmap.hasAlpha && cg.width >= 300 && cg.height >= 300)
            #expect((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.1)
            #expect((bitmap.colorAt(x: cg.width / 2, y: cg.height / 2)?.alphaComponent ?? 0) > 0.5)
        }
        for scheme in [ColorScheme.light, .dark] {
            let gallery = VStack(spacing: 16) {
                ForEach(CompanionIdleActivity.allCases, id: \.rawValue) { activity in
                    VStack(spacing: 8) {
                        Text(String(describing: activity).capitalized).font(.headline)
                        HStack(spacing: 16) {
                            ForEach(0..<4, id: \.self) { index in
                                let sample = CompanionIdleMoment(activity: activity,
                                    elapsed: Double(index) * (activity == .blush ? 0.65 : 0.4)).animation
                                if let image = CompanionSpriteSheet.image(for: sample.frame) {
                                    Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
                                        .frame(width: 96, height: 96)
                                        .scaleEffect(sample.scale, anchor: .bottom)
                                        .rotationEffect(.degrees(sample.rotationDegrees), anchor: .bottom)
                                        .offset(y: sample.verticalOffset)
                                }
                            }
                        }
                    }
                }
            }.padding(24).background(IvyTheme.canvas)
            try await snapshot(gallery, scheme: scheme, size: NSSize(width: 510, height: 465),
                               url: directory.appendingPathComponent("idle-\(scheme).png"))
        }
    }

    @Test("drag tracking moves in desktop coordinates and does not open Ivy when released")
    func companionDragging() {
        let view = CompanionDragSurface()
        var opens = 0
        var drops = 0
        var moving: [Bool] = []
        view.onOpen = { opens += 1 }
        view.onDrop = { drops += 1 }
        view.onMoving = { moving.append($0) }
        #expect(view.acceptsFirstMouse(for: nil) && !view.mouseDownCanMoveWindow)
        view.begin(pointer: CGPoint(x: 100, y: 100), origin: CGPoint(x: 50, y: 70))
        #expect(view.move(pointer: CGPoint(x: CGFloat.nan, y: 100)) == nil)
        #expect(view.move(pointer: CGPoint(x: 102, y: 101)) == nil)
        view.finish()
        #expect(opens == 1 && drops == 0 && moving.isEmpty, "small pointer jitter must stay a click")
        view.begin(pointer: CGPoint(x: 100, y: 100), origin: CGPoint(x: 50, y: 70))
        #expect(view.move(pointer: CGPoint(x: 104, y: 100)) == CGPoint(x: 54, y: 70))
        #expect(view.move(pointer: CGPoint(x: -100, y: 250)) == CGPoint(x: -150, y: 220))
        #expect(view.move(pointer: CGPoint(x: 100, y: 100)) == CGPoint(x: 50, y: 70))
        view.finish()
        view.finish()
        #expect(opens == 1 && drops == 1 && moving == [true, false], "drag completion never opens the app, even when it ends at its start")
        var actions: [String] = []
        view.onOpen = { actions.append("open") }
        view.onEndVoice = { actions.append("end") }
        view.onStopTask = { actions.append("stop") }
        view.onHide = { actions.append("hide") }
        view.installMenu()
        #expect(view.menu?.items.count == 4)
        view.openIvy(); view.endVoice(); view.stopTask(); view.hideIvy()
        #expect(actions == ["open", "end", "stop", "hide"])
    }

    @Test("drag animation visibly moves the sprite, keeps real activity poses, and is static with Reduce Motion")
    func companionMovingAnimation() {
        for mood in [CompanionMood.idle, .listening, .speaking, .working(0.5), .needsApproval, .error("Offline"), .hidden] {
            for time in [0.0, 0.14, 0.35, 0.7] {
                let still = CompanionAnimationSample.sample(mood: mood, elapsed: time, level: 0.5, reduceMotion: true, isMoving: true)
                #expect(still == CompanionAnimationSample(frame: CompanionPose(mood: mood).firstFrame, verticalOffset: 0, scale: 1))
                let sample = CompanionAnimationSample.sample(mood: mood, elapsed: time, level: 0.5, reduceMotion: false, isMoving: true)
                #expect(abs(sample.verticalOffset) <= 4 && abs(sample.rotationDegrees) <= 4)
                #expect((0..<16).contains(sample.frame))
                if mood == .needsApproval { #expect([10, 11].contains(sample.frame)) }
                if mood == .speaking { #expect(sample.frame == 7) }
            }
        }
        let moving = CompanionAnimationSample.sample(mood: .idle, elapsed: 0.14, level: 0, reduceMotion: false, isMoving: true)
        #expect(moving.verticalOffset < -3.9 && moving.rotationDegrees > 3.9 && moving.scale == 1.025)
        let quiet = CompanionAnimationSample.sample(mood: .speaking, elapsed: 0.14, level: 0, reduceMotion: false, isMoving: true)
        #expect(quiet.frame == 6, "moving must not invent speaking during silence")
    }

    @Test("all companion frames load and activity captions render in both appearances and motion settings")
    func companionLayouts() async throws {
        _ = NSApplication.shared
        #expect(CompanionSpriteSheet.frames.count == 16)
        for frame in CompanionSpriteSheet.frames {
            let cg = try #require(frame.cgImage(forProposedRect: nil, context: nil, hints: nil))
            #expect(cg.width >= 300 && cg.height >= 300)
            let bitmap = NSBitmapImageRep(cgImage: cg)
            #expect(bitmap.hasAlpha)
            #expect((bitmap.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.1, "frame edges stay transparent")
            #expect((bitmap.colorAt(x: cg.width / 2, y: cg.height / 2)?.alphaComponent ?? 0) > 0.5)
        }
        let named: [(String, CompanionMood)] = [("Hidden (paused)", .hidden), ("Idle", .idle), ("Listening", .listening),
                                                ("Thinking", .thinking), ("Speaking", .speaking), ("Working", .working(0.6)),
                                                ("Approval", .needsApproval), ("Error", .error("Connection unavailable. Try again."))]
        let fixtures = named.map { name, mood in
            let presentation = CompanionPresentation()
            presentation.mood = mood
            presentation.caption = "The event is ready. Check the date and time before I add it to your calendar."
            return CompanionFixture(id: name, presentation: presentation)
        }
        let movingPresentation = CompanionPresentation()
        movingPresentation.mood = .idle
        movingPresentation.isMoving = true
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-ui-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            for reduced in [false, true] {
                let movingCompanion = CompanionView(presentation: movingPresentation, meter: AudioLevelMeter(),
                                                    onOpen: {}, onEndVoice: {}, onStopTask: {}, onHide: {}, motionDisabled: reduced)
                try await snapshot(movingCompanion.background(IvyTheme.canvas), scheme: scheme,
                                   size: CompanionView.panelSize,
                                   url: directory.appendingPathComponent("companion-drag-\(scheme == .light ? "light" : "dark")-\(reduced).png"))
                let gallery = LazyVGrid(columns: [GridItem(.fixed(280)), GridItem(.fixed(280))], spacing: 12) {
                    ForEach(fixtures) { fixture in
                        VStack(spacing: 4) {
                            Text(fixture.id).font(.caption).foregroundStyle(.secondary)
                            CompanionView(presentation: fixture.presentation, meter: AudioLevelMeter(),
                                          onOpen: {}, onEndVoice: {}, onStopTask: {}, onHide: {}, motionDisabled: reduced)
                        }
                    }
                }
                .padding(20).background(IvyTheme.canvas)
                try await snapshot(gallery, scheme: scheme, size: NSSize(width: 620, height: 1080),
                                   url: directory.appendingPathComponent("companion-\(scheme == .light ? "light" : "dark")-\(reduced ? "static" : "animated").png"))
            }
        }
    }

    private func luminance(_ color: Color, appearance: NSAppearance) -> Double {
        var rgb: NSColor = .black
        appearance.performAsCurrentDrawingAppearance {
            rgb = NSColor(color).usingColorSpace(.sRGB) ?? .black
        }
        func linear(_ value: CGFloat) -> Double {
            let v = Double(value)
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }

    @Test("tool cards, diff drafts, screen-attach bar and pointer render as native controls")
    func releaseControls() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-ui-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let activity = ToolActivity()
        let running = activity.begin(FunctionCall(name: "file_op", args: ["action": "read", "path": "notes.txt"]))
        let succeeded = activity.begin(FunctionCall(name: "open_app", args: ["name": "Safari"]))
        activity.complete(succeeded, response: FunctionResponse(name: "open_app", response: ["success": true, "result": "Opened Safari"]))
        let failed = activity.begin(FunctionCall(name: "file_op", args: ["action": "write", "path": "notes.txt"]))
        activity.complete(failed, response: FunctionResponse(name: "file_op", response: ["success": false, "error": "Cancelled by you"]))
        #expect(activity.records.first?.id == running)
        let diff = "--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-old\n+new\n context"
        let cards = VStack(alignment: .leading, spacing: 16) {
            ForEach(activity.records) { ToolCardView(execution: $0, initiallyExpanded: true) }
            MessageBlocksView(text: "Proposed change:\n```diff\n" + diff + "\n```", onApplyDiff: { _ in })
        }.padding(24)
        let environment = IvyAppEnvironment(settingsStore: LayoutSettingsStore(),
            credentials: FixedCredentialProvider([.geminiAPIKey: "fixture"]),
            conversationStore: FileConversationStore(directory: directory.appendingPathComponent("release-history-" + UUID().uuidString)),
            geminiClient: LayoutOfflineClient(), visionPipeline: VisionPipeline(recognizer: LayoutCropRecognizer())) { _, _ in
            GeminiLiveVoiceCoordinator(session: MockGeminiLiveSession(), audioCapture: MockAudioCapture(), audioPlayer: MockLiveAudioPlayer())
        }
        let session = CommandBarSession(brain: environment.brain, tray: environment.attachments, tasks: environment.tasks, live: environment.liveCoordinator)
        let originalFrame = CGRect(x: 120, y: 400, width: 560, height: 220)
        let expandedFrame = CommandBarController.fittedFrame(originalFrame, contentHeight: 390.2, maximumHeight: 700)
        #expect(expandedFrame.height == 391 && expandedFrame.maxY == originalFrame.maxY)
        #expect(expandedFrame.minX == originalFrame.minX && expandedFrame.width == originalFrame.width)
        #expect(CommandBarController.fittedFrame(originalFrame, contentHeight: 900, maximumHeight: 500).height == 500)
        #expect(CommandBarController.fittedFrame(originalFrame, contentHeight: 40, maximumHeight: 500).height == 120)
        #expect(CommandBarController.fittedFrame(originalFrame, contentHeight: .nan, maximumHeight: 500) == originalFrame)
        let geometry = try #require(AnnotationGeometry(screen: CGRect(x: -800, y: 0, width: 800, height: 600),
                                                      target: CGRect(x: -600, y: 200, width: 180, height: 100)))
        let proposal = DiffDraftProposal(diff: diff)
        #expect(proposal.draft() != nil)
        proposal.path = ""
        #expect(proposal.draft() == nil)
        for scheme in [ColorScheme.light, .dark] {
            try await snapshot(cards, scheme: scheme, size: NSSize(width: 700, height: 920), url: directory.appendingPathComponent("release-tool-cards-\(scheme).png"))
            try await snapshot(DiffDraftSheet(proposal: proposal, onDraft: { _ in }, onCancel: {}),
                scheme: scheme, size: NSSize(width: 500, height: 320), url: directory.appendingPathComponent("release-diff-sheet-\(scheme).png"))
            try await snapshot(CommandBarView(brain: environment.brain, library: environment.library, tasks: environment.tasks,
                tray: environment.attachments, live: environment.liveCoordinator, session: session, onClose: {}, onContinueInWindow: {}),
                scheme: scheme, size: NSSize(width: 580, height: 320), url: directory.appendingPathComponent("release-command-bar-\(scheme).png"))
            try await snapshot(CommandBarView(brain: environment.brain, library: environment.library, tasks: environment.tasks,
                tray: environment.attachments, live: environment.liveCoordinator, session: session, onClose: {}, onContinueInWindow: {})
                .environment(\.ivyOpaqueSurfaces, true), scheme: scheme, size: NSSize(width: 580, height: 320),
                url: directory.appendingPathComponent("command-bar-opaque-\(scheme).png"))
            try await snapshot(AnnotationView(label: "Export menu", geometry: geometry).background(IvyTheme.canvas),
                scheme: scheme, size: NSSize(width: 800, height: 600), url: directory.appendingPathComponent("release-pointer-\(scheme).png"))
            try await snapshot(ChatFeedView(messages: [ChatMessage(role: .user, text: "Read notes"), ChatMessage(role: .model, text: "Done.")],
                activity: activity, voice: environment.voiceManager, onApplyDiff: nil),
                scheme: scheme, size: NSSize(width: 600, height: 560), url: directory.appendingPathComponent("release-tool-timeline-\(scheme).png"))
        }
        session.text = "Give me a short answer"
        let crop = try #require(ImageProcessing.rgbContext(width: 480, height: 180))
        crop.setFillColor(CGColor(gray: 0.15, alpha: 1)); crop.fill(CGRect(x: 0, y: 0, width: 480, height: 180))
        crop.setFillColor(CGColor(red: 0.4, green: 0.6, blue: 1, alpha: 1)); crop.fillEllipse(in: CGRect(x: 160, y: 40, width: 100, height: 100))
        let cropBytes = try ImageProcessing.jpeg(try #require(crop.makeImage()))
        let selectedArea = try #require(await environment.attachments.addImageData(cropBytes, name: "Selected area fixture"))
        #expect(environment.attachments.attachments.first?.id == selectedArea.id)
        try await snapshot(CommandBarView(brain: environment.brain, library: environment.library, tasks: environment.tasks,
            tray: environment.attachments, live: environment.liveCoordinator, session: session, onClose: {}, onContinueInWindow: {})
            .environment(\.ivyOpaqueSurfaces, true), scheme: .dark, size: NSSize(width: 580, height: 580),
            url: directory.appendingPathComponent("command-bar-attachment-dark.png"))
        #expect(await session.send())
        var measuredHeight: CGFloat = 0
        try await snapshot(CommandBarView(brain: environment.brain, library: environment.library, tasks: environment.tasks,
            tray: environment.attachments, live: environment.liveCoordinator, session: session, onClose: {}, onContinueInWindow: {},
            onContentHeight: { measuredHeight = $0 }).environment(\.ivyOpaqueSurfaces, true),
            scheme: .dark, size: NSSize(width: 580, height: 460),
            url: directory.appendingPathComponent("command-bar-reply-opaque-dark.png"))
        #expect(measuredHeight > 320 && measuredHeight < 460, "the actual reply layout grows beyond the old fixed panel")
        await environment.shutdown()
    }

    @Test("capture permission recovery wraps at compact widths; reduced-motion arrows are immediately complete")
    func screenGuidanceControls() async throws {
        struct DeniedCapture: ScreenContextCapturing {
            func frontmostOtherApp() async -> String? { "Editor" }
            func capture(_ target: CaptureTarget) async throws -> CapturedScreen { throw VisionError.screenPermissionDenied }
        }
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-ui-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tray = AttachmentTray(capturer: DeniedCapture())
        #expect(await tray.capture(.frontWindow) == nil)
        #expect(tray.needsScreenPermission && tray.canRetryCapture)
        let geometry = try #require(AnnotationGeometry(screen: CGRect(x: 0, y: 0, width: 800, height: 600),
                                                       target: CGRect(x: 180, y: 250, width: 120, height: 60)))
        var arrow = AnnotationArrow(geometry: geometry, progress: 0)
        #expect(arrow.animatableData == 0)
        arrow.animatableData = 1
        var endpoints: [CGPoint] = []
        arrow.path(in: CGRect(x: 0, y: 0, width: 800, height: 600)).forEach {
            if case .line(let point) = $0 { endpoints.append(point) }
        }
        #expect(endpoints.contains(geometry.end))
        for scheme in [ColorScheme.light, .dark] {
            for width in [CGFloat(320), 580] {
                try await snapshot(AttachmentBar(tray: tray).background(IvyTheme.canvas), scheme: scheme,
                                   size: NSSize(width: width, height: 150),
                                   url: directory.appendingPathComponent("capture-permission-\(Int(width))-\(scheme).png"))
            }
            try await snapshot(AnnotationView(label: "Export", geometry: geometry, forceReduceMotion: true).background(IvyTheme.canvas),
                               scheme: scheme, size: NSSize(width: 800, height: 600),
                               url: directory.appendingPathComponent("pointer-reduced-motion-\(scheme).png"))
        }
    }

    private func snapshot<V: View>(_ view: V, scheme: ColorScheme, size: NSSize, url: URL,
                                   increasedContrast: Bool = false, expectsWindowMaterial: Bool? = nil,
                                   expectsApproval: Bool = false, expectsCompanionApproval: Bool = false) async throws {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(scheme))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let appearance: NSAppearance.Name = increasedContrast
            ? (scheme == .light ? .accessibilityHighContrastAqua : .accessibilityHighContrastDarkAqua)
            : (scheme == .light ? .aqua : .darkAqua)
        window.appearance = NSAppearance(named: appearance)
        host.appearance = window.appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: 0))
        window.orderFront(nil)
        defer { window.close() }
        host.frame = NSRect(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        if expectsApproval {
            // macOS omits offscreen virtual AX nodes. Verify real sheet bounds and render its content instead.
            let sheet = try #require(window.sheets.first, "approval must be a native sheet")
            #expect(window.sheets.count == 1, "only one modal approval may be presented")
            #expect(window.frame.contains(sheet.frame), "the complete approval must fit even at minimum window size")
            let content = try #require(sheet.contentView)
            #expect(content.bounds.width >= 460 && content.bounds.height >= 300)
            #expect(content.bounds.width <= 480 && content.bounds.height <= 420,
                    "detailed app approvals must keep the decision controls inside the minimum window")
            content.layoutSubtreeIfNeeded()
            let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: url.deletingPathExtension().appendingPathExtension("sheet.png"))
        }
        if let expectsWindowMaterial {
            func materials(_ view: NSView) -> [NSVisualEffectView] {
                let own = (view as? NSVisualEffectView).map { [$0] } ?? []
                return own + view.subviews.flatMap(materials)
            }
            let backdrops = materials(host).filter { $0.material == .underWindowBackground && $0.blendingMode == .behindWindow }
            #expect(!backdrops.isEmpty == expectsWindowMaterial, "accessibility preferences must remove wallpaper blending")
            for backdrop in backdrops {
                #expect(backdrop.hitTest(.zero) == nil, "the backdrop must never intercept clicks")
            }
        }
        func verifyComposer(_ view: NSView) {
            // Navigation retains outgoing native views briefly; only visible editors participate in layout.
            if let editor = view as? ComposerTextView, !editor.visibleRect.isEmpty,
               let layout = editor.layoutManager,
               let container = editor.textContainer {
                layout.ensureLayout(for: container)
                #expect(editor.bounds.width > 100, "\(url.lastPathComponent): document must retain the viewport width")
                #expect(editor.bounds.height >= 32)
                #expect(layout.usedRect(for: container).maxY + 12 <= editor.bounds.height + 1,
                        "the native document must contain its text without clipping")
                if let scroll = editor.enclosingScrollView, editor.bounds.height <= scroll.contentSize.height + 1 {
                    let glyphHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
                    #expect(abs(editor.textContainerOrigin.y + glyphHeight / 2 - editor.bounds.midY) < 1,
                            "short drafts and empty insertion points must be vertically centered")
                }
                #expect(editor.isEditable && editor.isSelectable)
            }
            for child in view.subviews { verifyComposer(child) }
        }
        verifyComposer(host)
        // Normal status pills drag with the character. The user-requested approval bubble replaces
        // that pill with interactive controls, so only the 96-point character may drag during approval.
        func verifyDragSurfaces(_ view: NSView) {
            if let surface = view as? CompanionDragSurface {
                if !surface.isInteractive {
                    #expect(surface.hitTest(.zero) == nil, "layout measurement must not intercept approval buttons")
                    return
                }
                #expect(surface.bounds.width >= 96)
                if expectsCompanionApproval {
                    #expect(surface.bounds.height >= 96 && surface.bounds.height <= 100,
                            "approval buttons must remain outside the character's drag surface")
                } else {
                    #expect(surface.bounds.height >= 120)
                }
                let center = CGPoint(x: surface.bounds.midX, y: surface.bounds.midY)
                // AppKit hitTest expects the point in the receiver's superview coordinates.
                let point = surface.convert(center, to: host.superview)
                #expect(host.hitTest(point) === surface, "the drag surface must receive pointer events")
                let visible = surface.convert(surface.bounds, to: nil)
                let screen = CGRect(x: 0, y: 25, width: 1440, height: 900)
                let placement = CompanionPlacement(origin: CGPoint(x: -5000, y: -5000), panelSize: size,
                                                    visibleFrame: screen, displayID: 0, contentFrame: visible)
                let edge = placement.origin(panelSize: size, visibleFrame: screen, contentFrame: visible)
                #expect(abs(edge.x + visible.minX - screen.minX) < 0.001)
                #expect(abs(edge.y + visible.minY - screen.minY) < 0.001)
            }
            for child in view.subviews { verifyDragSurfaces(child) }
        }
        verifyDragSurfaces(host)
        window.displayIfNeeded()
        CATransaction.flush()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide >= Int(size.width))
        #expect(bitmap.pixelsHigh >= Int(size.height))
        #expect(png.count > 5_000, "a rendered screen must contain real interface content")
        try png.write(to: url)
    }
}

private struct CompanionFixture: Identifiable {
    let id: String
    let presentation: CompanionPresentation
}

private struct ControlFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Fixture preferences are isolated from the user's settings and never start hotkeys or recording.
private struct LayoutCropRecognizer: TextRecognizing {
    func recognize(_ image: Data) async throws -> [RecognizedText] { [] }
}

private final class LayoutSettingsStore: SettingsStore, @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: LayoutSettingsStore.defaults)
    private static var defaults: IvySettings {
        var settings = IvySettings.defaults
        settings.restoreLastConversation = false
        settings.pushToTalkEnabled = false
        settings.screenHelpHotkeyEnabled = false
        settings.commandBarHotkeyEnabled = false
        settings.onboardingCompleted = true
        return settings
    }
    func load() -> IvySettings { value.withLock { $0 } }
    func save(_ settings: IvySettings) throws { value.withLock { $0 = settings } }
}

/// An offline model fixture proposes one risky action. The test always denies it; no shell tool runs.
private final class LayoutApprovalClient: GeminiClientProtocol, @unchecked Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String {
        "Fixture reply."
    }
    func generateContent(history: [ChatMessage], systemPrompt: String,
                         tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
        let first = calls.withLock { count in
            defer { count += 1 }
            return count == 0
        }
        return first
            ? ModelTurnResponse(functionCalls: [FunctionCall(name: "run_shell", args: ["command": .string("echo fixture")])])
            : ModelTurnResponse(text: "The action was cancelled.")
    }
}

/// Every layout, including a proactive briefing, stays offline.
private struct LayoutOfflineClient: GeminiClientProtocol {
    func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String {
        "Fixture briefing."
    }
    func generateContent(history: [ChatMessage], systemPrompt: String,
                         tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
        ModelTurnResponse(text: "Fixture briefing.")
    }
}

/// This fixture only proposes a plan. Layout tests never approve or execute its command.
private struct LayoutTaskPlanner: TaskPlanning {
    func plan(goal: String, context: String, tools: [FunctionDeclaration]) async throws -> String {
        #"{"steps":[{"id":"1","title":"Review folder metadata","tool":"run_shell","arguments":{"command":"echo fixture"}}]}"#
    }
}

/// Native flow previews propose three harmless commands; tests never approve this plan.
private struct LayoutFlowPlanner: TaskPlanning {
    func plan(goal: String, context: String, tools: [FunctionDeclaration]) async throws -> String {
        #"{"steps":[{"id":"1","title":"Review project files","tool":"run_shell","arguments":{"command":"echo fixture"}},{"id":"2","title":"Summarize the findings","tool":"run_shell","arguments":{"command":"echo fixture"},"dependsOn":["1"]},{"id":"3","title":"Prepare next steps","tool":"run_shell","arguments":{"command":"echo fixture"},"dependsOn":["2"]}]}"#
    }
}
