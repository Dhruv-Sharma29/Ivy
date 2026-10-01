import Foundation

/// Shared argument checks and execution for the developer tools. Everything runs with an explicit argument
/// vector in the active workspace; paths and refs are validated so nothing can be read as an option.
enum GitTools {
    static let gitPath = "/usr/bin/git"
    static let readTimeout: TimeInterval = 20
    static let writeTimeout: TimeInterval = 60
    static let maxOutputLines = 400

    /// Branch/commit/ref names: no leading "-" (option injection), no "..", no whitespace or control characters.
    static func ref(_ args: ToolArguments, _ key: String) throws -> String {
        let value = try args.string(key, max: 100)
        guard value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._/~^@{}-]*$"#, options: .regularExpression) != nil,
              !value.contains(".."), !value.hasSuffix(".lock"), !value.hasSuffix("/") else {
            throw ToolError.invalidArgument("'\(value)' isn't a valid branch or commit name.")
        }
        return value
    }

    /// Workspace-relative paths, validated like `file_op` and required to stay inside the workspace.
    static func paths(_ args: ToolArguments, _ key: String, in workspace: Workspace, required: Bool) throws -> [String] {
        guard let raw = args.raw[key] else {
            if required { throw ToolError.missingArgument(key) }
            return []
        }
        // A string of paths separated by commas or new lines (declared as STRING: Gemini needs an item schema for
        // arrays). A JSON array is accepted too.
        let texts: [String]
        if let list = raw.arrayValue {
            texts = try list.map { item in
                guard let text = item.stringValue else { throw ToolError.invalidArgument("Paths must be strings.") }
                return text
            }
        } else if let text = raw.stringValue {
            texts = text.split(whereSeparator: { $0 == "," || $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } else {
            throw ToolError.invalidArgument("'\(key)' must be a path or a list of paths.")
        }
        guard !texts.isEmpty, texts.count <= 50 else { throw ToolError.invalidArgument("Give 1–50 paths.") }
        return try texts.map { text in
            let absolute = try ToolValidation.validateFilePath(text, allowedRoot: workspace.rootURL)
            guard workspace.contains(absolute) else { throw ToolError.invalidArgument("\(text) is outside the workspace.") }
            let relative = String(absolute.dropFirst(workspace.rootURL.standardized.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return relative.isEmpty ? "." : relative
        }
    }

    static func clip(_ text: String, lines: Int = maxOutputLines) -> String {
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = all.count > lines ? all.prefix(lines).joined(separator: "\n") + "\n… [\(all.count - lines) more lines]" : text
        return SecretRedactor.redact(kept)
    }

    static func result(_ output: CommandOutput, empty: String) -> ToolResult {
        let text = clip(output.combined)
        guard output.exitCode == 0 else { return .failure(text.isEmpty ? "git exited with status \(output.exitCode)." : text) }
        return .success(text.isEmpty ? empty : text)
    }
}

// MARK: - git_read

/// Read-only git: status, diff, log, branches, show, blame. Safe: it changes nothing.
public final class GitReadTool: IvyTool, Sendable {
    enum Action: String, CaseIterable { case status, diff, log, branches, show, blame }

    public let name = "git_read"
    public let description = "Reads git state in the active workspace: status, diff (staged or not, optional paths), log (last n), branches, show a commit, blame lines of a file. Changes nothing."
    public let group = ToolGroup.developer
    public let safetyClassification = ToolSafetyClassification.safe
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "action": ToolProperty(type: "STRING", description: "One of: status, diff, log, branches, show, blame."),
                "staged": ToolProperty(type: "BOOLEAN", description: "For diff: the staged changes instead of the working tree."),
                "paths": ToolProperty(type: "STRING", description: "For diff: workspace-relative paths to limit it to, separated by commas or new lines."),
                "count": ToolProperty(type: "INTEGER", description: "For log: how many commits (1–50, default 10)."),
                "commit": ToolProperty(type: "STRING", description: "For show: a commit hash or ref."),
                "path": ToolProperty(type: "STRING", description: "For blame: a file in the workspace."),
                "start_line": ToolProperty(type: "INTEGER", description: "For blame: first line."),
                "end_line": ToolProperty(type: "INTEGER", description: "For blame: last line (at most 200 lines)."),
            ],
            required: ["action"]))
    }

    private let scope: WorkspaceScope
    private let runner: CommandRunning

    public init(scope: WorkspaceScope, runner: CommandRunning = SystemCommandRunner()) {
        self.scope = scope
        self.runner = runner
    }

    func argv(_ arguments: [String: AnyCodable]) throws -> [String] {
        let workspace = try scope.require()
        let args = ToolArguments(arguments)
        switch try args.choice("action", Action.self) {
        case .status:
            try args.allow(["action"])
            return ["status", "--short", "--branch"]
        case .diff:
            try args.allow(["action", "staged", "paths"])
            let paths = try GitTools.paths(args, "paths", in: workspace, required: false)
            return ["diff", "--no-color", "--no-ext-diff"] + ((try args.optionalBool("staged")) == true ? ["--cached"] : []) + ["--"] + paths
        case .log:
            try args.allow(["action", "count"])
            let count = try args.optionalInt("count") ?? 10
            guard (1...50).contains(count) else { throw ToolError.invalidArgument("'count' must be 1–50.") }
            return ["log", "--no-color", "-n", String(count), "--pretty=format:%h %ad %an %s", "--date=short"]
        case .branches:
            try args.allow(["action"])
            return ["branch", "--all", "--no-color", "-vv"]
        case .show:
            try args.allow(["action", "commit"])
            return ["show", "--no-color", "--stat", "--patch", "--no-ext-diff", try GitTools.ref(args, "commit"), "--"]
        case .blame:
            try args.allow(["action", "path", "start_line", "end_line"])
            guard let path = try GitTools.paths(args, "path", in: workspace, required: true).first else { throw ToolError.missingArgument("path") }
            let start = try args.optionalInt("start_line") ?? 1
            let end = try args.optionalInt("end_line") ?? start + 49
            guard start >= 1, end >= start, end - start < 200 else { throw ToolError.invalidArgument("Blame at most 200 lines, start ≥ 1.") }
            return ["blame", "-L", "\(start),\(end)", "--", path]
        }
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try argv(arguments) }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let argv = try argv(arguments)
        let workspace = try scope.require()
        do {
            let output = try await runner.run(GitTools.gitPath, argv, in: workspace.rootURL, timeout: GitTools.readTimeout)
            return GitTools.result(output, empty: argv.first == "diff" ? "No changes." : "Nothing to show.")
        } catch {
            return .failure("git: \(error.localizedDescription)")
        }
    }
}

