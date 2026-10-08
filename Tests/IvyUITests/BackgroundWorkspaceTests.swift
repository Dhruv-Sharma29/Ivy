import AppKit
import SwiftUI
import Testing
import os
@testable import Ivy
@testable import IvyCore

@MainActor
@Suite("Background workspace lifecycle", .serialized)
struct BackgroundWorkspaceTests {
    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(predicate())
    }

    private func environment(directory: URL, session: MockGeminiLiveSession = MockGeminiLiveSession(),
                             capture: MockAudioCapture = MockAudioCapture(),
                             player: MockLiveAudioPlayer = MockLiveAudioPlayer(autoDrain: false)) -> IvyAppEnvironment {
        IvyAppEnvironment(settingsStore: BackgroundSettingsStore(), credentials: FixedCredentialProvider([:]),
            conversationStore: FileConversationStore(directory: directory.appendingPathComponent("history")),
            geminiClient: BackgroundOfflineClient(), taskPlanner: BackgroundReadPlanner(path: directory.appendingPathComponent("fixture.txt").path)) { _, _ in
                GeminiLiveVoiceCoordinator(session: session, audioCapture: capture, audioPlayer: player,
                    wakeWordDetector: MockWakeWordDetector())
            }
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: -10000, y: 0, width: 300, height: 200),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private func remove(_ directory: URL) {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Could not remove background fixture: \(error)") }
    }

    @Test("Companion launch hides an automatic workspace, retains suggestions and opens only on request")
    func companionLaunch() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-companion-launch-" + UUID().uuidString)
        defer { remove(directory) }
        let e = environment(directory: directory)
        let panel = BackgroundTestPanel(contentRect: CGRect(origin: .zero, size: CompanionView.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let companion = CompanionController(environment: e, panelFactory: { panel })
        let controller = MainWindowController(proactive: e.proactive, startsInBackground: true) {
            companion.showForBackground()
        }
        let workspace = window()
        defer { workspace.close(); panel.close() }
        workspace.orderFront(nil)
        controller.register(window: workspace)
        controller.workInBackground()
        #expect(controller.isWorkingInBackground && !workspace.isVisible && panel.isVisible)
        var opens = 0
        controller.openWindow = { opens += 1; workspace.orderFront(nil) }
        e.proactive.pendingPrompt = "Keep this suggestion for later"
        try await Task.sleep(for: .milliseconds(25))
        #expect(opens == 0 && !workspace.isVisible && e.proactive.pendingPrompt != nil)
        controller.show()
        #expect(opens == 1 && workspace.isVisible && !controller.isWorkingInBackground)
        controller.workInBackground()
        #expect(opens == 1 && !workspace.isVisible && panel.isVisible)
        await e.shutdown()
    }

    @Test("The menu-bar label installs an open route before a workspace has been created")
    func menuBarRoute() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-companion-route-" + UUID().uuidString)
        defer { remove(directory) }
        let e = environment(directory: directory)
        let controller = MainWindowController(proactive: e.proactive, startsInBackground: true) {}
        let host = NSHostingView(rootView: IvyMenuBarLabel(windowController: controller))
        let labelWindow = window()
        defer { labelWindow.close() }
        labelWindow.contentView = host
        labelWindow.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await waitFor { controller.openWindow != nil }
        #expect(controller.isWorkingInBackground, "installing the menu route must not open the workspace")
        await e.shutdown()
    }

    @Test("Hiding or closing the workspace preserves a held voice request and its reply", arguments: [false, true])
    func voiceContinues(close: Bool) async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-background-" + UUID().uuidString)
        defer { remove(directory) }
        let session = MockGeminiLiveSession(), capture = MockAudioCapture()
        let player = MockLiveAudioPlayer(autoDrain: false)
        let e = environment(directory: directory, session: session, capture: capture, player: player)
        let panel = BackgroundTestPanel(contentRect: CGRect(origin: .zero, size: CompanionView.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let companion = CompanionController(environment: e, panelFactory: { panel })
        let controller = MainWindowController(proactive: e.proactive) { companion.showForBackground() }
        let workspace = window(), settingsWindow = window()
        defer { workspace.close(); settingsWindow.close(); panel.close() }
        var opens = 0
        controller.openWindow = { opens += 1; workspace.orderFront(nil) }
        workspace.contentView = NSHostingView(rootView: WorkspaceWindowReader { controller.register(window: $0) })
        workspace.contentView?.layoutSubtreeIfNeeded()
        controller.register(window: workspace)
        controller.register(window: workspace) // duplicate attachment retains the one close observer
        controller.show()
        settingsWindow.orderFront(nil)
        await e.liveCoordinator.beginPushToTalk()
        let speech = Data((0..<640).map { $0.isMultiple(of: 2) ? UInt8(0) : UInt8(64) })
        capture.simulateAudioChunk(speech)
        try await waitFor { session.sentAudioChunks == [speech] }
        if close { workspace.close() } else { controller.workInBackground() }
        try await waitFor { controller.isWorkingInBackground && panel.isVisible }
        #expect(!workspace.isVisible && settingsWindow.isVisible)
        #expect(e.liveCoordinator.isPushToTalkActive && capture.isCapturing && session.isConnected)
        #expect(e.settings.settings.companionEnabled && e.settings.settings.companionShowWhileIdle)
        let host = try #require(panel.contentView as? NSHostingView<CompanionView>)
        try await waitFor { host.rootView.presentation.mood == .listening }
        e.proactive.pendingPrompt = "A suggestion to review later"
        try await Task.sleep(for: .milliseconds(25))
        #expect(opens == 1 && !workspace.isVisible, "a suggestion must not reopen a background workspace")
        #expect(e.proactive.pendingPrompt != nil)
        await e.liveCoordinator.endPushToTalk()
        #expect(!capture.isCapturing && e.liveCoordinator.state == .thinking)
        #expect(session.audioInputEndCount == 1)
        session.simulateEvent(.audioChunk(Data([1, 2])))
        try await waitFor { host.rootView.presentation.mood == .speaking && player.isPlaying }
        #expect(!workspace.isVisible)
        session.simulateEvent(.turnComplete)
        player.finishPlayback()
        try await waitFor { e.liveCoordinator.state == .idle && host.rootView.presentation.mood == .idle }
        #expect(panel.isVisible && !capture.isCapturing && !session.isConnected)
        controller.show()
        #expect(!controller.isWorkingInBackground && workspace.isVisible && opens == 2)
        e.proactive.pendingPrompt = "A new visible-workspace suggestion"
        try await waitFor { opens == 3 }
        await e.shutdown()
    }

    @Test("An approved task completes and saves results while the workspace is hidden", arguments: [false, true])
    func taskContinues(close: Bool) async throws {
        // File tools stay inside the permitted home scope; do not loosen validation for a fixture.
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/ivy-background-task-" + UUID().uuidString)
        defer { remove(directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "Background fixture only".write(to: directory.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
        let e = environment(directory: directory)
        let workspace = window()
        defer { workspace.close() }
        let controller = MainWindowController(proactive: e.proactive) {}
        controller.register(window: workspace)
        controller.openWindow = { workspace.orderFront(nil) }
        controller.show()
        await e.tasks.start(goal: "Read the fixture twice")
        #expect(e.tasks.run?.phase == .awaitingApproval)
        e.tasks.approvePlan() // explicit plan review, independent of background/close actions
        if close { workspace.close() } else { controller.workInBackground() }
        try await waitFor { e.tasks.run?.phase == .finished(.succeeded) && controller.isWorkingInBackground }
        #expect(!workspace.isVisible)
        #expect(e.tasks.run?.plan.steps.allSatisfy { $0.status == .succeeded } == true)
        #expect(e.tasks.history.count == 1 && e.tasks.history.first?.report?.isEmpty == false)
        #expect(e.tasks.history.first?.phase == .finished(.succeeded))
        #expect(e.tasks.history.first?.plan.steps.allSatisfy { $0.output?.contains("Background fixture only") == true } == true)
        #expect(e.brain.toolDispatcher.activity.records.count == 2)
        await e.shutdown()
    }

    @Test("Background mode reveals a hidden companion approval and never answers it on its own")
    func approvalRemainsExplicit() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-background-approval-" + UUID().uuidString)
        defer { remove(directory) }
        let e = environment(directory: directory)
        let panel = BackgroundTestPanel(contentRect: CGRect(origin: .zero, size: CompanionView.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let companion = CompanionController(environment: e, panelFactory: { panel })
        let controller = MainWindowController(proactive: e.proactive) { companion.showForBackground() }
        controller.workInBackground() // also valid if the workspace was already closed
        let request = ConfirmationRequest(toolName: "run_shell", title: "Fixture approval", prompt: "Fixture only", detail: "No executable command")
        let pending = Task { await e.brain.handleConfirmation(request) }
        try await waitFor { e.brain.pendingConfirmation?.id == request.id && panel.allowsKeyboard }
        let pane = ChatPaneView(brain: e.brain, voiceManager: e.voiceManager, liveVoiceCoordinator: e.liveCoordinator,
            proactive: e.proactive, attachments: e.attachments, tasks: e.tasks, windowController: controller)
        #expect(pane.presentedSheet == nil)
        controller.show()
        let priorBinding = pane.sheetPresentation
        #expect(pane.presentedSheet?.id == "chat-\(request.id)")
        controller.workInBackground()
        priorBinding.wrappedValue = nil // dismissal of the old sheet must leave the same approval pending
        #expect(e.brain.pendingConfirmation?.id == request.id && pane.presentedSheet == nil)
        let host = try #require(panel.contentView as? NSHostingView<CompanionView>)
        let card = try #require(host.rootView.presentation.approval)
        host.rootView.onHide()
        #expect(!panel.isVisible && e.brain.pendingConfirmation?.id == request.id)
        controller.workInBackground()
        #expect(panel.isVisible && e.brain.pendingConfirmation?.id == request.id)
        host.rootView.onConfirm(card, false)
        #expect(await pending.value == false)
        try await waitFor { host.rootView.presentation.approval == nil && panel.isVisible }
        await e.shutdown()
    }

    @Test("The workspace reader is noninteractive and unrelated window closes do not change background state")
    func windowIdentity() async throws {
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-background-identity-" + UUID().uuidString)
        defer { remove(directory) }
        let e = environment(directory: directory)
        var transitions = 0
        let controller = MainWindowController(proactive: e.proactive) { transitions += 1 }
        let workspace = window(), other = window()
        defer { workspace.close(); other.close() }
        let surface = WorkspaceWindowSurface()
        surface.onWindow = { controller.register(window: $0) }
        workspace.contentView = surface
        #expect(surface.hitTest(.zero) == nil)
        other.close()
        try await Task.sleep(for: .milliseconds(10))
        #expect(!controller.isWorkingInBackground && transitions == 0)
        workspace.close()
        try await waitFor { transitions == 1 && controller.isWorkingInBackground }
        await e.shutdown()
    }
}

@MainActor
private final class BackgroundTestPanel: CompanionPanel {
    private var shown = false
    override var isVisible: Bool { shown }
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
}

private struct BackgroundOfflineClient: GeminiClientProtocol {
    func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "Offline fixture" }
}

private struct BackgroundReadPlanner: TaskPlanning {
    let path: String
    func plan(goal: String, context: String, tools: [FunctionDeclaration]) async throws -> String {
        let steps: [[String: Any]] = (1...2).map { index in
            ["id": String(index), "title": "Read fixture \(index)", "tool": "file_op",
             "arguments": ["action": "read", "path": path], "dependsOn": index == 1 ? [] : ["1"],
             "verify": ["outputContains": "Background fixture only"]]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["steps": steps]), as: UTF8.self)
    }
}

private final class BackgroundSettingsStore: SettingsStore, @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: defaults)
    private static var defaults: IvySettings {
        var settings = IvySettings.defaults
        settings.restoreLastConversation = false
        settings.pushToTalkEnabled = false
        settings.screenHelpHotkeyEnabled = false
        settings.commandBarHotkeyEnabled = false
        settings.onboardingCompleted = true
        settings.companionEnabled = false
        settings.companionShowWhileIdle = false
        return settings
    }
    func load() -> IvySettings { value.withLock { $0 } }
    func save(_ settings: IvySettings) throws { value.withLock { $0 = settings } }
}
