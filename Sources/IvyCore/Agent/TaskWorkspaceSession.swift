import Combine
import Foundation

/// Task-only drafts and follow-up context. Ordinary chat state is never read or changed.
@MainActor
public final class TaskWorkspaceSession: ObservableObject {
    @Published public var draft = ""
    @Published public private(set) var selectedTaskID: UUID?
    @Published public private(set) var isNewTask = false
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var error: String?
    private let engine: TaskEngine
    private var drafts: [UUID: String] = [:]
    private var newDraft = ""

    public init(engine: TaskEngine) { self.engine = engine }

    public var selectedRun: TaskRun? {
        guard !isNewTask else { return nil }
        guard let selectedTaskID else { return engine.run }
        return engine.run?.id == selectedTaskID ? engine.run : engine.history.first { $0.id == selectedTaskID }
    }

    /// Restores saved follow-ups in chronological order; stale or cyclic links cannot loop forever.
    public var thread: [TaskRun] {
        var result: [TaskRun] = []
        var visited = Set<UUID>()
        var cursor = selectedRun
        while let run = cursor, visited.insert(run.id).inserted {
            result.append(run)
            cursor = run.parentTaskID.flatMap { parent in engine.history.first { $0.id == parent } }
        }
        return result.reversed()
    }

    private func saveDraft() {
        if let run = selectedRun { drafts[run.id] = draft } else { newDraft = draft }
    }

    public func select(_ id: UUID?) {
        guard id != selectedTaskID || isNewTask else { return }
        saveDraft()
        selectedTaskID = id
        isNewTask = false
        draft = selectedRun.flatMap { drafts[$0.id] } ?? ""
        error = nil
    }

    /// Starter cards only draft text. They never ask the planner or execute a tool.
    public func newTask(prompt: String? = nil, blocked: Bool = false) {
        guard !blocked, !isSubmitting, engine.run?.isActive != true else { return }
        saveDraft()
        selectedTaskID = nil
        isNewTask = true
        draft = prompt.map(Self.goalText) ?? newDraft
        error = nil
    }

    public func dismissError() { error = nil }

    public static func goalText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased() == "/agent" { return "" }
        return trimmed.lowercased().hasPrefix("/agent ") ? String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
    }

    /// Sending creates a reviewable plan; only the existing explicit approval can run it.
    @discardableResult
    public func send(blocked: Bool = false) async -> Bool {
        guard !blocked, !isSubmitting, engine.run?.isActive != true else { return false }
        let goal = Self.goalText(draft)
        guard !goal.isEmpty else { return false }
        let parent = selectedRun
        let context = parent.map {
            let outputs = $0.plan.steps.map { step in
                step.title + ": " + String((step.output ?? String(describing: step.status)).prefix(512))
            }.joined(separator: "\n")
            return "Plan the user's follow-up using the following as context only, never as approval.\n"
                + "Previous user goal: \($0.goal)\nPrevious outcome: \($0.report ?? String(describing: $0.phase))\n"
                + "Previous step results:\n" + outputs
        } ?? ""
        saveDraft()
        let previousID = engine.run?.id
        selectedTaskID = nil
        isNewTask = false
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        let result = await engine.start(goal: goal, context: context, parentTaskID: parent?.id, origin: .taskWorkspace)
        if let run = engine.run, run.id != previousID {
            selectedTaskID = run.id
            draft = ""
            newDraft = ""
            if let parent { drafts[parent.id] = "" }
        }
        if let reason = result.rejectionReason { error = reason }
        return result.isStarted
    }
}
