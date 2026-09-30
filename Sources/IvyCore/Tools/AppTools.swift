import Foundation

// MARK: - finder

public protocol FinderControlling: Sendable {
    /// Shows the item selected in a Finder window.
    func reveal(path: String) async throws
    func openFolder(path: String) async throws
    /// POSIX paths of the items selected in Finder.
    func selection() async throws -> [String]
}

/// Reveals items, opens folders and reads the Finder selection (paths only). Nothing is changed on disk.
public final class FinderTool: IvyTool, Sendable {
    enum Action: String, CaseIterable { case reveal, open, selection }

    public let name = "finder"
    public let description = "Reveals a file in Finder, opens a folder in Finder, or lists the paths currently selected in Finder."
    public let group = ToolGroup.files
    public let safetyClassification = ToolSafetyClassification.safe
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "action": ToolProperty(type: "STRING", description: "One of: reveal, open, selection."),
                "path": ToolProperty(type: "STRING", description: "For reveal and open: a path inside the user's home folder (e.g. ~/Documents)."),
            ],
            required: ["action"]))
    }

    private let finder: FinderControlling
    private let allowedRoot: URL?

    public init(finder: FinderControlling = SystemFinder(), allowedRoot: URL? = nil) {
        self.finder = finder
        self.allowedRoot = allowedRoot
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> (action: Action, path: String?) {
        let args = ToolArguments(arguments)
        let action = try args.choice("action", Action.self)
        guard action != .selection else {
            try args.allow(["action"])
            return (action, nil)
        }
        try args.allow(["action", "path"])
        return (action, try ToolValidation.validateFilePath(try args.string("path", max: ToolValidation.maxPathLength), allowedRoot: allowedRoot))
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        do {
            switch request.action {
            case .reveal:
                try await finder.reveal(path: request.path ?? "")
                return .success("Revealed \(request.path ?? "") in Finder.")
            case .open:
                try await finder.openFolder(path: request.path ?? "")
                return .success("Opened \(request.path ?? "") in Finder.")
            case .selection:
                // Paths only, and never ones Ivy's file tools would refuse to touch.
                let paths = try await finder.selection().filter { FileSearchTool.isAllowed($0, allowedRoot: allowedRoot) }
                guard !paths.isEmpty else { return .success("Nothing is selected in Finder.") }
                return .success(paths.prefix(50).joined(separator: "\n"))
            }
        } catch {
            return .failure("Finder: \(error.localizedDescription)")
        }
    }
}

// MARK: - file_search

public protocol FileSearching: Sendable {
    /// Spotlight results under `root`, best first. `content` searches inside files instead of names.
    func search(query: String, content: Bool, root: URL) async throws -> [String]
}

/// Spotlight search by file name or content. Read-only, limited to the home folder, and blind to the same
/// credential locations `file_op` refuses (plus ~/Library).
public final class FileSearchTool: IvyTool, Sendable {
    public static let maxResults = 50
    enum Kind: String, CaseIterable { case name, content }

