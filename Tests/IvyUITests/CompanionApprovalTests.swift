import AppKit
import SwiftUI
import Testing
import os
@testable import Ivy
@testable import IvyCore

@MainActor
@Suite("Companion approval routing", .serialized)
struct CompanionApprovalTests {
    private func request(_ title: String) -> ConfirmationRequest {
        ConfirmationRequest(toolName: "run_shell", title: title, prompt: "Review this fixture.", detail: "Fixture only; no tool executes.")
    }

    private func coordinator() -> GeminiLiveVoiceCoordinator {
        GeminiLiveVoiceCoordinator(session: MockGeminiLiveSession(), audioCapture: MockAudioCapture(),
                                  audioPlayer: MockLiveAudioPlayer(), wakeWordDetector: MockWakeWordDetector())
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(predicate())
    }

    @Test("only the exact chat request can be answered, even after replacement or repeated clicks")
    func chatResponses() async throws {
        let brain = IvyBrain(client: ApprovalOfflineClient(), credentials: FixedCredentialProvider([:]))
        let live = coordinator()
        #expect(CompanionApproval.pending(chat: nil, live: nil) == nil)
        let first = request("First")
        let firstWait = Task { await brain.handleConfirmation(first) }
        try await waitFor { brain.pendingConfirmation?.id == first.id }
        let firstCard = try #require(CompanionApproval.pending(chat: brain.pendingConfirmation, live: nil))
        #expect(!firstCard.isLive && firstCard.id == first.id)
        let second = request("Second")
        let secondWait = Task { await brain.handleConfirmation(second) }
        try await waitFor { brain.pendingConfirmation?.id == second.id }
        #expect(await firstWait.value == false, "replacement cancels the old continuation")
        firstCard.respond(approved: true, brain: brain, liveCoordinator: live)
        #expect(brain.pendingConfirmation?.id == second.id, "an old companion cannot approve the new request")
        let secondCard = try #require(CompanionApproval.pending(chat: brain.pendingConfirmation, live: nil))
        secondCard.respond(approved: false, brain: brain, liveCoordinator: live)
        #expect(await secondWait.value == false)
        #expect(brain.pendingConfirmation == nil)
        secondCard.respond(approved: true, brain: brain, liveCoordinator: live)
        let third = request("Third")
        let thirdWait = Task { await brain.handleConfirmation(third) }
        try await waitFor { brain.pendingConfirmation?.id == third.id }
        secondCard.respond(approved: true, brain: brain, liveCoordinator: live)
        #expect(brain.pendingConfirmation?.id == third.id)
        let thirdCard = try #require(CompanionApproval.pending(chat: brain.pendingConfirmation, live: nil))
        thirdCard.respond(approved: true, brain: brain, liveCoordinator: live)
        #expect(await thirdWait.value == true)
        thirdCard.respond(approved: false, brain: brain, liveCoordinator: live)
        #expect(brain.pendingConfirmation == nil)
    }

    @Test("Live approval wins selection but never answers a pending chat request")
    func liveResponses() async throws {
        let brain = IvyBrain(client: ApprovalOfflineClient(), credentials: FixedCredentialProvider([:]))
        let live = coordinator()
        await live.startSession()
        let chatRequest = request("Chat")
        let chatWait = Task { await brain.handleConfirmation(chatRequest) }
        try await waitFor { brain.pendingConfirmation != nil }
        for approved in [false, true] {
            let liveRequest = request("Live")
            let liveWait = Task { await live.handleConfirmation(liveRequest) }
            try await waitFor { live.pendingConfirmation?.id == liveRequest.id }
            let card = try #require(CompanionApproval.pending(chat: brain.pendingConfirmation, live: live.pendingConfirmation))
            #expect(card.id == liveRequest.id && card.isLive)
            CompanionApproval(request: chatRequest, isLive: true).respond(approved: true, brain: brain, liveCoordinator: live)
            #expect(live.pendingConfirmation?.id == liveRequest.id)
            card.respond(approved: approved, brain: brain, liveCoordinator: live)
            #expect(await liveWait.value == approved)
            card.respond(approved: !approved, brain: brain, liveCoordinator: live)
            #expect(brain.pendingConfirmation?.id == chatRequest.id && live.pendingConfirmation == nil)
        }
        CompanionApproval(request: chatRequest, isLive: false).respond(approved: false, brain: brain, liveCoordinator: live)
        #expect(await chatWait.value == false)
        await live.stopSession()
    }

    @Test("the native controller grows, hides and shrinks the same review panel without authorizing on display")
    func panelLifecycle() async throws {
        _ = NSApplication.shared
        let directory = URL(fileURLWithPath: "/private/tmp/ivy-approval-tests-" + UUID().uuidString)
        let environment = IvyAppEnvironment(settingsStore: ApprovalSettingsStore(), credentials: FixedCredentialProvider([:]),
            conversationStore: FileConversationStore(directory: directory), geminiClient: ApprovalOfflineClient()) { _, _ in
                coordinator()
            }
        defer {
            if FileManager.default.fileExists(atPath: directory.path) {
                do { try FileManager.default.removeItem(at: directory) }
                catch { Issue.record("Could not remove approval fixture: \(error)") }
            }
        }
        let panel = ApprovalTestPanel(contentRect: CGRect(origin: .zero, size: CompanionView.panelSize),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let controller = CompanionController(environment: environment, panelFactory: { panel })
        let first = request("First panel request")
        let firstWait = Task { await environment.brain.handleConfirmation(first) }
        try await waitFor { panel.canBecomeKey && panel.frame.size == CompanionView.panelSize(hasApproval: true) }
        let host = try #require(panel.contentView as? NSHostingView<CompanionView>)
        #expect(host.rootView.presentation.approval?.id == first.id && panel.isVisible)
        #expect(panel.worksWhenModal && !panel.canBecomeMain)
        let stale = try #require(host.rootView.presentation.approval)
        host.rootView.onHide()
        #expect(!panel.isVisible && environment.brain.pendingConfirmation?.id == first.id)
        let second = request("Fresh panel request")
        let secondWait = Task { await environment.brain.handleConfirmation(second) }
        try await waitFor { host.rootView.presentation.approval?.id == second.id && panel.isVisible }
        #expect(await firstWait.value == false)
        host.rootView.onConfirm(stale, true)
        #expect(environment.brain.pendingConfirmation?.id == second.id)
        let current = try #require(host.rootView.presentation.approval)
        host.rootView.onConfirm(current, false)
        #expect(await secondWait.value == false)
        try await waitFor { !panel.isVisible && host.rootView.presentation.approval == nil }
        // An idle companion returns to its original frame after review.
        environment.settings.settings.companionShowWhileIdle = true
        try await waitFor { panel.frame.size == CompanionView.panelSize && panel.isVisible }
        #expect(!panel.canBecomeKey)
        environment.settings.settings.companionEnabled = false
        try await waitFor { !panel.isVisible }
        withExtendedLifetime(controller) {}
        await environment.shutdown()
    }
}

/// This window records presentation without appearing on the user's desktop.
@MainActor
private final class ApprovalTestPanel: CompanionPanel {
    private var shown = false
    override var isVisible: Bool { shown }
    override func orderFrontRegardless() { shown = true }
    override func orderOut(_ sender: Any?) { shown = false }
}

private struct ApprovalOfflineClient: GeminiClientProtocol {
    func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "Offline fixture." }
}

private final class ApprovalSettingsStore: SettingsStore, @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: defaults)
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
