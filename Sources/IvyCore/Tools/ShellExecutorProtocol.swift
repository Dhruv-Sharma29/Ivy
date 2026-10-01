import os
import Foundation

/// Structured outcome of a shell command execution.
public struct ShellCommandResult: Sendable, Equatable {
    public let command: String
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let duration: TimeInterval

    public var isSuccess: Bool {
        exitCode == 0
    }

    public init(
        command: String,
        stdout: String = "",
        stderr: String = "",
        exitCode: Int32 = 0,
        duration: TimeInterval = 0
    ) {
        self.command = command
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
        self.duration = duration
    }

    /// Maximum formatted output length permitted in ToolResult (256 KB).
    public static let maxOutputLength: Int = 262_144

    /// Human-readable combined output suitable for ToolResult.
    public var formattedOutput: String {
        var lines: [String] = []
        let trimmedStdout = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        if !trimmedStdout.isEmpty {
            lines.append(trimmedStdout)
        }
        if !trimmedStderr.isEmpty {
            if lines.isEmpty {
                lines.append(trimmedStderr)
            } else {
                lines.append("[stderr]:\n\(trimmedStderr)")
            }
        }
        if lines.isEmpty {
            if isSuccess {
                return "(Command executed successfully with no output, exit code: 0)"
            } else {
                return "(Command failed with exit code: \(exitCode) and no output)"
            }
        }
        let full = lines.joined(separator: "\n")
        if full.count > Self.maxOutputLength {
            let index = full.index(full.startIndex, offsetBy: Self.maxOutputLength)
            return String(full[..<index]) + "\n... [Output truncated to \(Self.maxOutputLength / 1024) KB]"
        }
        return full
    }
}

/// Errors that can occur during shell command preparation or execution.
public enum ShellError: Error, LocalizedError, Equatable, Sendable {
    case emptyCommand
    case commandNotFound(String)
    case launchFailed(String)
    case timedOut(duration: TimeInterval)
    case terminatedBySignal(Int32)
    case executionFailed(exitCode: Int32, stderr: String)
    /// Stopped by the user (the command and its children were killed).
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .emptyCommand:
            return "Command cannot be empty."
        case .commandNotFound(let cmd):
            return "Command or executable not found: '\(cmd)'"
        case .launchFailed(let msg):
            return "Failed to launch process: \(msg)"
        case .timedOut(let duration):
            return "Command timed out after \(String(format: "%.1f", duration)) seconds."
        case .terminatedBySignal(let sig):
            return "Process was terminated by signal: \(sig)."
        case .cancelled:
            return "Stopped: the command and everything it started were ended."
        case .executionFailed(let code, let err):
            if err.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Command exited with non-zero status code: \(code)."
            }
            return "Command failed (exit code \(code)): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

/// Abstraction for executing shell commands.
/// Allows mock-based testing without executing real commands during tests.
public protocol ShellExecutorProtocol: Sendable {
    /// Executes a shell command and returns the structured result.
    /// - Parameters:
    ///   - command: The raw command string to execute.
    ///   - timeout: Maximum duration in seconds allowed before termination. Defaults to 30s.
    func execute(command: String, timeout: TimeInterval?) async throws -> ShellCommandResult
}

public extension ShellExecutorProtocol {
    func execute(command: String) async throws -> ShellCommandResult {
        try await execute(command: command, timeout: nil)
    }
}

/// Production implementation of ShellExecutorProtocol using Foundation.Process.
public final class SystemShellExecutor: ShellExecutorProtocol, Sendable {
    public static let defaultTimeout: TimeInterval = 30.0
    public let defaultCommandTimeout: TimeInterval

    public init(defaultCommandTimeout: TimeInterval = defaultTimeout) {
        self.defaultCommandTimeout = defaultCommandTimeout
    }

    /// Sanitizes the environment variables passed to child shell processes,
    /// removing sensitive secrets, credentials, tokens, and API keys.
    public static func sanitizeEnvironment(_ rawEnv: [String: String]) -> [String: String] {
        let sensitiveKeywords = [
            "API_KEY",
            "SECRET",
            "TOKEN",
            "PASSWORD",
            "PASSWD",
            "CREDENTIAL",
            "AUTH",
            "PRIVATE",
            "BEARER"
        ]

        var cleanEnv = rawEnv.filter { key, _ in
            let upperKey = key.uppercased()
            return !sensitiveKeywords.contains { upperKey.contains($0) }
        }

        // Augment PATH with standard macOS binary paths if missing
        let standardPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let currentPath = cleanEnv["PATH"] ?? ""
        var pathComponents = currentPath.split(separator: ":").map(String.init)
        for stdPath in standardPaths {
            if !pathComponents.contains(stdPath) {
                pathComponents.append(stdPath)
            }
        }
        cleanEnv["PATH"] = pathComponents.joined(separator: ":")

        // Ensure standard locale variables
        cleanEnv["LC_ALL"] = "en_US.UTF-8"
        cleanEnv["LANG"] = "en_US.UTF-8"
        return cleanEnv
    }

