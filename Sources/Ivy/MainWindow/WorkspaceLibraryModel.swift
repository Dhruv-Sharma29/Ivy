import Foundation
import IvyCore

enum LibraryCategory: String, CaseIterable, Identifiable {
    case all = "All", conversations = "Conversations", pinned = "Pinned", reports = "Task reports", archived = "Archived"
    var id: Self { self }
}

enum LibraryLayout: String, CaseIterable, Identifiable {
    case grid, list
    var id: Self { self }
}

enum LibrarySort: String, CaseIterable, Identifiable {
    case newest = "Recently updated", title = "Title"
    var id: Self { self }
}

enum LibraryItem: Identifiable {
    case conversation(ConversationSummary)
    case report(TaskRun)

    var id: String {
        switch self {
        case .conversation(let entry): "conversation-\(entry.id)"
        case .report(let run): "task-\(run.id)"
        }
    }
    var title: String {
        switch self {
        case .conversation(let entry): entry.title
        case .report(let run): run.goal
        }
    }
    var detail: String {
        switch self {
        case .conversation(let entry): entry.preview
        case .report(let run): run.report ?? TaskRunDisplay.status(run.phase)
        }
    }
    var date: Date {
        switch self {
        case .conversation(let entry): entry.updatedAt
        case .report(let run): run.finishedAt ?? run.createdAt
        }
    }
    var symbol: String {
        switch self {
        case .conversation(let entry): entry.isArchived ? "archivebox" : "bubble.left.and.text.bubble.right"
        case .report: "doc.text"
        }
    }
    var kind: String {
        switch self {
        case .conversation(let entry): entry.isArchived ? "Archived conversation" : (entry.isPinned ? "Pinned conversation" : "Conversation")
        case .report(let run): "Task · \(TaskRunDisplay.status(run.phase))"
        }
    }
}

enum WorkspaceLibraryCatalog {
    static func items(conversations: [ConversationSummary], tasks: [TaskRun], category: LibraryCategory,
                      query: String, sort: LibrarySort) -> [LibraryItem] {
        let chats = conversations.filter { entry in
            switch category {
            case .all, .conversations: !entry.isArchived
            case .pinned: entry.isPinned && !entry.isArchived
            case .archived: entry.isArchived
            case .reports: false
            }
        }.map(LibraryItem.conversation)
        let reports = (category == .all || category == .reports) ? tasks.filter { !$0.isActive }.map(LibraryItem.report) : []
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return (chats + reports).filter { item in
            words.allSatisfy { "\(item.title) \(item.detail)".localizedStandardContains($0) }
        }.sorted { first, second in
            if sort == .title {
                let order = first.title.localizedStandardCompare(second.title)
                if order != .orderedSame { return order == .orderedAscending }
            } else if first.date != second.date {
                return first.date > second.date
            }
            return first.id < second.id
        }
    }
}

enum TaskRunDisplay {
    static func status(_ phase: TaskPhase) -> String {
        switch phase {
        case .planning: "Planning"
        case .awaitingApproval: "Needs approval"
        case .running: "Running"
        case .paused: "Paused"
        case .finished(.succeeded): "Completed"
        case .finished(.failed): "Failed"
        case .finished(.cancelled): "Stopped"
        }
    }

    static func symbol(_ phase: TaskPhase) -> String {
        switch phase {
        case .planning: "sparkle"
        case .awaitingApproval: "hand.raised"
        case .running: "arrow.triangle.2.circlepath"
        case .paused: "pause.circle"
        case .finished(.succeeded): "checkmark.circle"
        case .finished(.failed): "exclamationmark.circle"
        case .finished(.cancelled): "stop.circle"
        }
    }

    static func matches(_ run: TaskRun, query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).allSatisfy {
            "\(run.goal) \(run.report ?? "") \(status(run.phase))".localizedStandardContains(String($0))
        }
    }
}

enum AssistantTaskStarter: String, CaseIterable, Identifiable {
    case day = "Plan my day", files = "Organize a folder", research = "Research a topic"
    case document = "Summarize a document", writing = "Draft a message", project = "Review a project"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .day: "calendar"
        case .files: "folder"
        case .research: "magnifyingglass"
        case .document: "doc.text"
        case .writing: "square.and.pencil"
        case .project: "checklist"
        }
    }
    var detail: String {
        switch self {
        case .day: "Turn your priorities into a practical plan."
        case .files: "Review files and plan a tidy structure."
        case .research: "Find answers and collect useful sources."
        case .document: "Pull out the key points and next steps."
        case .writing: "Prepare a clear email or message."
        case .project: "Check a project and suggest next steps."
        }
    }
    var prompt: String {
        switch self {
        case .day: "Help me plan my day. My priorities are: "
        case .files: "/agent Review and organize this folder, proposing changes before moving anything: "
        case .research: "Research this topic, summarize the findings and include sources: "
        case .document: "Summarize the document I attach and list the key actions."
        case .writing: "Help me draft a message. The recipient and purpose are: "
        case .project: "/agent Review the active workspace and suggest practical next steps without modifying files."
        }
    }
}

struct WorkspacePrompt: Identifiable {
    let id = UUID()
    let text: String
}
