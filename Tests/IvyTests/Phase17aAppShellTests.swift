import Testing
import Foundation
@testable import IvyCore

@MainActor
@Suite("Phase 17a - App router and Dock presence")
struct Phase17aRouterTests {
    @Test("Ivy stays in the Dock before launch, while open, and after the last window closes")
    func presence() {
        let router = AppRouter()
        #expect(router.presence == .regular)
        #expect(!router.isMainWindowOpen)
        router.mainWindowDidOpen()
        router.mainWindowDidOpen()
        router.mainWindowDidClose()
        #expect(router.isMainWindowOpen)
        #expect(router.presence == .regular)
        router.mainWindowDidClose()
        #expect(!router.isMainWindowOpen)
        #expect(router.presence == .regular)
        router.mainWindowDidClose()
        router.mainWindowDidOpen()
        #expect(router.isMainWindowOpen)
        router.mainWindowDidClose()
        #expect(!router.isMainWindowOpen, "a stray close cannot leave the window count negative")
        #expect(router.presence == .regular)
    }

    @Test("reopening a closed window never switches Ivy into accessory mode")
    func reopen() {
        let router = AppRouter()
        for _ in 0..<3 {
            router.mainWindowDidOpen()
            #expect(router.isMainWindowOpen)
            router.mainWindowDidClose()
            #expect(!router.isMainWindowOpen)
            #expect(router.presence == .regular)
        }
    }

    @Test("deep links only navigate; anything unexpected is ignored")
    func deepLinks() throws {
        let id = UUID()
        #expect(AppRouter.parse(try #require(URL(string: "ivy://conversation/\(id.uuidString)"))) == .conversation(id))
        #expect(AppRouter.parse(try #require(URL(string: "IVY://new"))) == .newConversation)
        for bad in ["ivy://conversation/not-a-uuid", "ivy://conversation/\(id.uuidString)/extra", "ivy://run_shell/rm",
                    "https://conversation/\(id.uuidString)", "ivy://new/thing"] {
            #expect(AppRouter.parse(try #require(URL(string: bad))) == nil, "\(bad)")
        }
    }

    @Test("legacy Dock preference remains readable without changing desktop app presence")
    func setting() throws {
        #expect(IvySettings.defaults.alwaysShowInDock == false)
        var s = IvySettings.defaults
        s.alwaysShowInDock = true
        let decoded = try JSONDecoder().decode(IvySettings.self, from: JSONEncoder().encode(s))
        #expect(decoded.alwaysShowInDock)
        #expect(AppRouter().presence == .regular)
        let old = try JSONDecoder().decode(IvySettings.self, from: Data(#"{"pushToTalkEnabled": false}"#.utf8))
        #expect(old.alwaysShowInDock == false && old.pushToTalkEnabled == false)
    }
}

@Suite("Phase 17a - Message blocks")
struct Phase17aMessageBlockTests {
    @Test("prose, code and diffs are split; languages are kept")
    func split() {
        let reply = """
        Because you assert too early. Classic.

        ```swift
        await until { listener.isListening }
        ```
        Here's the fix:
        ```diff
        - await until { listener.isListening }
        + await until { listener.isListening && status == .listening }
        ```
        Done.
        """
        #expect(MessageBlock.parse(reply) == [
            .text("Because you assert too early. Classic."),
            .code(language: "swift", code: "await until { listener.isListening }"),
            .text("Here's the fix:"),
            .diff("- await until { listener.isListening }\n+ await until { listener.isListening && status == .listening }"),
            .text("Done."),
        ])
    }

    @Test("plain text is one block; empty text is none")
    func plain() {
        #expect(MessageBlock.parse("Just words.\n\nTwo paragraphs.") == [.text("Just words.\n\nTwo paragraphs.")])
        #expect(MessageBlock.parse("  \n ").isEmpty)
    }

    @Test("a fence without a language is code; an unclosed fence runs to the end")
    func edges() {
        #expect(MessageBlock.parse("```\nls -la\n```") == [.code(language: nil, code: "ls -la")])
        #expect(MessageBlock.parse("Try:\n```bash title\necho hi") == [.text("Try:"), .code(language: "bash", code: "echo hi")])
        #expect(MessageBlock.parse("```patch\n+x\n```") == [.diff("+x")])
    }

    @Test("diff lines are classified for colouring")
    func diffLines() {
        #expect(DiffLineKind.of("+added") == .added)
        #expect(DiffLineKind.of("-removed") == .removed)
        #expect(DiffLineKind.of("@@ -1,2 +1,3 @@") == .hunk)
        #expect(DiffLineKind.of("--- a/file.swift") == .header)
        #expect(DiffLineKind.of("+++ b/file.swift") == .header)
        #expect(DiffLineKind.of(" unchanged") == .context)
    }
}

@Suite("Phase 17a - Sidebar grouping")
struct Phase17aGroupingTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func entry(_ title: String, hoursAgo: Double, pinned: Bool = false, archived: Bool = false, now: Date) -> ConversationSummary {
        ConversationSummary(id: UUID(), title: title, updatedAt: now.addingTimeInterval(-hoursAgo * 3600), messageCount: 2,
                            isPinned: pinned, isArchived: archived, preview: "")
    }

    @Test("pinned first, then by day; archived left out; empty sections dropped; newest first within a section")
    func grouping() throws {
        let now = try #require(utc.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 15)))
        let entries = [
            entry("Old", hoursAgo: 24 * 30, now: now),
            entry("Pinned old", hoursAgo: 24 * 40, pinned: true, now: now),
            entry("This morning", hoursAgo: 6, now: now),
            entry("Just now", hoursAgo: 0.1, now: now),
            entry("Last night", hoursAgo: 20, now: now),
            entry("Monday", hoursAgo: 24 * 3, now: now),
            entry("Archived", hoursAgo: 1, archived: true, now: now),
        ]
        let groups = ConversationGroup.group(entries, now: now, calendar: utc)
        #expect(groups.map(\.section) == [.pinned, .today, .yesterday, .previousWeek, .earlier])
        #expect(groups.map { $0.entries.map(\.title) } == [["Pinned old"], ["Just now", "This morning"], ["Last night"], ["Monday"], ["Old"]])
        #expect(ConversationGroup.group([], now: now, calendar: utc).isEmpty)
    }
}