    public func execute(command: String, timeout: TimeInterval? = nil) async throws -> ShellCommandResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShellError.emptyCommand
        }

        let effectiveTimeout = timeout ?? defaultCommandTimeout

        // Execute via /bin/zsh -c with discrete argument vector.
        // The command is passed as an isolated argv parameter without string interpolation into a template.
        let executableURL = URL(fileURLWithPath: "/bin/zsh")
        let arguments = ["-c", trimmed]

        return try await runProcess(
            executableURL: executableURL,
            arguments: arguments,
            rawCommand: trimmed,
            timeout: effectiveTimeout
        )
    }

    /// How long output is still collected after the shell exits. A background child (`cmd &`) can keep the pipes
    /// open indefinitely; after this grace Ivy stops listening instead of hanging.
    static let outputGrace: TimeInterval = 1.0
    /// Per-stream ceiling on collected bytes; the rest is drained and dropped (the result is cut far below this).
    static let maxCollectedBytes = 1_048_576

    private func runProcess(
        executableURL: URL,
        arguments: [String],
        rawCommand: String,
        timeout: TimeInterval
    ) async throws -> ShellCommandResult {
        let startTime = Date()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        // Sanitize environment to prevent API key and secret leakage
        process.environment = Self.sanitizeEnvironment(ProcessInfo.processInfo.environment)

        // Connect null device to standardInput so child processes receive immediate EOF if they attempt to read
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Collected as it arrives (never a blocking read): a pipe held open by a grandchild can't stall Ivy.
        let output = ShellOutputCollector(limit: Self.maxCollectedBytes)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            output.receive(handle.availableData, stderr: false)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            output.receive(handle.availableData, stderr: true)
        }
        let stopListening = {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }

        do {
            try process.run()
        } catch {
            stopListening()
            throw ShellError.launchFailed(error.localizedDescription)
        }
        let pid = process.processIdentifier

        let exitedInTime = await Self.poll(timeout: timeout) { !process.isRunning }
        // Stop (an agent task, or the user) cancels the calling task: the command is killed like a timeout.
        let cancelled = Task.isCancelled && process.isRunning
        if !exitedInTime || cancelled {
            // The whole tree, not just zsh: children would otherwise keep running and keep the pipes open.
            await Self.terminateTree(rootedAt: pid)
            _ = await Self.poll(timeout: 2) { !process.isRunning }
        }
        let outputComplete = await Self.poll(timeout: exitedInTime ? Self.outputGrace : 0.5) { output.isComplete }
        stopListening()

        let duration = Date().timeIntervalSince(startTime)
        if cancelled {
            throw ShellError.cancelled
        }
        if !exitedInTime {
            throw ShellError.timedOut(duration: timeout)
        }
        if process.terminationReason == .uncaughtSignal {
            throw ShellError.terminatedBySignal(process.terminationStatus)
        }

        let (stdoutData, stderrData) = output.snapshot()
        var stdoutString = String(decoding: stdoutData, as: UTF8.self)
        if !outputComplete {
            stdoutString += "\n[A background process is still running; its later output is not captured.]"
        }
        return ShellCommandResult(
            command: rawCommand,
            stdout: stdoutString,
            stderr: String(decoding: stderrData, as: UTF8.self),
            exitCode: process.terminationStatus,
            duration: duration
        )
    }

    /// Re-checks `condition` every 20 ms until it holds (true), `timeout` passes, or the task is cancelled (false).
    static func poll(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline || Task.isCancelled { return condition() }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    /// SIGTERM to the process and every descendant (found before anything dies, while the tree is still
    /// linked), then SIGKILL to whatever is left after a short grace.
    static func terminateTree(rootedAt root: pid_t) async {
        guard root > 0 else { return }
        let tree = descendants(of: root) + [root]
        for pid in tree { kill(pid, SIGTERM) }
        _ = await poll(timeout: 0.5) { tree.allSatisfy { kill($0, 0) != 0 } }
        for pid in tree where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Children, grandchildren, … of `root`, via libproc (no shell, no `ps`).
    static func descendants(of root: pid_t) -> [pid_t] {
        var found: [pid_t] = []
        var queue: [pid_t] = [root]
        while let parent = queue.popLast() {
            let capacity = 512
            var pids = [pid_t](repeating: 0, count: capacity)
            let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent), &pids, Int32(capacity * MemoryLayout<pid_t>.stride))
            guard bytes > 0 else { continue }
            for child in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride) where child > 0 && !found.contains(child) {
                found.append(child)
                queue.append(child)
            }
        }
        return found
    }

    /// Searches standard macOS PATH locations for the given executable name.
    public static func lookupBinaryInPath(_ name: String) -> URL? {
        let fm = FileManager.default
        let searchPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        for dir in searchPaths {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}

/// Thread-safe sink for a child process's stdout/stderr, fed from pipe readability handlers.
final class ShellOutputCollector: Sendable {
    private struct State {
        var stdout = Data()
        var stderr = Data()
        var stdoutClosed = false
        var stderrClosed = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    /// Empty data means end of file on that stream.
    func receive(_ data: Data, stderr: Bool) {
        state.withLock { s in
            if data.isEmpty {
                if stderr { s.stderrClosed = true } else { s.stdoutClosed = true }
                return
            }
            if stderr {
                if s.stderr.count < limit { s.stderr.append(data.prefix(limit - s.stderr.count)) }
            } else {
                if s.stdout.count < limit { s.stdout.append(data.prefix(limit - s.stdout.count)) }
            }
        }
    }

    var isComplete: Bool {
        state.withLock { $0.stdoutClosed && $0.stderrClosed }
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        state.withLock { ($0.stdout, $0.stderr) }
    }
}
