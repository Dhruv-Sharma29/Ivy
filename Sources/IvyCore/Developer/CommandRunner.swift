import Foundation

public struct CommandOutput: Equatable, Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String = "", exitCode: Int32 = 0) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }

    /// stdout, then stderr, for results the model reads.
    public var combined: String {
        [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Runs a fixed executable with an argument vector in a directory. No shell is involved, so nothing in an
/// argument is ever interpreted.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], in directory: URL, timeout: TimeInterval) async throws -> CommandOutput
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], in directory: URL, timeout: TimeInterval) async throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = SystemShellExecutor.sanitizeEnvironment(ProcessInfo.processInfo.environment)
        // Never wait for a username/password prompt nobody can see.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_ASKPASS"] = "/usr/bin/false"
        environment["GH_PROMPT_DISABLED"] = "1"
        // A socket path, not a secret (the sanitizer drops it for its "AUTH"): git over SSH needs the user's agent.
        if let agent = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { environment["SSH_AUTH_SOCK"] = agent }
        environment["GIT_PAGER"] = "cat"
        environment["PAGER"] = "cat"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let collector = ShellOutputCollector(limit: SystemShellExecutor.maxCollectedBytes)
        out.fileHandleForReading.readabilityHandler = { collector.receive($0.availableData, stderr: false) }
        err.fileHandleForReading.readabilityHandler = { collector.receive($0.availableData, stderr: true) }
        defer {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }
        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(error.localizedDescription)
        }
        let exited = await SystemShellExecutor.poll(timeout: timeout) { !process.isRunning }
        let cancelled = Task.isCancelled && process.isRunning
        if !exited || cancelled {
            await SystemShellExecutor.terminateTree(rootedAt: process.processIdentifier)
            throw cancelled ? ShellError.cancelled : ShellError.timedOut(duration: timeout)
        }
        _ = await SystemShellExecutor.poll(timeout: SystemShellExecutor.outputGrace) { collector.isComplete }
        let (stdout, stderr) = collector.snapshot()
        return CommandOutput(stdout: String(decoding: stdout, as: UTF8.self), stderr: String(decoding: stderr, as: UTF8.self),
                             exitCode: process.terminationStatus)
    }
}
