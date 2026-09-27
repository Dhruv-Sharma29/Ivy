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

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(error.localizedDescription)
        }

        let pid = process.processIdentifier
        final class TimeoutState: @unchecked Sendable {
            var timedOut = false
        }
        let timeoutState = TimeoutState()

        // Watchdog task to enforce timeout
        let timeoutNanos = UInt64(max(timeout, 0.001) * 1_000_000_000)
        let watchdogTask = Task {
            try? await Task.sleep(nanoseconds: timeoutNanos)
            if !Task.isCancelled && process.isRunning {
                timeoutState.timedOut = true
                process.terminate()
                // Grace period before force killing
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                if process.isRunning && pid > 0 {
                    kill(pid, SIGKILL)
                }
            }
        }

        // Read stdout and stderr concurrently to prevent pipe buffer deadlock
        async let stdoutTask = Task.detached {
            stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        }.value

        async let stderrTask = Task.detached {
            stderrPipe.fileHandleForReading.readDataToEndOfFile()
        }.value

        let (stdoutData, stderrData) = await (stdoutTask, stderrTask)
        process.waitUntilExit()

        watchdogTask.cancel()

        let duration = Date().timeIntervalSince(startTime)
        let stdoutString = String(decoding: stdoutData, as: UTF8.self)
        let stderrString = String(decoding: stderrData, as: UTF8.self)

        if timeoutState.timedOut {
            throw ShellError.timedOut(duration: timeout)
        }

        if process.terminationReason == .uncaughtSignal {
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
