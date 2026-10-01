import Foundation
import Combine
import os

/// A project folder the user added. Developer tools work inside the active one; `file_op` writes are confined to it.
public struct Workspace: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case swiftpm, xcode, node, python, rust, go
    }

    /// The command names the model may ask `project_run` for. The command *text* is never the model's.
    public static let commandNames = ["build", "test", "lint", "run"]

    public let id: UUID
    public var name: String
    /// Absolute, standardized path.
    public var root: String
    public var kinds: [Kind]
    /// "build" → "swift build". Detected, editable by the user only.
    public var commands: [String: String]

    public init(id: UUID = UUID(), name: String, root: String, kinds: [Kind] = [], commands: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.root = root
        self.kinds = kinds
        self.commands = commands
    }

    public var rootURL: URL { URL(fileURLWithPath: root, isDirectory: true) }

    /// True for the root itself and anything under it (after resolving symlinks).
    public func contains(_ path: String) -> Bool {
        let base = rootURL.standardized.resolvingSymlinksInPath().path
        let target = URL(fileURLWithPath: path).standardized.resolvingSymlinksInPath().path
        return target == base || target.hasPrefix(base + "/")
    }

    /// Looks at marker files in `root` and proposes kinds and commands. Reads names only, runs nothing.
    public static func detect(at root: URL, fileManager: FileManager = .default) -> Workspace {
        let path = root.standardized.path
        func has(_ name: String) -> Bool { fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(name)) }
        let entries = (try? fileManager.contentsOfDirectory(atPath: path)) ?? []

        var kinds: [Kind] = []
        var commands: [String: String] = [:]
        func propose(_ name: String, _ command: String) {
            if commands[name] == nil { commands[name] = command }
        }
        if has("Package.swift") {
            kinds.append(.swiftpm)
            propose("build", "swift build")
            propose("test", "swift test")
        }
        if entries.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            kinds.append(.xcode)
            propose("build", "xcodebuild build")
            propose("test", "xcodebuild test")
        }
        if has("package.json") {
            kinds.append(.node)
            let scripts = nodeScripts(at: (path as NSString).appendingPathComponent("package.json"))
            for name in ["build", "test", "lint"] where scripts.contains(name) { propose(name, "npm run \(name)") }
            if scripts.contains("start") { propose("run", "npm start") }
        }
        if has("pyproject.toml") || has("requirements.txt") || has("setup.py") {
            kinds.append(.python)
            propose("test", "python3 -m pytest")
        }
        if has("Cargo.toml") {
            kinds.append(.rust)
            propose("build", "cargo build")
            propose("test", "cargo test")
            propose("lint", "cargo clippy")
            propose("run", "cargo run")
        }
        if has("go.mod") {
            kinds.append(.go)
            propose("build", "go build ./...")
            propose("test", "go test ./...")
            propose("lint", "go vet ./...")
        }
        return Workspace(name: root.lastPathComponent, root: path, kinds: kinds, commands: commands)
    }

    static func nodeScripts(at path: String) -> Set<String> {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any] else { return [] }
        return Set(scripts.keys)
    }
}

/// The active workspace as the tools see it (read off the main actor, so lock-backed).
public final class WorkspaceScope: Sendable {
    private let active = OSAllocatedUnfairLock<Workspace?>(initialState: nil)

    public init(_ workspace: Workspace? = nil) {
        active.withLock { $0 = workspace }
    }

    public var current: Workspace? { active.withLock { $0 } }

    public func set(_ workspace: Workspace?) {
        active.withLock { $0 = workspace }
    }

    /// The active workspace, or an error telling the model (and user) to pick one.
    public func require() throws -> Workspace {
        guard let workspace = current else {
            throw ToolError.invalidArgument("No workspace is active. The user can add and pick one from Ivy's window (Workspace menu).")
        }
        return workspace
    }
}

public protocol WorkspaceStore: Sendable {
    func load() -> (workspaces: [Workspace], activeID: UUID?)
    func save(workspaces: [Workspace], activeID: UUID?) throws
}

/// `Application Support/Ivy/workspaces.json` (0600). Ivy isn't sandboxed, so plain paths are enough; no
/// security-scoped bookmarks are needed.
public struct FileWorkspaceStore: WorkspaceStore {
    private struct Saved: Codable {
        var workspaces: [Workspace]
        var activeID: UUID?
    }

    public let fileURL: URL

    public init(fileURL: URL = FileConversationStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("workspaces.json")) {
        self.fileURL = fileURL
    }