// MARK: - git_write

/// Local repository changes: stage, unstage, commit, create/switch branch, stash. Risky: each shows the exact
/// command. Destructive operations (reset --hard, clean, branch -D, rebase, amend) are not offered at all.
public final class GitWriteTool: IvyTool, Sendable {
    enum Action: String, CaseIterable { case stage, unstage, commit, create_branch, switch_branch, stash, stash_pop }

    public let name = "git_write"
    public let description = "Changes the local git repository in the active workspace: stage or unstage paths, commit staged changes with a message, create or switch branches, stash and pop. Cannot reset, clean, rebase, amend or delete branches."
    public let group = ToolGroup.developer
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "action": ToolProperty(type: "STRING", description: "One of: stage, unstage, commit, create_branch, switch_branch, stash, stash_pop."),
                "paths": ToolProperty(type: "STRING", description: "For stage/unstage: workspace-relative paths, separated by commas or new lines."),
                "message": ToolProperty(type: "STRING", description: "For commit: the full commit message."),
                "branch": ToolProperty(type: "STRING", description: "For create_branch/switch_branch: the branch name."),
            ],
            required: ["action"]))
    }

    private let scope: WorkspaceScope
    private let runner: CommandRunning

    public init(scope: WorkspaceScope, runner: CommandRunning = SystemCommandRunner()) {
        self.scope = scope
        self.runner = runner
    }

    func argv(_ arguments: [String: AnyCodable]) throws -> [String] {
        let workspace = try scope.require()
        let args = ToolArguments(arguments)
        switch try args.choice("action", Action.self) {
        case .stage:
            try args.allow(["action", "paths"])
            return ["add", "--"] + (try GitTools.paths(args, "paths", in: workspace, required: true))
        case .unstage:
            try args.allow(["action", "paths"])
            return ["restore", "--staged", "--"] + (try GitTools.paths(args, "paths", in: workspace, required: true))
        case .commit:
            try args.allow(["action", "message"])
            let message = try args.string("message", max: 5_000, multiline: true)
            if let reason = SensitiveDataDetector.reason(message) {
                throw ToolError.invalidArgument("The commit message looks like it contains \(reason).")
            }
            return ["commit", "-m", message]
        case .create_branch:
            try args.allow(["action", "branch"])
            return ["switch", "-c", try GitTools.ref(args, "branch")]
        case .switch_branch:
            try args.allow(["action", "branch"])
            return ["switch", try GitTools.ref(args, "branch")]
        case .stash:
            try args.allow(["action"])
            return ["stash", "push"]
        case .stash_pop:
            try args.allow(["action"])
            return ["stash", "pop"]
        }
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try argv(arguments) }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        guard let argv = try? argv(arguments), let workspace = scope.current else { return nil }
        let shown = argv.first == "commit" ? "git commit -m <message below>" : "git " + argv.joined(separator: " ")
        var detail = "Action: Change the git repository\nWorkspace: \(workspace.root)\nCommand: \(shown)"
        if argv.first == "commit", let message = argv.last { detail += "\nMessage:\n\(message)" }
        return ToolConfirmation(
            title: "Git: \(argv.prefix(2).joined(separator: " "))",
            prompt: "You're about to let me touch your repository. It's local and reversible, mostly. Do it or chicken out?",
            detail: detail)
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let argv = try argv(arguments)
        let workspace = try scope.require()
        do {
            let output = try await runner.run(GitTools.gitPath, argv, in: workspace.rootURL, timeout: GitTools.writeTimeout)
            return GitTools.result(output, empty: "Done.")
        } catch {
            return .failure("git: \(error.localizedDescription)")
        }
    }
}

