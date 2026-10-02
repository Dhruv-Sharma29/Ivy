import Foundation
import Combine

/// Whether Ivy shows in the Dock and ⌘-Tab. Mirrors `NSApplication.ActivationPolicy` without importing AppKit.
public enum AppPresence: Equatable, Sendable {
    /// Reserved for accessory panels; Ivy itself is a regular desktop app.
    case accessory
    /// A normal app: Dock icon, ⌘-Tab, menu bar.
    case regular
}

/// Where the user is in the app: which conversation the main window shows, and whether that window is open.
/// Closing a window keeps Ivy in the Dock, so it can be reopened like any other Mac app.
@MainActor
public final class AppRouter: ObservableObject {
    /// The conversation the main window's sidebar has selected (nil = the brain's active conversation).
    @Published public var selectedConversationID: UUID?
    public let presence: AppPresence = .regular

    private var openMainWindows = 0
    public init() {}

    public func mainWindowDidOpen() {
        openMainWindows += 1
    }

    public func mainWindowDidClose() {
        openMainWindows = max(0, openMainWindows - 1)
    }

    public var isMainWindowOpen: Bool { openMainWindows > 0 }

    // MARK: - Deep links

    public enum DeepLink: Equatable, Sendable {
        case conversation(UUID)
        case newConversation
    }

    /// `ivy://conversation/<uuid>` and `ivy://new`. Anything else is ignored: links only navigate, never act.
    public static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == "ivy" else { return nil }
        let host = url.host?.lowercased()
        let parts = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "conversation":
            guard parts.count == 1, let id = UUID(uuidString: parts[0]) else { return nil }
            return .conversation(id)
        case "new":
            return parts.isEmpty ? .newConversation : nil
        default:
            return nil
        }
    }
}

// MARK: - Sidebar grouping

/// One section of the conversation sidebar.
public struct ConversationGroup: Identifiable, Equatable, Sendable {
    public enum Section: String, CaseIterable, Sendable {
        case pinned, today, yesterday, previousWeek, earlier

        public var title: String {
            switch self {
            case .pinned: return "Pinned"
            case .today: return "Today"
            case .yesterday: return "Yesterday"
            case .previousWeek: return "Previous 7 Days"
            case .earlier: return "Earlier"
            }
        }
    }

    public var id: Section { section }
    public let section: Section
    public let entries: [ConversationSummary]

    /// Pinned first (by recency), then by the day of the last message. Archived conversations are left out;
    /// empty sections are dropped.
    public static func group(_ entries: [ConversationSummary], now: Date = Date(), calendar: Calendar = .current) -> [ConversationGroup] {
        let shown = entries.filter { !$0.isArchived }.sorted { $0.updatedAt > $1.updatedAt }
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let weekAgo = calendar.date(byAdding: .day, value: -7, to: today) ?? today

        var buckets: [Section: [ConversationSummary]] = [:]
        for entry in shown {
            let section: Section
            if entry.isPinned {
                section = .pinned
            } else if entry.updatedAt >= today {
                section = .today
            } else if entry.updatedAt >= yesterday {
                section = .yesterday
            } else if entry.updatedAt >= weekAgo {
                section = .previousWeek
            } else {
                section = .earlier
            }
            buckets[section, default: []].append(entry)
        }
        return Section.allCases.compactMap { section in
            buckets[section].map { ConversationGroup(section: section, entries: $0) }
        }
    }
}
