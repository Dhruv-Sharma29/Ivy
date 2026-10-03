import Foundation
import Testing
@testable import Ivy
@testable import IvyCore

@MainActor
@Suite("Workspace library")
struct WorkspaceLibraryTests {
    private let date = Date(timeIntervalSince1970: 1_790_920_800)

    @Test("general browsing excludes archived chats and unfinished tasks, with distinct identities across content types")
    func libraryScope() {
        let id = UUID()
        let active = ConversationSummary(id: id, title: "Weekly notes", updatedAt: date, messageCount: 2, isPinned: true)
        let archived = ConversationSummary(id: UUID(), title: "Archived notes", updatedAt: date, messageCount: 1, isPinned: true, isArchived: true)
        let report = TaskRun(id: id, plan: TaskPlan(goal: "Review files", steps: []), phase: .finished(.succeeded), createdAt: date)
        let unfinished = TaskRun(plan: report.plan, phase: .awaitingApproval, createdAt: date)
        let all = WorkspaceLibraryCatalog.items(conversations: [active, archived], tasks: [report, unfinished], category: .all, query: "", sort: .newest)
        #expect(all.count == 2)
        #expect(Set(all.map(\.id)).count == 2)
        #expect(!all.contains { $0.title == archived.title })
        #expect(WorkspaceLibraryCatalog.items(conversations: [active, archived], tasks: [report], category: .pinned, query: "", sort: .newest).map(\.title) == [active.title])
        #expect(WorkspaceLibraryCatalog.items(conversations: [active, archived], tasks: [report], category: .archived, query: "", sort: .newest).map(\.title) == [archived.title])
        #expect(WorkspaceLibraryCatalog.items(conversations: [active, archived], tasks: [report], category: .conversations, query: "", sort: .newest).count == 1)
        #expect(WorkspaceLibraryCatalog.items(conversations: [active, archived], tasks: [report], category: .reports, query: "", sort: .newest).count == 1)
    }

    @Test("search combines words across title and preview and sorting handles tied dates consistently")
    func searchAndSort() {
        let older = ConversationSummary(id: UUID(), title: "Budget", updatedAt: date, messageCount: 2, preview: "Weekly review")
        let newer = ConversationSummary(id: UUID(), title: "Agenda", updatedAt: date.addingTimeInterval(60), messageCount: 2, preview: "Meeting notes")
        let tied = ConversationSummary(id: UUID(), title: "Zebra", updatedAt: newer.updatedAt, messageCount: 2)
        func catalog(_ query: String = "", _ sort: LibrarySort = .newest) -> [LibraryItem] {
            WorkspaceLibraryCatalog.items(conversations: [older, newer, tied], tasks: [], category: .all, query: query, sort: sort)
        }
        #expect(catalog("  BUDGET\nweekly ").map(\.title) == ["Budget"])
        #expect(catalog("Budget missing").isEmpty)
        #expect(catalog(" \n ").count == 3)
        #expect(catalog("", .title).map(\.title) == ["Agenda", "Budget", "Zebra"])
        #expect(catalog().last?.title == "Budget")
        #expect(catalog().map(\.id) == catalog().map(\.id))
    }

    @Test("task reports retain real outcomes, searchable report text and timestamps")
    func reportMetadata() {
        let phases: [TaskPhase] = [.planning, .awaitingApproval, .running(stepID: "1"), .paused(.budget("Time limit")),
                                  .finished(.succeeded), .finished(.failed), .finished(.cancelled)]
        for phase in phases {
            var run = TaskRun(plan: TaskPlan(goal: "Review invoices", steps: []), phase: phase, createdAt: date)
            #expect(!TaskRunDisplay.status(phase).isEmpty && !TaskRunDisplay.symbol(phase).isEmpty)
            #expect(TaskRunDisplay.matches(run, query: "review INVOICES"))
            #expect(!TaskRunDisplay.matches(run, query: "missing"))
            run.report = "Three receipts were found."
            run.finishedAt = date.addingTimeInterval(5)
            #expect(TaskRunDisplay.matches(run, query: "review receipts"))
            let item = LibraryItem.report(run)
            #expect(item.detail == run.report)
            #expect(item.date == run.finishedAt)
            #expect(!item.kind.isEmpty && !item.symbol.isEmpty)
        }
        let unreported = TaskRun(plan: TaskPlan(goal: "Stopped task", steps: []), phase: .finished(.cancelled), createdAt: date)
        #expect(LibraryItem.report(unreported).detail == "Stopped")
        #expect(LibraryItem.report(unreported).date == date)
        for flags in [(false, false), (true, false), (true, true)] {
            let entry = ConversationSummary(id: UUID(), title: "Notes", updatedAt: date, messageCount: 1,
                                            isPinned: flags.0, isArchived: flags.1, preview: "Saved text")
            let item = LibraryItem.conversation(entry)
            #expect(item.detail == "Saved text" && item.date == date)
            #expect(!item.kind.isEmpty && !item.symbol.isEmpty)
        }
    }
}