// MARK: - git_remote

/// fetch, pull (fast-forward only), push the current branch (never force). Risky.
public final class GitRemoteTool: IvyTool, Sendable {
    enum Action: String, CaseIterable { case fetch, pull, push }

    public let name = "git_remote"
    public let description = "Talks to the git remote of the active workspace: fetch, pull (fast-forward only), or push the current branch to its upstream (never force)."
    public let group = ToolGroup.developer
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "action": ToolProperty(type: "STRING", description: "One of: fetch, pull, push."),
                "set_upstream": ToolProperty(type: "BOOLEAN", description: "For push: publish the current branch to origin and track it."),
            ],
            required: ["action"]))
    }

    private let scope: WorkspaceScope
    private let runner: CommandRunning

    public init(scope: WorkspaceScope, runner: CommandRunning = SystemCommandRunner()) {
        self.scope = scope
        self.runner = runner
    }

    func argv(_ arguments: [String: AnyCodable]) throws -> [String] {
        _ = try scope.require()
        let args = ToolArguments(arguments)
        switch try args.choice("action", Action.self) {
        case .fetch:
            try args.allow(["action"])
            return ["fetch", "--prune"]
        case .pull:
            try args.allow(["action"])
            return ["pull", "--ff-only"]
        case .push:
            try args.allow(["action", "set_upstream"])
            return (try args.optionalBool("set_upstream")) == true ? ["push", "--set-upstream", "origin", "HEAD"] : ["push"]
        }
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try argv(arguments) }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        guard let argv = try? argv(arguments), let workspace = scope.current else { return nil }
        let pushing = argv.first == "push"
        return ToolConfirmation(
            title: "Git: \(argv[0])",
            prompt: pushing
                ? "You're about to let me push your commits for the world to see. No force, at least. Do it or chicken out?"
                : "You're about to let me talk to your git remote. Do it or chicken out?",
            detail: "Action: \(pushing ? "Publish commits to the remote" : "Update from the remote")\nWorkspace: \(workspace.root)\nCommand: git \(argv.joined(separator: " "))")
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let argv = try argv(arguments)
        let workspace = try scope.require()
        do {
            let output = try await runner.run(GitTools.gitPath, argv, in: workspace.rootURL, timeout: 120)
            return GitTools.result(output, empty: "Done.")
        } catch {
            return .failure("git: \(error.localizedDescription)")
        }
    }
}

