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
        #expect(!IvyAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    @Test("chat, settings and composers render at compact and expanded sizes in both appearances")
    func layouts() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-ui-review")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = FileConversationStore(directory: directory.appendingPathComponent("history-" + UUID().uuidString))
        let now = Date(timeIntervalSince1970: 1_790_920_800)
        let conversation = Conversation(id: UUID(), createdAt: now, chatMessages: [
            ChatMessage(role: .user, text: "Why is this Swift task racing?", timestamp: now),
            ChatMessage(role: .model, text: "The response arrives after the view changes. Keep the state on the main actor and cancel work when its owner disappears.\n\n```swift\n.task {\n    await model.load()\n}\n```\n\nStart with the smallest fix, then run the tests.", timestamp: now.addingTimeInterval(5))
        ])
        try store.save(conversation)
        let credentials = FixedCredentialProvider([.geminiAPIKey: "fixture-not-a-real-key"])
        let environment = IvyAppEnvironment(
            settingsStore: LayoutSettingsStore(), credentials: credentials, conversationStore: store
        ) { credentials, _ in GeminiLiveVoiceCoordinator(credentials: credentials) }
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
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .light ? "light" : "dark"
            for width in [CGFloat(560), 1080] {
                let view = IvyWindowRoot(environment: environment)
                try await snapshot(view, scheme: scheme, size: NSSize(width: width, height: 760),
                                   url: directory.appendingPathComponent("chat-\(name)-\(Int(width)).png"))
            }
            for pane in SettingsPane.allCases {
                environment.settings.settings.proactiveEnabled = pane == .proactive
                environment.settings.settings.proactiveCalendar = pane == .proactive
                environment.settings.settings.proactiveBriefing = pane == .proactive
                let settings = SettingsWindowView(environment: environment, settings: environment.settings,
                                                  wakeWord: environment.wakeWord, initialPane: pane)
                try await snapshot(settings, scheme: scheme, size: NSSize(width: 800, height: 600),
                                   url: directory.appendingPathComponent("settings-\(pane.id)-\(name).png"))
            }
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
        let approvalBrain = IvyBrain(client: LayoutApprovalClient(), apiKey: "fixture-not-a-real-key")
        let approvalTurn = Task { await approvalBrain.send("Propose a fixture shell action") }
        for _ in 0..<100 where approvalBrain.pendingConfirmation == nil { await Task.yield() }
        let request = try #require(approvalBrain.pendingConfirmation)
        let approvalView = ChatPaneView(brain: approvalBrain, voiceManager: environment.voiceManager,
                                       liveVoiceCoordinator: environment.liveCoordinator, proactive: environment.proactive,
                                       attachments: environment.attachments, tasks: environment.tasks)
        try await snapshot(approvalView, scheme: .light, size: NSSize(width: 680, height: 760),
                           url: directory.appendingPathComponent("pending-approval.png"))
        #expect(approvalBrain.pendingConfirmation?.id == request.id, "rendering must never approve an action")
        approvalBrain.respondToPendingConfirmation(id: request.id, approved: false)
        await approvalTurn.value
        #expect(approvalBrain.pendingConfirmation == nil)
        await environment.shutdown()
    }

    private func snapshot<V: View>(_ view: V, scheme: ColorScheme, size: NSSize, url: URL) async throws {
        let host = NSHostingView(rootView: view.preferredColorScheme(scheme))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: 0))
        window.orderFront(nil)
        defer { window.close() }
        host.frame = NSRect(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
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

/// Fixture preferences are isolated from the user's settings and never start hotkeys or recording.
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
