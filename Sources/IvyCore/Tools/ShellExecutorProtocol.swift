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
        return lines.joined(separator: "\n")
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

    public func execute(command: String, timeout: TimeInterval? = nil) async throws -> ShellCommandResult {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ShellError.emptyCommand
        }

        let effectiveTimeout = timeout ?? defaultCommandTimeout

        // Determine execution strategy:
        // If the command contains shell control operators (pipes, redirects, chaining),
        // we invoke /bin/zsh with discrete argv arguments ["-c", trimmed].
        // The command is passed as an isolated argv parameter without string interpolation into a template.
        // Otherwise, if simple, we tokenize and launch the binary directly.
        let shellMetacharacters = CharacterSet(charactersIn: "|&;><*?$`\\~()[]{}")
        let needsShell = trimmed.rangeOfCharacter(from: shellMetacharacters) != nil || trimmed.contains(" ")

        let executableURL: URL
        let arguments: [String]

        if needsShell {
            executableURL = URL(fileURLWithPath: "/bin/zsh")
            // Crucial: trimmed is passed as an isolated argument string to -c,
            // NOT interpolated into any command line format string.
            arguments = ["-c", trimmed]
        } else {
            // Direct execution of single command without shell invocation
            let tokens = trimmed.split(separator: " ").map(String.init)
            guard let binaryName = tokens.first, !binaryName.isEmpty else {
                throw ShellError.emptyCommand
            }

            if binaryName.hasPrefix("/") {
                executableURL = URL(fileURLWithPath: binaryName)
            } else {
                guard let found = Self.lookupBinaryInPath(binaryName) else {
                    throw ShellError.commandNotFound(binaryName)
                }
                executableURL = found
            }
            arguments = Array(tokens.dropFirst())
        }

        return try await runProcess(
            executableURL: executableURL,
            arguments: arguments,
            rawCommand: trimmed,
            timeout: effectiveTimeout
        )
    }

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

        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANG"] = "en_US.UTF-8"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(error.localizedDescription)
        }

        // Watchdog task to enforce timeout
        let timeoutNanos = UInt64(max(timeout, 0.001) * 1_000_000_000)
        let watchdogTask = Task {
            try? await Task.sleep(nanoseconds: timeoutNanos)
            if process.isRunning {
                process.terminate()
            }
        }

        // Read output asynchronously and await process exit
        let (stdoutData, stderrData) = await Task.detached {
            let out = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let err = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (out, err)
        }.value

        watchdogTask.cancel()

        let duration = Date().timeIntervalSince(startTime)
        let stdoutString = String(decoding: stdoutData, as: UTF8.self)
        let stderrString = String(decoding: stderrData, as: UTF8.self)

        if process.terminationReason == .uncaughtSignal {
            if duration >= timeout {
                throw ShellError.timedOut(duration: timeout)
            }
            throw ShellError.terminatedBySignal(process.terminationStatus)
        }

        return ShellCommandResult(
            command: rawCommand,
            stdout: stdoutString,
            stderr: stderrString,
            exitCode: process.terminationStatus,
            duration: duration
        )
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
