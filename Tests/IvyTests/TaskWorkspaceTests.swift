import Foundation
import os
import Testing
@testable import IvyCore

private final class WorkspacePlanner: TaskPlanning, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (contexts: [String](), replies: [String]()))
    init(_ replies: [String] = []) { state.withLock { $0.replies = replies } }
    var contexts: [String] { state.withLock { $0.contexts } }
    func plan(goal: String, context: String, tools: [FunctionDeclaration]) async throws -> String {
        state.withLock { s in
            s.contexts.append(context)
            return s.replies.isEmpty ? #"{"steps":[{"id":"1","title":"Read the fixture","tool":"workspace_read","arguments":{}}]}"# : s.replies.removeFirst()
        }
    }
}

private final class WorkspaceCalls: Sendable {
    let count = OSAllocatedUnfairLock(initialState: 0)
}

private struct WorkspaceReadTool: IvyTool {
    let name = "workspace_read"
    let description = "Read an offline test fixture"
    let safetyClassification = ToolSafetyClassification.safe
    let calls: WorkspaceCalls
    var declaration: FunctionDeclaration { .init(name: name, description: description) }
    func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        calls.count.withLock { $0 += 1 }
        return .success("Fixture reviewed")
    }
}

private struct WorkspaceConfirmation: ConfirmationProvider {
    func requestConfirmation(for request: ConfirmationRequest) async -> Bool { false }
}

@MainActor
private func workspaceEngine(planner: WorkspacePlanner = WorkspacePlanner(), store: TaskStore = InMemoryTaskStore(),
                             calls: WorkspaceCalls = WorkspaceCalls()) -> TaskEngine {
    let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [WorkspaceReadTool(calls: calls)]),
        safetyGate: InteractiveSafetyGate(confirmationProvider: WorkspaceConfirmation()), permissions: MockPermissionManager())
    return TaskEngine(planner: planner, dispatcher: dispatcher, denyPendingConfirmation: {}, store: store)
}

@Suite("Task workspace conversations") @MainActor
struct TaskWorkspaceTests {
    @Test("Starters/new drafts cannot plan or run; blank and blocked sends preserve the draft")
    func draftOnly() async {
        let planner = WorkspacePlanner()
        let calls = WorkspaceCalls()
        let engine = workspaceEngine(planner: planner, calls: calls)
        let session = TaskWorkspaceSession(engine: engine)
        session.newTask(prompt: " /AGENT Review a folder ")
        #expect(session.draft == "Review a folder" && session.isNewTask && session.selectedRun == nil)
        session.newTask(prompt: "Replace draft", blocked: true)
        #expect(!(await session.send(blocked: true)) && session.draft == "Review a folder")
        session.draft = " /agent "
        #expect(!(await session.send()))
        #expect(TaskWorkspaceSession.goalText(" ordinary goal ") == "ordinary goal")
        #expect(TaskWorkspaceSession.goalText("   ") == "")
        #expect(engine.run == nil && planner.contexts.isEmpty && calls.count.withLock { $0 } == 0)
    }

    @Test("A sent goal stays reviewable; following up carries context without executing")
    func followUp() async throws {
        let planner = WorkspacePlanner()
        let calls = WorkspaceCalls()
        let store = InMemoryTaskStore()
        let engine = workspaceEngine(planner: planner, store: store, calls: calls)
        let session = TaskWorkspaceSession(engine: engine)
        session.newTask(prompt: "Read my notes")
        #expect(await session.send())
        let firstID = try #require(session.selectedTaskID)
        #expect(engine.run?.phase == .awaitingApproval && engine.run?.origin == .taskWorkspace)
        #expect(session.draft.isEmpty && planner.contexts == [""] && calls.count.withLock { $0 } == 0)
        session.draft = "A second request"
        #expect(!(await session.send()))
        session.newTask(prompt: "Must not replace an active task")
        #expect(session.draft == "A second request")
        engine.approvePlan()
        #expect(await waitUntil { engine.run?.isActive == false })
        #expect(calls.count.withLock { $0 } == 1)
        session.draft = "Summarize that result"
        #expect(await session.send())
        #expect(engine.run?.parentTaskID == firstID && engine.run?.phase == .awaitingApproval)
        #expect(planner.contexts.last?.contains("Read my notes") == true)
        #expect(planner.contexts.last?.contains("Fixture reviewed") == true)
        #expect(session.thread.map(\.goal) == ["Read my notes", "Summarize that result"])
        #expect(calls.count.withLock { $0 } == 1, "A follow-up also requires plan approval")
        engine.cancel()
        let reopened = TaskWorkspaceSession(engine: workspaceEngine(store: store))
        reopened.select(engine.run?.id)
        #expect(reopened.thread.count == 2 && reopened.thread.first?.id == firstID)
        reopened.newTask(prompt: "Unrelated goal")
        #expect(reopened.thread.isEmpty)
    }