    public let name = "file_search"
    public let description = "Finds files in the user's home folder with Spotlight, by name or by text inside them. Returns paths only."
    public let group = ToolGroup.files
    public let safetyClassification = ToolSafetyClassification.safe
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "query": ToolProperty(type: "STRING", description: "Words to look for (e.g. 'resume')."),
                "kind": ToolProperty(type: "STRING", description: "'name' (default) to match file names, 'content' to match text inside files."),
                "limit": ToolProperty(type: "INTEGER", description: "Maximum results, 1–50. Default 20."),
            ],
            required: ["query"]))
    }

    private let searcher: FileSearching
    private let allowedRoot: URL?

    public init(searcher: FileSearching = SystemFileSearcher(), allowedRoot: URL? = nil) {
        self.searcher = searcher
        self.allowedRoot = allowedRoot
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> (query: String, content: Bool, limit: Int) {
        let args = ToolArguments(arguments)
        try args.allow(["query", "kind", "limit"])
        let query = try args.string("query", max: 200)
        // These would change the meaning of the Spotlight query rather than be searched for.
        guard query.rangeOfCharacter(from: CharacterSet(charactersIn: "\"'\\*")) == nil else {
            throw ToolError.invalidArgument("Argument 'query' cannot contain quotes, backslashes or asterisks.")
        }
        let kind = args.raw["kind"] == nil ? Kind.name : try args.choice("kind", Kind.self)
        let limit = try args.optionalInt("limit") ?? 20
        guard (1...Self.maxResults).contains(limit) else {
            throw ToolError.invalidArgument("Argument 'limit' must be between 1 and \(Self.maxResults).")
        }
        return (query, kind == .content, limit)
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    /// True for paths inside the home folder that aren't in a credential location or ~/Library.
    static func isAllowed(_ path: String, allowedRoot: URL?) -> Bool {
        let root = (allowedRoot ?? FileManager.default.homeDirectoryForCurrentUser).standardized.path
        guard !path.hasPrefix(root + "/Library/"), path != root + "/Library" else { return false }
        return (try? ToolValidation.validateFilePath(path, allowedRoot: allowedRoot)) != nil
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        let root = allowedRoot ?? FileManager.default.homeDirectoryForCurrentUser
        do {
            let found = try await searcher.search(query: request.query, content: request.content, root: root)
                .filter { Self.isAllowed($0, allowedRoot: allowedRoot) }
            guard !found.isEmpty else { return .success("No files matched '\(request.query)'.") }
            let shown = found.prefix(request.limit)
            let more = found.count > shown.count ? "\n… and \(found.count - shown.count) more" : ""
            return .success(shown.joined(separator: "\n") + more, summary: "found \(found.count) file(s) matching '\(request.query)'")
        } catch {
            return .failure("File search failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - media

/// Playback control for Music and Spotify through their own AppleScript commands. The scripts are fixed
/// text: nothing the model says ends up inside one.
public final class MediaTool: IvyTool, Sendable {
    enum Action: String, CaseIterable { case play, pause, toggle, next, previous, now_playing }
    /// The only players Ivy talks to, by bundle identifier.
    enum Player: String, CaseIterable {
        case music, spotify

        var bundleID: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
        var appName: String { self == .music ? "Music" : "Spotify" }
    }

    public let name = "media"
    public let description = "Controls music playback in Music or Spotify: play, pause, toggle, next, previous, or report what is playing."
    public let group = ToolGroup.media
    public let safetyClassification = ToolSafetyClassification.safe
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "action": ToolProperty(type: "STRING", description: "One of: play, pause, toggle, next, previous, now_playing."),
                "app": ToolProperty(type: "STRING", description: "Optional: 'music' or 'spotify'. Default: Spotify if it is installed and running, otherwise Music."),
            ],
            required: ["action"]))
    }

    private let executor: AppleScriptExecutorProtocol
    private let workspace: WorkspaceProtocol

    public init(executor: AppleScriptExecutorProtocol = SystemAppleScriptExecutor(), workspace: WorkspaceProtocol = SystemWorkspace()) {
        self.executor = executor
        self.workspace = workspace
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> (action: Action, player: Player?) {
        let args = ToolArguments(arguments)
        try args.allow(["action", "app"])
        return (try args.choice("action", Action.self), args.raw["app"] == nil ? nil : try args.choice("app", Player.self))
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    static func command(_ action: Action) -> String {
        switch action {
        case .play: return "play"
        case .pause: return "pause"
        case .toggle: return "playpause"
        case .next: return "next track"
        case .previous: return "previous track"
        case .now_playing:
            return """
            if player state is playing then
                        return (name of current track) & " — " & (artist of current track)
                    else
                        return "Nothing is playing."
                    end if
            """
        }
    }

    static func script(_ action: Action, player: Player) -> String {
        """
        tell application id "\(player.bundleID)"
            \(command(action))
        end tell
        """
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        // A script naming an app that isn't installed makes macOS ask the user to locate it: never build one.
        let spotifyInstalled = workspace.findApplicationURL(named: Player.spotify.appName) != nil
        if request.player == .spotify, !spotifyInstalled {
            return .failure("Spotify isn't installed.")
        }
        let script: String
        if let player = request.player {
            script = Self.script(request.action, player: player)
        } else if spotifyInstalled {
            script = """
            if application id "\(Player.spotify.bundleID)" is running then
            \(Self.script(request.action, player: .spotify))
            else
            \(Self.script(request.action, player: .music))
            end if
            """
        } else {
            script = Self.script(request.action, player: .music)
        }
        do {
            let output = try await executor.execute(script: script)
            if request.action == .now_playing { return .success(output) }
            return .success("Done: \(request.action.rawValue.replacingOccurrences(of: "_", with: " ")).")
        } catch {
            return .failure("Media control failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - reminders

public struct ReminderItem: Sendable, Equatable {
    public let title: String
    public let due: Date?
    public let list: String

    public init(title: String, due: Date?, list: String) {
        self.title = title
        self.due = due
        self.list = list
    }
}

public protocol RemindersExecuting: Sendable {
    /// Incomplete reminders, soonest due first.
    func incomplete() async throws -> [ReminderItem]
    /// Creates a reminder in the default list; returns that list's name.
    func create(title: String, due: Date?) async throws -> String
    /// Marks the first incomplete reminder with this exact title complete. False if none matched.
    func complete(title: String) async throws -> Bool
}

/// Lists reminders (safe), creates and completes them (risky). There is no delete.
public final class RemindersTool: IvyTool, Sendable {
    enum Action: String, CaseIterable { case list, create, complete }

    public let name = "reminders"
    public let description = "Lists the user's incomplete reminders, creates a reminder (optionally with a due date and time), or marks one complete by its exact title."
    public let group = ToolGroup.productivity
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "action": ToolProperty(type: "STRING", description: "One of: list, create, complete."),
                "title": ToolProperty(type: "STRING", description: "For create and complete: the reminder's title."),
                "due": ToolProperty(type: "STRING", description: "For create, optional: due date and time in ISO 8601 (e.g. '2026-10-01T18:00:00Z' or '2026-10-01 18:00')."),
            ],
            required: ["action"]))
    }

    private let executor: RemindersExecuting

    public init(executor: RemindersExecuting = SystemRemindersExecutor()) {
        self.executor = executor
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> (action: Action, title: String?, due: Date?, rawDue: String?) {
        let args = ToolArguments(arguments)
        let action = try args.choice("action", Action.self)
        switch action {
        case .list:
            try args.allow(["action"])
            return (action, nil, nil, nil)
        case .complete:
            try args.allow(["action", "title"])
            return (action, try args.string("title", max: ToolValidation.maxCalendarTitleLength), nil, nil)
        case .create:
            try args.allow(["action", "title", "due"])
            let rawDue = try args.optionalString("due", max: 64)
            return (action, try args.string("title", max: ToolValidation.maxCalendarTitleLength), try rawDue.map(ToolValidation.parseCalendarDate), rawDue)
        }
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func classification(for arguments: [String: AnyCodable]) -> ToolSafetyClassification {
        (try? parse(arguments))?.action == .list ? .safe : .risky
    }

    public func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType] { [.reminders] }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        guard let request = try? parse(arguments), let title = request.title else { return nil }
        if request.action == .complete {
            return ToolConfirmation(
                title: "Complete Reminder",
                prompt: "You're about to let me tick off '\(title)'. Whether you actually did it is between you and your conscience. Do it or chicken out?",
                detail: "Action: Mark reminder complete\nTitle: \(title)")
        }
        return ToolConfirmation(
            title: "Create Reminder",
            prompt: "You're about to add '\(title)' to your reminders. As if you'll look at it. Do it or chicken out?",
            detail: "Action: Create Reminder\nTitle: \(title)\nList: your default Reminders list\nDue: \(request.rawDue ?? "no due date")")
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        do {
            switch request.action {
            case .list:
                let items = try await executor.incomplete()
                guard !items.isEmpty else { return .success("No incomplete reminders.") }
                let lines = items.prefix(50).map { item in
                    "\(item.title) [\(item.list)]" + (item.due.map { " — due \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "")
                }
                return .success(lines.joined(separator: "\n"), summary: "listed \(items.count) reminder(s)")
            case .create:
                let list = try await executor.create(title: request.title ?? "", due: request.due)
                return .success("Created reminder '\(request.title ?? "")' in \(list)" + (request.due.map { ", due \($0.formatted(date: .abbreviated, time: .shortened))." } ?? "."))
            case .complete:
                guard try await executor.complete(title: request.title ?? "") else {
                    return .failure("No incomplete reminder is titled '\(request.title ?? "")'. List the reminders to get the exact title.")
                }
                return .success("Marked '\(request.title ?? "")' complete.")
            }
        } catch {
            return .failure("Reminders: \(error.localizedDescription)")
        }
    }
}

// MARK: - notes

/// Searches note titles (safe), reads a note (risky: its text goes to Gemini) and creates notes (risky).
/// There is no edit and no delete.
public final class NotesTool: IvyTool, Sendable {
    public static let maxBodyBytes = 10 * 1024
    enum Action: String, CaseIterable { case search, read, create }

    public let name = "notes"
    public let description = "Works with the Notes app: search note titles, read one note by its exact title, or create a new note."
    public let group = ToolGroup.productivity
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "action": ToolProperty(type: "STRING", description: "One of: search, read, create."),
                "query": ToolProperty(type: "STRING", description: "For search: text to look for in note titles."),
                "title": ToolProperty(type: "STRING", description: "For read: the note's exact title. For create: the new note's title."),
                "body": ToolProperty(type: "STRING", description: "For create: the note's text (plain text, at most 10 KB)."),
            ],
            required: ["action"]))
    }

    private let executor: AppleScriptExecutorProtocol

    public init(executor: AppleScriptExecutorProtocol = SystemAppleScriptExecutor()) {
        self.executor = executor
    }

    private enum Request {
        case search(String)
        case read(String)
        case create(title: String, body: String)
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> Request {
        let args = ToolArguments(arguments)
        switch try args.choice("action", Action.self) {
        case .search:
            try args.allow(["action", "query"])
            return .search(try args.string("query", max: 200))
        case .read:
            try args.allow(["action", "title"])
            return .read(try args.string("title", max: 300))
        case .create:
            try args.allow(["action", "title", "body"])
            let body = try args.string("body", max: Self.maxBodyBytes, multiline: true)
            guard body.utf8.count <= Self.maxBodyBytes else { throw ToolError.invalidArgument("Argument 'body' exceeds 10 KB.") }
            return .create(title: try args.string("title", max: 300), body: body)
        }
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func classification(for arguments: [String: AnyCodable]) -> ToolSafetyClassification {
        if case .search = try? parse(arguments) { return .safe }
        return .risky
    }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        switch try? parse(arguments) {
        case .read(let title):
            return ToolConfirmation(
                title: "Read Note",
                prompt: "You're about to let me read your note '\(title)'. I'll try not to judge what's in it. Do it or chicken out?",
                detail: "Action: Read note\nTitle: \(title)\nThe note's text is sent to Gemini to answer you. Anything that looks like an API key or token is masked first.")
        case .create(let title, let body):
            let shown = body.count > 300 ? String(body.prefix(300)) + "… [truncated]" : body
            return ToolConfirmation(
                title: "Create Note",
                prompt: "You're about to add a note called '\(title)'. One more thing you'll never read again. Do it or chicken out?",
                detail: "Action: Create Note\nTitle: \(title)\nText (\(body.count) characters):\n\(shown)")
        default:
            return nil
        }
    }

    /// Plain text → the HTML Notes stores. Every character that means something in HTML is escaped, so text
    /// can never become markup.
    static func html(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "<br>")
    }

    static func script(for action: String, _ a: String, _ b: String = "") -> String {
        switch action {
        case "search":
            return """
            tell application "Notes"
                set out to ""
                set n to 0
                repeat with aNote in (notes whose name contains \(AppleScriptLiteral.quote(a)))
                    set out to out & (name of aNote) & linefeed
                    set n to n + 1
                    if n ≥ 20 then exit repeat
                end repeat
                return out
            end tell
            """
        case "read":
            return """
            tell application "Notes"
                set hits to (notes whose name is \(AppleScriptLiteral.quote(a)))
                if (count of hits) is 0 then return ""
                return plaintext of (item 1 of hits)
            end tell
            """
        default:
            return """
            tell application "Notes"
                make new note with properties {name:\(AppleScriptLiteral.quote(a)), body:\(AppleScriptLiteral.quote(b))}
                return "created"
            end tell
            """
        }
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        do {
            switch request {
            case .search(let query):
                let titles = try await executor.execute(script: Self.script(for: "search", query))
                    .split(whereSeparator: \.isNewline).map(String.init)
                guard !titles.isEmpty else { return .success("No note titles contain '\(query)'.") }
                return .success(titles.joined(separator: "\n"), summary: "found \(titles.count) note title(s) matching '\(query)'")
            case .read(let title):
                let text = try await executor.execute(script: Self.script(for: "read", title))
                guard !text.isEmpty else { return .failure("No note is titled '\(title)'. Search the titles first.") }
                return .success(SecretRedactor.redact(text), summary: "read the note '\(title)'")
            case .create(let title, let body):
                _ = try await executor.execute(script: Self.script(for: "create", title, "<div><b>\(Self.html(title))</b></div><div>\(Self.html(body))</div>"))
                return .success("Created the note '\(title)'.", summary: "created the note '\(title)'")
            }
        } catch {
            return .failure("Notes: \(error.localizedDescription)")
        }
    }
}

// MARK: - contacts

public struct ContactMatch: Sendable, Equatable {
    public let name: String
    public let phones: [String]
    public let emails: [String]

    public init(name: String, phones: [String], emails: [String]) {
        self.name = name
        self.phones = phones
        self.emails = emails
    }
}

public protocol ContactsSearching: Sendable {
    func find(name: String) async throws -> [ContactMatch]
}

/// Looks up a contact's phone numbers and/or email addresses by name. Risky every time: it is personal data
/// about other people, and the answer goes to Gemini. Only the requested fields, at most 5 people.
public final class ContactsTool: IvyTool, Sendable {
    public static let maxMatches = 5
    enum Field: String, CaseIterable { case phone, email, both }

    public let name = "contacts"
    public let description = "Finds a person in the user's Contacts by name and returns their phone numbers and/or email addresses."
    public let group = ToolGroup.productivity
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "name": ToolProperty(type: "STRING", description: "The person's name, or part of it."),
                "field": ToolProperty(type: "STRING", description: "What to return: 'phone', 'email' or 'both' (default). Ask only for what the task needs."),
            ],
            required: ["name"]))
    }

    private let contacts: ContactsSearching

    public init(contacts: ContactsSearching = SystemContactsSearcher()) {
        self.contacts = contacts
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> (name: String, field: Field) {
        let args = ToolArguments(arguments)
        try args.allow(["name", "field"])
        return (try args.string("name", max: 100), args.raw["field"] == nil ? .both : try args.choice("field", Field.self))
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType] { [.contacts] }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        guard let request = try? parse(arguments) else { return nil }
        let wanted = request.field == .both ? "phone numbers and email addresses" : (request.field == .phone ? "phone numbers" : "email addresses")
        return ToolConfirmation(
            title: "Look Up Contact",
            prompt: "You're about to let me dig through your contacts for '\(request.name)'. They didn't agree to this, you know. Do it or chicken out?",
            detail: "Action: Look up a contact\nName: \(request.name)\nReturns: \(wanted) of up to \(Self.maxMatches) matching people\nThe result is sent to Gemini to answer you.")
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        let matches: [ContactMatch]
        do {
            matches = try await contacts.find(name: request.name)
        } catch {
            return .failure("Contacts: \(error.localizedDescription)")
        }
        guard !matches.isEmpty else { return .success("No contact matches '\(request.name)'.", summary: "looked up a contact (no match)") }
        let lines = matches.prefix(Self.maxMatches).map { match -> String in
            var parts = [match.name]
            if request.field != .email { parts.append("phone: " + (match.phones.isEmpty ? "none" : match.phones.joined(separator: ", "))) }
            if request.field != .phone { parts.append("email: " + (match.emails.isEmpty ? "none" : match.emails.joined(separator: ", "))) }
            return parts.joined(separator: " — ")
        }
        return .success(lines.joined(separator: "\n"), summary: "looked up a contact")
    }
}

