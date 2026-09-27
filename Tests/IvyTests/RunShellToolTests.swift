import Testing
import Foundation
@testable import IvyCore

/// In-memory mock implementation of ShellExecutorProtocol for safe unit testing.
/// Strictly guarantees zero real shell execution occurs during testing.
final class MockShellExecutor: ShellExecutorProtocol, @unchecked Sendable {
    struct RecordedCommand: Equatable, Sendable {
        let command: String
        let timeout: TimeInterval?
    }

    var recordedCommands: [RecordedCommand] = []
    var resultToReturn: ShellCommandResult?
    var errorToThrow: (any Error)?

    func execute(command: String, timeout: TimeInterval?) async throws -> ShellCommandResult {
        recordedCommands.append(RecordedCommand(command: command, timeout: timeout))
        if let errorToThrow {
            throw errorToThrow
        }
        if let resultToReturn {
            return resultToReturn
        }
        return ShellCommandResult(
            command: command,
            stdout: "mock output",
            stderr: "",
            exitCode: 0,
            duration: 0.02
        )
    }
}

@Suite("RunShellTool Argument & Model Tests")
struct RunShellToolArgumentTests {
    @Test("Valid shell command validates successfully")
    func testValidCommandValidation() throws {
        let cmd = try ToolValidation.validateShellCommand("git status")
        #expect(cmd == "git status")

        let args: [String: AnyCodable] = ["command": AnyCodable("ls -la /tmp")]
        let parsed = try ToolValidation.validateShellArguments(args)
        #expect(parsed == "ls -la /tmp")
    }

    @Test("Empty or whitespace-only command throws invalidArgument")
    func testEmptyCommandThrows() {
        #expect(throws: ToolError.self) {
            try ToolValidation.validateShellCommand("")
        }
        #expect(throws: ToolError.self) {
            try ToolValidation.validateShellCommand("   \n\t  ")
        }
        #expect(throws: ToolError.self) {
            try ToolValidation.validateShellArguments(["command": AnyCodable("   ")])
        }
    }

    @Test("Missing command argument throws missingArgument")
    func testMissingCommandThrows() {
        #expect(throws: ToolError.self) {
            try ToolValidation.validateShellArguments([:])
        }
    }

    @Test("Non-string command argument throws invalidArgument")
    func testNonStringCommandThrows() {
        #expect(throws: ToolError.self) {
            try ToolValidation.validateShellArguments(["command": AnyCodable(12345)])
        }
        #expect(throws: ToolError.self) {
            try ToolValidation.validateShellArguments(["command": AnyCodable(true)])
        }
    }

    @Test("Null byte in shell command throws invalidArgument")
    func testNullByteInCommandThrows() {
        #expect(throws: ToolError.self) {
            try ToolValidation.validateShellCommand("echo hello\0world")
        }
    }

    @Test("Command exceeding maximum length throws invalidArgument")
    func testCommandExceedingMaxLengthThrows() {
        let hugeCommand = "echo " + String(repeating: "x", count: ToolValidation.maxShellCommandLength + 10)
        #expect(throws: ToolError.self) {
            try ToolValidation.validateShellCommand(hugeCommand)
        }
    }

    @Test("Unexpected arguments outside schema throw invalidArgument")
    func testUnexpectedArgumentsThrow() {
        #expect(throws: ToolError.self) {
            try ToolValidation.validateShellArguments([
                "command": AnyCodable("whoami"),
                "timeout": AnyCodable(60)
            ])
        }
        #expect(throws: ToolError.self) {
            try ToolValidation.validateShellArguments([
                "command": AnyCodable("whoami"),
                "sudo": AnyCodable(true)
            ])
        }
    }

    @Test("ShellCommandResult formatting correctly formats stdout, stderr, and exit codes")
    func testResultFormatting() {
        // Success with stdout
        let res1 = ShellCommandResult(command: "echo hi", stdout: "hi\n", stderr: "", exitCode: 0)
        #expect(res1.formattedOutput == "hi")
        #expect(res1.isSuccess == true)

        // Success with empty output
        let res2 = ShellCommandResult(command: "true", stdout: "", stderr: "", exitCode: 0)
        #expect(res2.formattedOutput.contains("executed successfully with no output"))

        // Error with stderr only
        let res3 = ShellCommandResult(command: "cat missing", stdout: "", stderr: "No such file", exitCode: 1)
        #expect(res3.formattedOutput == "No such file")
        #expect(res3.isSuccess == false)

        // Stderr and stdout both present
        let res4 = ShellCommandResult(command: "build", stdout: "Compiling...", stderr: "Warning: unused", exitCode: 0)
        #expect(res4.formattedOutput.contains("Compiling..."))
        #expect(res4.formattedOutput.contains("[stderr]:\nWarning: unused"))

        // Failure with empty output
        let res5 = ShellCommandResult(command: "false", stdout: "", stderr: "", exitCode: 1)
        #expect(res5.formattedOutput.contains("failed with exit code: 1"))
    }

    @Test("ShellError descriptions are informative and non-empty")
    func testShellErrorDescriptions() {
        let errors: [ShellError] = [
            .emptyCommand,
            .commandNotFound("nonexistent_binary"),
            .launchFailed("posix_spawn failed"),
            .timedOut(duration: 30.0),
            .terminatedBySignal(9),
            .executionFailed(exitCode: 127, stderr: "not found")
        ]

        for err in errors {
            #expect(err.errorDescription?.isEmpty == false)
        }
    }
}