    @Test("New-task and each saved task retain separate unsent drafts")
    func draftSelection() async throws {
        let store = InMemoryTaskStore()
        let first = TaskRun(plan: TaskPlan(goal: "First", steps: []), phase: .finished(.succeeded), createdAt: .distantPast)
        let second = TaskRun(plan: TaskPlan(goal: "Second", steps: []), phase: .finished(.succeeded), createdAt: .now)
        try store.save(first); try store.save(second)
        let session = TaskWorkspaceSession(engine: workspaceEngine(store: store))
        session.newTask(prompt: "Fresh draft")
        session.select(first.id); session.draft = "First follow-up"
        session.select(first.id)
        #expect(session.draft == "First follow-up")
        session.select(second.id); session.draft = "Second follow-up"
        session.select(first.id)
        #expect(session.draft == "First follow-up")
        session.newTask()
        #expect(session.draft == "Fresh draft")
        session.select(second.id)
        #expect(session.draft == "Second follow-up")
        session.select(UUID())
        #expect(session.selectedRun == nil && session.thread.isEmpty)
    }

    @Test("Failed planning remains visible and sends are not mistaken for approvals")
    func failure() async {
        let planner = WorkspacePlanner([#"{"steps":[]}"#])
        let engine = workspaceEngine(planner: planner)
        let session = TaskWorkspaceSession(engine: engine)
        session.newTask(prompt: "Can't plan this")
        #expect(!(await session.send()))
        #expect(session.error != nil && session.selectedRun?.phase == .finished(.failed))
        #expect(!session.isSubmitting && session.thread.count == 1)
        session.dismissError(); #expect(session.error == nil)
        session.newTask(); #expect(session.selectedRun == nil)
    }

    @Test("Prior context is redacted/bounded and survives a planner-validation retry")
    func contextSafety() async throws {
        let invalid = #"{"steps":[{"id":"1","title":"Unknown","tool":"not_registered","arguments":{}}]}"#
        let valid = #"{"steps":[{"id":"1","title":"Read","tool":"workspace_read","arguments":{}}]}"#
        let planner = WorkspacePlanner([invalid, valid])
        let engine = workspaceEngine(planner: planner)
        let syntheticSecret = "AIza" + String(repeating: "x", count: 35)
        #expect((await engine.start(goal: "Follow up", context: syntheticSecret + String(repeating: "a", count: 6000))).isStarted)
        #expect(planner.contexts.count == 2 && planner.contexts[0].count <= 4096)
        #expect(!planner.contexts[0].contains(syntheticSecret))
        #expect(planner.contexts[1].hasPrefix(planner.contexts[0]))
        #expect(planner.contexts[1].contains("previous plan was rejected"))
        engine.cancel()
    }

    @Test("Old task JSON remains compatible; cyclic/missing parent links cannot loop")
    func compatibility() throws {
        let id = UUID(), other = UUID()
        let first = TaskRun(id: id, plan: TaskPlan(goal: "First", steps: []), phase: .finished(.succeeded),
                            createdAt: .distantPast, parentTaskID: other, origin: .taskWorkspace)
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
        json.removeValue(forKey: "parentTaskID"); json.removeValue(forKey: "origin")
        let old = try JSONDecoder().decode(TaskRun.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.parentTaskID == nil && old.origin == nil && old.goal == "First")
        let store = InMemoryTaskStore()
        try store.save(first)
        try store.save(TaskRun(id: other, plan: TaskPlan(goal: "Second", steps: []), phase: .finished(.failed), createdAt: .now, parentTaskID: id))
        let session = TaskWorkspaceSession(engine: workspaceEngine(store: store))
        session.select(id); #expect(session.thread.count == 2)
        let missing = TaskRun(plan: TaskPlan(goal: "Missing parent", steps: []), phase: .finished(.cancelled), createdAt: .now, parentTaskID: UUID())
        try store.save(missing)
        let recovered = TaskWorkspaceSession(engine: workspaceEngine(store: store))
        recovered.select(missing.id); #expect(recovered.thread.count == 1)
    }
}
