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
        #expect(NSApplication.shared.activationPolicy() == .regular)
        #expect(MainWindowController.shared != nil)
        var opened = 0
        MainWindowController.shared?.openWindow = { opened += 1 }
        #expect(IvyAppDelegate().applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false))
        #expect(opened == 1)
        MainWindowController.shared?.show()
        #expect(opened == 2)
        environment.proactive.pendingPrompt = "Fixture suggestion"
        try await Task.sleep(for: .milliseconds(30))
        #expect(opened == 3)
        environment.proactive.pendingPrompt = nil
        let delegate = IvyAppDelegate()
        let savedLink = try #require(URL(string: "ivy://conversation/\(conversation.id)"))
        delegate.application(NSApplication.shared, open: [try #require(URL(string: "ivy://run_shell/rm")), savedLink])
        #expect(opened == 4 && environment.router.selectedConversationID == conversation.id)
        delegate.application(NSApplication.shared, open: [try #require(URL(string: "ivy://new")), savedLink])
        #expect(opened == 5 && environment.brain.messages.isEmpty)
        #expect(environment.brain.conversationID != conversation.id, "only the first recognized URL in a batch is handled")
        delegate.application(NSApplication.shared, open: [try #require(URL(string: "ivy://new?prompt=run"))])
        #expect(opened == 5, "unexpected parameters cannot act or navigate")
        delegate.application(NSApplication.shared, open: [try #require(URL(string: "ivy://conversation/\(UUID())"))])
        #expect(opened == 6 && environment.router.navigationError != nil)
        try await snapshot(IvyWindowRoot(environment: environment), scheme: .dark,
            size: NSSize(width: 1080, height: 760), url: directory.appendingPathComponent("missing-conversation-link.png"))
        MainWindowController.shared?.openWindow = { opened += 1 }
        delegate.application(NSApplication.shared, open: [savedLink])
        #expect(opened == 7 && environment.brain.conversationID == conversation.id)
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
                let view = IvyWindowRoot(environment: environment)
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
            try await snapshot(TasksWorkspaceView(tasks: environment.tasks, selectedTaskID: savedTask.id, blocked: false, onPrompt: { _ in }),
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
                               size: NSSize(width: 600, height: 1120), url: directory.appendingPathComponent("voice-full-\(name).png"))
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
        try await snapshot(IvyWindowRoot(environment: environment), scheme: .dark,
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
            try await snapshot(TasksWorkspaceView(tasks: environment.tasks, blocked: true, onPrompt: { _ in }),
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
                size: NSSize(width: 280, height: 100),
                url: directory.appendingPathComponent("approval-long-\(scheme == .light ? "light" : "dark").png"))
            // Replace obsolete Details fixtures with reason-only approvals, as explicitly requested.
            // Keep long/empty payload coverage and all identity/cancellation assertions.
            try await snapshot(ConfirmationCardView(request: longRequest, compact: true, onConfirm: { _ in }),
                scheme: scheme, size: NSSize(width: 240, height: 96),
                url: directory.appendingPathComponent("approval-reason-long-\(scheme).png"))
            try await snapshot(ConfirmationSheetView(request: ConfirmationRequest(
                toolName: "open_app", title: "Open Calculator", prompt: "Open Calculator?", detail: ""),
                onConfirm: { _ in }), scheme: scheme, size: NSSize(width: 280, height: 100),
                url: directory.appendingPathComponent("approval-reason-empty-\(scheme).png"))
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
                #expect(visibleBounds.width >= 240 && visibleBounds.height >= 190,
                        "placement must include the review card, not only the character")
                #expect(visibleBounds.width <= 240 && visibleBounds.height <= 224,
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
            presentation.caption = "The change is ready. Review it before applying."
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
            #expect(content.bounds.width >= 280 && content.bounds.height >= 100)
            #expect(content.bounds.width <= 300 && content.bounds.height <= 120,
                    "confirmation must stay compact even when the action preview is long")
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