// MARK: - code_search

/// Text or file-name search in the workspace, honouring .gitignore (via `git grep` / `git ls-files`). Safe.
public final class CodeSearchTool: IvyTool, Sendable {
    public static let maxMatches = 200
    enum Kind: String, CaseIterable { case text, regex, filename }

    public let name = "code_search"
    public let description = "Searches the active workspace: literal text, a regular expression, or file names. Ignores files listed in .gitignore. Returns at most 200 matches as path:line: text."
    public let group = ToolGroup.developer
    public let safetyClassification = ToolSafetyClassification.safe
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "query": ToolProperty(type: "STRING", description: "What to look for."),
                "kind": ToolProperty(type: "STRING", description: "'text' (default), 'regex', or 'filename'."),
                "ignore_case": ToolProperty(type: "BOOLEAN", description: "Case-insensitive (default false)."),
            ],
            required: ["query"]))
    }

    private let scope: WorkspaceScope
    private let runner: CommandRunning

    public init(scope: WorkspaceScope, runner: CommandRunning = SystemCommandRunner()) {
        self.scope = scope
        self.runner = runner
    }

    func parse(_ arguments: [String: AnyCodable]) throws -> (query: String, kind: Kind, ignoreCase: Bool) {
        _ = try scope.require()
        let args = ToolArguments(arguments)
        try args.allow(["query", "kind", "ignore_case"])
        let kind = args.raw["kind"] == nil ? Kind.text : try args.choice("kind", Kind.self)
        let query = try args.string("query", max: 300)
        if kind == .regex {
            do { _ = try NSRegularExpression(pattern: query) } catch { throw ToolError.invalidArgument("That isn't a valid regular expression.") }
        }
        return (query, kind, try args.optionalBool("ignore_case") ?? false)
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        let workspace = try scope.require()
        do {
            switch request.kind {
            case .filename:
                let output = try await runner.run(GitTools.gitPath, ["ls-files", "--cached", "--others", "--exclude-standard"],
                                                  in: workspace.rootURL, timeout: GitTools.readTimeout)
                guard output.exitCode == 0 else { return .failure("code_search needs a git repository: \(GitTools.clip(output.combined))") }
                let hits = output.stdout.split(separator: "\n").filter {
                    request.ignoreCase ? $0.localizedCaseInsensitiveContains(request.query) : $0.contains(request.query)
                }
                return Self.format(hits.map(String.init), query: request.query)
            case .text, .regex:
                var argv = ["grep", "-n", "-I", "--untracked", "--exclude-standard", "--no-color", "--max-count=20"]
                argv.append(request.kind == .regex ? "-E" : "-F")
                if request.ignoreCase { argv.append("-i") }
                argv += ["-e", request.query, "--"]
                let output = try await runner.run(GitTools.gitPath, argv, in: workspace.rootURL, timeout: GitTools.readTimeout)
                // git grep exits 1 for "no matches".
                guard output.exitCode == 0 || output.exitCode == 1 else {
                    return .failure("code_search needs a git repository: \(GitTools.clip(output.combined))")
                }
                return Self.format(output.stdout.split(separator: "\n").map(String.init), query: request.query)
            }
        } catch {
            return .failure("code_search: \(error.localizedDescription)")
        }
    }

    static func format(_ hits: [String], query: String) -> ToolResult {
        guard !hits.isEmpty else { return .success("No matches for '\(query)'.") }
        let shown = hits.prefix(maxMatches).map { String($0.prefix(300)) }
        let more = hits.count > maxMatches ? "\n… and \(hits.count - maxMatches) more" : ""
        return .success(SecretRedactor.redact(shown.joined(separator: "\n") + more), summary: "searched the workspace for '\(query)' (\(hits.count) matches)")
    }
}

