import Foundation
import Combine

/// The floating bar uses the same memory-only tray and chat safety checks as the main composer.
@MainActor
public final class CommandBarSession: ObservableObject {
    @Published public var text = ""
    @Published public private(set) var askedID: UUID?
    private let brain: IvyBrain
    private let tray: AttachmentTray
    private let tasks: TaskEngine
    private let live: GeminiLiveVoiceCoordinator

    public init(brain: IvyBrain, tray: AttachmentTray, tasks: TaskEngine, live: GeminiLiveVoiceCoordinator) {
        self.brain = brain; self.tray = tray; self.tasks = tasks; self.live = live
    }

    public var blocked: String? {
        if brain.pendingConfirmation != nil || live.pendingConfirmation != nil { return "Ivy is waiting for your approval in its window." }
        if live.state.isLive { return "End voice before sending a typed request." }
        if tasks.run?.isActive == true { return "A task is running. Watch it in Ivy's window." }
        if tray.isWorking { return "Preparing your attachment…" }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("/agent "), !tray.attachments.isEmpty {
            return "Send the screen in a chat first, then plan a task."
        }
        return nil
    }

    public func captureFrontWindow() async {
        guard !brain.isThinking, blocked == nil else { return }
        await tray.capture(.frontWindow)
    }

    @discardableResult
    public func send() async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !tray.attachments.isEmpty, !brain.isThinking, blocked == nil else { return false }
        text = ""
        if trimmed.lowercased().hasPrefix("/agent ") {
            await tasks.start(goal: String(trimmed.dropFirst("/agent ".count)))
        } else {
            let attachments = tray.take()
            await brain.send(trimmed, attachments: attachments)
            askedID = brain.messages.last { $0.role == .user }?.id
        }
        return true
    }
}
