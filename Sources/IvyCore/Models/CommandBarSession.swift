import Foundation
import Combine

/// The floating bar uses the same memory-only tray and chat safety checks as the main composer.
@MainActor
public final class CommandBarSession: ObservableObject {
    @Published public var text = ""
    @Published public private(set) var askedID: UUID?
    @Published public var screenQuestionID: UUID?
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
        if tasks.isDesktopControlActive { return "A desktop control session is active. Watch or stop it in Ivy's window." }
        if tasks.run?.isActive == true { return "A task is running. Watch it in Ivy's window." }
        if tray.isWorking { return "Preparing your attachment…" }
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.hasPrefix("/agent "), !tray.attachments.isEmpty {
            return "Send the screen in a chat first, then plan a task."
        }
        if lower.hasPrefix("/desktop "), !tray.attachments.isEmpty {
            return "Desktop control operates directly on the target window."
        }
        return nil
    }

    public func captureFrontWindow() async {
        guard !brain.isThinking, blocked == nil else { return }
        await tray.capture(.frontWindow)
    }

    /// Keeps an existing draft intact; the crop is reviewed before an explicit send.
    public func prepareScreenQuestion(_ attachment: ImageAttachment) {
        screenQuestionID = attachment.id
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = "What is this, and how does it work?"
        }
    }

    @discardableResult
    public func send() async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !tray.attachments.isEmpty, !brain.isThinking, blocked == nil else { return false }
        text = ""
        screenQuestionID = nil
        if trimmed.lowercased().hasPrefix("/agent ") {
            await tasks.start(goal: String(trimmed.dropFirst("/agent ".count)))
        } else if trimmed.lowercased().hasPrefix("/desktop ") {
            let commandText = String(trimmed.dropFirst("/desktop ".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            let (bundleID, goal) = Self.parseDesktopCommand(commandText)
            let targetApp: String
            if let bundleID {
                targetApp = bundleID
            } else if let front = await tray.capturer.frontmostOtherApp() {
                targetApp = front
            } else {
                targetApp = "com.apple.finder"
            }
            let scope = ComputerControlScope(bundleIdentifier: targetApp, isAuthorized: true)
            await tasks.startAdaptiveDesktop(goal: goal, scope: scope)
        } else {
            let attachments = tray.take()
            await brain.send(trimmed, attachments: attachments)
            askedID = brain.messages.last { $0.role == .user }?.id
        }
        return true
    }

    /// Parses a `/desktop` command into an optional target bundle identifier and goal string.
    /// If the first token contains a dot (e.g. `com.apple.TextEdit`), it is treated as the bundle ID.
    public static func parseDesktopCommand(_ text: String) -> (bundleID: String?, goal: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        if let first = parts.first, first.contains(".") && parts.count > 1 {
            return (String(first), String(parts[1]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (nil, trimmed)
    }
}