// MARK: - project_run

/// Runs the workspace's own build / test / lint / run command. The model only names which; the command text
/// comes from the workspace (detected, or set by the user), so the card shows a command the model didn't write.
public final class ProjectRunTool: IvyTool, Sendable {
    public static let timeout: TimeInterval = 10 * 60
    public static let tailLines = 200

    public let name = "project_run"
    public let description = "Runs one of the active workspace's project commands (build, test, lint or run) in the workspace folder, and returns the output tail plus parsed errors. The commands themselves come from the workspace settings."
    public let group = ToolGroup.developer
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: ["command": ToolProperty(type: "STRING", description: "One of: build, test, lint, run.")],
            required: ["command"]))
    }

    private let scope: WorkspaceScope
    private let shell: ShellExecutorProtocol

    public init(scope: WorkspaceScope, shell: ShellExecutorProtocol = SystemShellExecutor()) {
        self.scope = scope
        self.shell = shell
    }

    func resolve(_ arguments: [String: AnyCodable]) throws -> (name: String, command: String, workspace: Workspace) {
        let workspace = try scope.require()
        let args = ToolArguments(arguments)
        try args.allow(["command"])
        let name = try args.string("command", max: 20).lowercased()
        guard Workspace.commandNames.contains(name) else {
            throw ToolError.invalidArgument("'\(name)' isn't a project command. Use one of: \(Workspace.commandNames.joined(separator: ", ")).")
        }
        guard let command = workspace.commands[name] else {
            let known = workspace.commands.keys.sorted().joined(separator: ", ")
            throw ToolError.invalidArgument("This workspace has no '\(name)' command\(known.isEmpty ? "" : " (it has: \(known))"). The user can set one in the Workspace menu.")
        }
        return (name, command, workspace)
    }

    /// `cd '<root>' && <command>`, with the root single-quoted so a path can't break out of it.
    static func shellLine(_ command: String, in root: String) -> String {
        "cd '" + root.replacingOccurrences(of: "'", with: "'\\''") + "' && " + command
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try resolve(arguments) }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        guard let request = try? resolve(arguments) else { return nil }
        return ToolConfirmation(
            title: "Run \(request.name)",
            prompt: "You're about to let me run your project's \(request.name) command. It's your code; whatever it does is on it. Do it or chicken out?",
            detail: "Action: Run a project command\nWorkspace: \(request.workspace.root)\nCommand: \(request.command)\nTime limit: \(Int(Self.timeout / 60)) minutes")
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try resolve(arguments)
        do {
            let result = try await shell.execute(command: Self.shellLine(request.command, in: request.workspace.root), timeout: Self.timeout)
            let output = result.stdout + (result.stderr.isEmpty ? "" : "\n" + result.stderr)
            let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
            let tail = lines.suffix(Self.tailLines).joined(separator: "\n")
            let diagnostics = DiagnosticParser.parse(output)
            var text = "\(request.name) exited with status \(result.exitCode).\n"
            if !diagnostics.isEmpty {
                text += "Problems (\(diagnostics.count)):\n" + diagnostics.prefix(30).map { "- " + $0.summary }.joined(separator: "\n") + "\n"
            }
            text += "Output (last \(min(lines.count, Self.tailLines)) lines):\n" + tail
            let redacted = SecretRedactor.redact(text)
            let summary = "ran \(request.name): exit \(result.exitCode), \(diagnostics.count) problem(s)"
            return result.isSuccess ? .success(redacted, summary: summary) : ToolResult(output: redacted, isError: true)
        } catch {
            return .failure("\(request.name): \(error.localizedDescription)")
        }
    }
}

