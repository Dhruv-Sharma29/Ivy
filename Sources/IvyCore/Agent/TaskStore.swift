import Foundation
import os

/// Task history. Outputs are already redacted and clipped (`TaskStep.clip`) before they get here.
public protocol TaskStore: Sendable {
    func save(_ run: TaskRun) throws
    /// Newest first, at most `limit`.
    func recent(limit: Int) -> [TaskRun]
}

public extension TaskStore {
    func recent() -> [TaskRun] { recent(limit: 20) }
}

/// One JSON file per task in `Application Support/Ivy/Tasks` (0700 / 0600). Unreadable files are skipped.
public struct FileTaskStore: TaskStore {
    public let directory: URL

    public static var defaultDirectory: URL {
        FileConversationStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("Tasks", isDirectory: true)
    }

    public init(directory: URL = FileTaskStore.defaultDirectory) {
        self.directory = directory
    }

    public func save(_ run: TaskRun) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("\(run.id.uuidString).json")
        try JSONEncoder().encode(run).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func recent(limit: Int) -> [TaskRun] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let runs = names.filter { $0.hasSuffix(".json") }.compactMap { name -> TaskRun? in
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path) else { return nil }
            return try? JSONDecoder().decode(TaskRun.self, from: data)
        }
        return Array(runs.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
}

public final class InMemoryTaskStore: TaskStore, Sendable {
    private let runs = OSAllocatedUnfairLock(initialState: [UUID: TaskRun]())

    public init() {}

    public func save(_ run: TaskRun) throws { runs.withLock { $0[run.id] = run } }

    public func recent(limit: Int) -> [TaskRun] {
        Array(runs.withLock { Array($0.values) }.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }
}