    public func load() -> (workspaces: [Workspace], activeID: UUID?) {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return ([], nil) }
        return (saved.workspaces, saved.activeID)
    }

    public func save(workspaces: [Workspace], activeID: UUID?) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(Saved(workspaces: workspaces, activeID: activeID)).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

public final class InMemoryWorkspaceStore: WorkspaceStore, Sendable {
    private let state = OSAllocatedUnfairLock<([Workspace], UUID?)>(initialState: ([], nil))
    public init() {}
    public func load() -> (workspaces: [Workspace], activeID: UUID?) { state.withLock { ($0.0, $0.1) } }
    public func save(workspaces: [Workspace], activeID: UUID?) throws { state.withLock { $0 = (workspaces, activeID) } }
}

/// The user's workspaces for the UI, and the short project context added to Ivy's prompt.
@MainActor
public final class WorkspaceModel: ObservableObject {
    @Published public private(set) var workspaces: [Workspace] = []
    @Published public private(set) var activeID: UUID?
    /// "Workspace Ivy (swiftpm) at ~/Coding/Ivy, branch main, 3 changed files…" — refreshed on demand.
    @Published public private(set) var context: String?
    @Published public private(set) var lastError: String?

    public let scope: WorkspaceScope
    private let store: WorkspaceStore
    private let git: CommandRunning

    public init(store: WorkspaceStore, scope: WorkspaceScope, git: CommandRunning = SystemCommandRunner()) {
        self.store = store
        self.scope = scope
        self.git = git
        let saved = store.load()
        workspaces = saved.workspaces
        activeID = saved.activeID.flatMap { id in saved.workspaces.contains { $0.id == id } ? id : nil }
        scope.set(active)
    }

    public var active: Workspace? { workspaces.first { $0.id == activeID } }

    /// Adds a folder the user picked (open panel). Refuses system and credential locations like `file_op` does.
    @discardableResult
    public func add(folder: URL) -> Workspace? {
        do {
            let path = try ToolValidation.validateFilePath(folder.path)
            if let existing = workspaces.first(where: { $0.root == path }) {
                activate(existing.id)
                return existing
            }
            let workspace = Workspace.detect(at: URL(fileURLWithPath: path, isDirectory: true))
            workspaces.append(workspace)
            activate(workspace.id)
            return workspace
        } catch {
            lastError = "That folder can't be a workspace: \(error.localizedDescription)"
            return nil
        }
    }

    public func activate(_ id: UUID?) {
        activeID = id.flatMap { id in workspaces.contains { $0.id == id } ? id : nil }
        scope.set(active)
        context = nil
        save()
        Task { await refreshContext() }
    }

    public func remove(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        if activeID == id { activate(nil) } else { save() }
    }

    /// Sets (or clears, with an empty string) a project command. Only the user edits these.
    public func setCommand(_ name: String, to command: String, in id: UUID) {
        guard Workspace.commandNames.contains(name), let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        workspaces[index].commands[name] = trimmed.isEmpty ? nil : trimmed
        if activeID == id { scope.set(workspaces[index]) }
        save()
    }

    /// Cheap git facts for the prompt: branch and number of changed files. Never file contents.
    public func refreshContext() async {
        guard let workspace = active else {
            context = nil
            return
        }
        var line = "Active workspace: \(workspace.name) at \(workspace.root)"
        if !workspace.kinds.isEmpty { line += " (\(workspace.kinds.map(\.rawValue).joined(separator: ", ")))" }
        if !workspace.commands.isEmpty {
            line += ". Project commands for project_run: " + workspace.commands.keys.sorted().joined(separator: ", ")
        }
        if let branch = try? await git.run(GitTools.gitPath, ["rev-parse", "--abbrev-ref", "HEAD"], in: workspace.rootURL, timeout: 5),
           branch.exitCode == 0 {
            line += ". Git branch: \(branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"
            if let status = try? await git.run(GitTools.gitPath, ["status", "--porcelain"], in: workspace.rootURL, timeout: 5) {
                let changed = status.stdout.split(separator: "\n").count
                line += ", \(changed) changed file\(changed == 1 ? "" : "s")"
            }
        }
        guard activeID == workspace.id else { return }
        context = SecretRedactor.redact(line) + "."
    }

    public func dismissError() {
        lastError = nil
    }

    private func save() {
        do {
            try store.save(workspaces: workspaces, activeID: activeID)
        } catch {
            lastError = "Workspaces couldn't be saved: \(error.localizedDescription)"
        }
    }
}