// MARK: - log_analyze

/// Turns build/test output (pasted text, or a log file in the workspace) into a list of file:line problems. Safe.
public final class LogAnalyzeTool: IvyTool, Sendable {
    public let name = "log_analyze"
    public let description = "Extracts errors and test failures (file, line, message) from build or test output: either text you pass, or a log file in the active workspace."
    public let group = ToolGroup.developer
    public let safetyClassification = ToolSafetyClassification.safe
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "text": ToolProperty(type: "STRING", description: "Build or test output to analyse."),
                "path": ToolProperty(type: "STRING", description: "Or: a log file inside the workspace."),
            ],
            required: nil))
    }

    private let scope: WorkspaceScope

    public init(scope: WorkspaceScope) {
        self.scope = scope
    }

    func source(_ arguments: [String: AnyCodable]) throws -> (text: String?, path: String?) {
        let args = ToolArguments(arguments)
        try args.allow(["text", "path"])
        let text = try args.optionalString("text", max: 500_000, multiline: true)
        let path: String?
        if args.raw["path"] != nil {
            let workspace = try scope.require()
            let absolute = try ToolValidation.validateFilePath(try args.string("path", max: ToolValidation.maxPathLength), allowedRoot: workspace.rootURL)
            guard workspace.contains(absolute) else { throw ToolError.invalidArgument("The log must be inside the workspace.") }
            path = absolute
        } else {
            path = nil
        }
        guard (text == nil) != (path == nil) else { throw ToolError.invalidArgument("Give exactly one of 'text' or 'path'.") }
        return (text, path)
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try source(arguments) }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try source(arguments)
        var text = request.text ?? ""
        if let path = request.path {
            guard let data = FileManager.default.contents(atPath: path) else { return .failure("That log file can't be read.") }
            text = String(decoding: data.suffix(2_000_000), as: UTF8.self)
        }
        let diagnostics = DiagnosticParser.parse(text)
        guard !diagnostics.isEmpty else { return .success("No errors or failures found in that output.") }
        return .success(SecretRedactor.redact(diagnostics.map(\.summary).joined(separator: "\n")),
                        summary: "found \(diagnostics.count) problem(s) in build output")
    }
}

// MARK: - github

/// GitHub through the user's own `gh` CLI (its login, its keyring; Ivy never handles a token). Listing and
/// viewing are safe; creating a draft PR and commenting are risky. There is no merge, close or delete.
public final class GitHubTool: IvyTool, Sendable {
    enum Action: String, CaseIterable { case list_prs, view_pr, list_issues, create_draft_pr, comment }

