import Foundation
import Combine

/// Whether Ivy shows in the Dock and ⌘-Tab. Mirrors `NSApplication.ActivationPolicy` without importing AppKit.
public enum AppPresence: Equatable, Sendable {
    /// Menu-bar only (what `LSUIElement` gives Ivy.app at launch).
    case accessory
    /// A normal app: Dock icon, ⌘-Tab, menu bar.
    case regular
}

/// Where the user is in the app: which conversation the main window shows, and whether that window is open.
/// The single owner of the Dock decision, so window open/close can't leave the policy flickering or stuck.
@MainActor
public final class AppRouter: ObservableObject {
    /// The conversation the main window's sidebar has selected (nil = the brain's active conversation).
    @Published public var selectedConversationID: UUID?
    @Published public private(set) var presence: AppPresence = .accessory

    private var openMainWindows = 0
    private var alwaysShowInDock: Bool
    /// Applies the policy to the real app (AppKit lives in the app target).
    public var applyPresence: ((AppPresence) -> Void)?

    public init(alwaysShowInDock: Bool = false) {
        self.alwaysShowInDock = alwaysShowInDock
        presence = Self.presence(openWindows: 0, alwaysShowInDock: alwaysShowInDock)
    }

    /// The Dock icon appears while a main window is open (or always, if the user asked) and goes away after.
    public static func presence(openWindows: Int, alwaysShowInDock: Bool) -> AppPresence {
        openWindows > 0 || alwaysShowInDock ? .regular : .accessory
    }

    public func mainWindowDidOpen() {
        openMainWindows += 1
        update()
    }

    public func mainWindowDidClose() {
        openMainWindows = max(0, openMainWindows - 1)
        update()
    }

    public var isMainWindowOpen: Bool { openMainWindows > 0 }

    public func setAlwaysShowInDock(_ on: Bool) {
        alwaysShowInDock = on
        update()
    }

    private func update() {
        let next = Self.presence(openWindows: openMainWindows, alwaysShowInDock: alwaysShowInDock)
        guard next != presence else { return }
        presence = next
        applyPresence?(next)
    }

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