// MARK: - mail

/// Opens a draft in the user's mail app, or searches inbox subjects. Ivy never sends mail: the draft sits in
/// a compose window until the user presses Send themselves.
public final class MailTool: IvyTool, Sendable {
    enum Action: String, CaseIterable { case draft, search }

    public let name = "mail"
    public let description = "Opens a new email draft (recipient, subject, body) in the user's mail app for them to review and send, or searches inbox subjects. It cannot send mail."
    public let group = ToolGroup.productivity
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "action": ToolProperty(type: "STRING", description: "'draft' or 'search'."),
                "to": ToolProperty(type: "STRING", description: "For draft, optional: one recipient email address."),
                "subject": ToolProperty(type: "STRING", description: "For draft: the subject line."),
                "body": ToolProperty(type: "STRING", description: "For draft: the message text."),
                "query": ToolProperty(type: "STRING", description: "For search: text to look for in inbox subjects."),
            ],
            required: ["action"]))
    }

    private let opener: URLOpening
    private let executor: AppleScriptExecutorProtocol

    public init(opener: URLOpening = SystemURLOpener(), executor: AppleScriptExecutorProtocol = SystemAppleScriptExecutor()) {
        self.opener = opener
        self.executor = executor
    }

    private enum Request {
        case draft(to: String?, subject: String, body: String)
        case search(String)
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> Request {
        let args = ToolArguments(arguments)
        switch try args.choice("action", Action.self) {
        case .search:
            try args.allow(["action", "query"])
            return .search(try args.string("query", max: 200))
        case .draft:
            try args.allow(["action", "to", "subject", "body"])
            let to = try args.optionalString("to", max: 254)
            if let to, to.wholeMatch(of: /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/) == nil {
                throw ToolError.invalidArgument("Argument 'to' must be a single email address.")
            }
            return .draft(to: to, subject: try args.string("subject", max: 300), body: try args.string("body", max: 20_000, multiline: true))
        }
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        switch try? parse(arguments) {
        case .draft(let to, let subject, let body):
            let shown = body.count > 300 ? String(body.prefix(300)) + "… [truncated]" : body
            return ToolConfirmation(
                title: "Open Email Draft",
                prompt: "You're about to let me write an email in your name. I only open the draft; pressing Send, and the consequences, are yours. Do it or chicken out?",
                detail: "Action: Open a draft in your mail app (nothing is sent)\nTo: \(to ?? "(left blank)")\nSubject: \(subject)\nBody (\(body.count) characters):\n\(shown)")
        case .search(let query):
            return ToolConfirmation(
                title: "Search Mail",
                prompt: "You're about to let me look through your inbox for '\(query)'. Do it or chicken out?",
                detail: "Action: Search inbox subjects in Mail\nLooking for: \(query)\nReturns: subject, sender and date of up to 10 messages, sent to Gemini to answer you.")
        case nil:
            return nil
        }
    }

    static func mailto(to: String?, subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to ?? ""
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        // URLComponents leaves "+" alone, which mail apps read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    static func searchScript(_ query: String) -> String {
        """
        tell application "Mail"
            set out to ""
            set hits to (messages of inbox whose subject contains \(AppleScriptLiteral.quote(query)))
            repeat with i from 1 to (count of hits)
                if i > 10 then exit repeat
                set m to item i of hits
                set out to out & (subject of m) & " — " & (sender of m) & " — " & ((date received of m) as string) & linefeed
            end repeat
            return out
        end tell
        """
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        switch try parse(arguments) {
        case .draft(let to, let subject, let body):
            guard let url = Self.mailto(to: to, subject: subject, body: body), await opener.open(url) else {
                return .failure("Couldn't open a draft: no mail app is set up to handle it.")
            }
            return .success("Opened a draft in the mail app. It has not been sent: the user must review it and press Send.",
                            summary: "opened an email draft (not sent)")
        case .search(let query):
            do {
                let lines = try await executor.execute(script: Self.searchScript(query)).split(whereSeparator: \.isNewline).map(String.init)
                guard !lines.isEmpty else { return .success("No inbox subjects contain '\(query)'.", summary: "searched mail (no match)") }
                return .success(SecretRedactor.redact(lines.joined(separator: "\n")), summary: "searched mail")
            } catch {
                return .failure("Mail: \(error.localizedDescription)")
            }
        }
    }
}