    public let name = "github"
    public let description = "Uses the GitHub CLI in the active workspace: list pull requests or issues, view a PR, open a DRAFT pull request for the current branch, or comment on a PR/issue. It cannot merge, close or delete anything."
    public let group = ToolGroup.developer
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "action": ToolProperty(type: "STRING", description: "One of: list_prs, view_pr, list_issues, create_draft_pr, comment."),
                "number": ToolProperty(type: "INTEGER", description: "For view_pr/comment: the PR or issue number."),
                "title": ToolProperty(type: "STRING", description: "For create_draft_pr: the PR title."),
                "body": ToolProperty(type: "STRING", description: "For create_draft_pr/comment: the text."),
                "base": ToolProperty(type: "STRING", description: "For create_draft_pr, optional: the base branch."),
            ],
            required: ["action"]))
    }

    private let scope: WorkspaceScope
    private let runner: CommandRunning
    private let ghPath: @Sendable () -> String?

    public init(scope: WorkspaceScope, runner: CommandRunning = SystemCommandRunner(),
                ghPath: @escaping @Sendable () -> String? = { SystemShellExecutor.lookupBinaryInPath("gh")?.path }) {
        self.scope = scope
        self.runner = runner
        self.ghPath = ghPath
    }

    func argv(_ arguments: [String: AnyCodable]) throws -> [String] {
        _ = try scope.require()
        let args = ToolArguments(arguments)
        func number() throws -> String {
            let n = try args.int("number")
            guard n > 0 else { throw ToolError.invalidArgument("'number' must be positive.") }
            return String(n)
        }
        switch try args.choice("action", Action.self) {
        case .list_prs:
            try args.allow(["action"])
            return ["pr", "list", "--limit", "20"]
        case .list_issues:
            try args.allow(["action"])
            return ["issue", "list", "--limit", "20"]
        case .view_pr:
            try args.allow(["action", "number"])
            return ["pr", "view", try number()]
        case .create_draft_pr:
            try args.allow(["action", "title", "body", "base"])
            var argv = ["pr", "create", "--draft", "--title", try args.string("title", max: 200), "--body", try args.string("body", max: 20_000, multiline: true)]
            if args.raw["base"] != nil { argv += ["--base", try GitTools.ref(args, "base")] }
            return argv
        case .comment:
            try args.allow(["action", "number", "body"])
            return ["pr", "comment", try number(), "--body", try args.string("body", max: 10_000, multiline: true)]
        }
    }

    public func classification(for arguments: [String: AnyCodable]) -> ToolSafetyClassification {
        guard let argv = try? argv(arguments) else { return .risky }
        return argv.contains("create") || argv.contains("comment") ? .risky : .safe
    }

    public func validate(arguments: [String: AnyCodable]) throws {
        let argv = try argv(arguments)
        for text in argv where SensitiveDataDetector.reason(text) != nil && (argv.contains("create") || argv.contains("comment")) {
            throw ToolError.invalidArgument("That text looks like it contains a secret; it won't be posted.")
        }
    }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        guard let argv = try? argv(arguments), let workspace = scope.current else { return nil }
        let creating = argv.contains("create")
        let body = argv.firstIndex(of: "--body").map { argv[$0 + 1] } ?? ""
        let shownBody = body.count > 400 ? String(body.prefix(400)) + "… [truncated]" : body
        let title = argv.firstIndex(of: "--title").map { argv[$0 + 1] }
        return ToolConfirmation(
            title: creating ? "Open Draft Pull Request" : "Comment on GitHub",
            prompt: creating
                ? "You're about to let me open a draft PR in your name. It's a draft, so the shame is limited. Do it or chicken out?"
                : "You're about to let me post a comment in your name. Everyone can read it. Do it or chicken out?",
            detail: "Action: \(creating ? "Create a draft pull request for the current branch" : "Post a comment")\nWorkspace: \(workspace.root)"
                + (title.map { "\nTitle: \($0)" } ?? "") + "\nText:\n\(shownBody)")
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let argv = try argv(arguments)
        let workspace = try scope.require()
        guard let gh = ghPath() else {
            return .failure("The GitHub CLI (gh) isn't installed. Install it (brew install gh) and run `gh auth login` once.")
        }
        do {
            let output = try await runner.run(gh, argv, in: workspace.rootURL, timeout: 60)
            return GitTools.result(output, empty: "Done.")
        } catch {
            return .failure("github: \(error.localizedDescription)")
        }
    }
}
