import Testing
import Foundation
@testable import IvyCore

final class MockAppleScriptExecutor: AppleScriptExecutorProtocol, @unchecked Sendable {
    var executedScripts: [String] = []
    var outputToReturn: String = "Mock output"
    var errorToThrow: Error?

    func execute(script: String) async throws -> String {
        executedScripts.append(script)
        if let error = errorToThrow {
            throw error
        }
        return outputToReturn
    }
}

@Suite("RunAppleScriptTool Tests")
struct RunAppleScriptToolTests {

    @Test("Declaration metadata and risky safety classification")
    func testToolDeclaration() {
        let tool = RunAppleScriptTool(executor: MockAppleScriptExecutor())
        #expect(tool.name == "run_applescript")
        #expect(tool.safetyClassification == .risky)
        #expect(tool.declaration.name == "run_applescript")
        #expect(tool.declaration.parameters?.properties["script"]?.type == "STRING")
        #expect(tool.declaration.parameters?.required == ["script"])
    }

    @Test("Successful execution returns output in ToolResult")
    func testSuccessfulExecution() async throws {
        let mock = MockAppleScriptExecutor()
        mock.outputToReturn = "Finder window 1"
        let tool = RunAppleScriptTool(executor: mock)

        let script = "tell application \"Finder\" to get name of window 1"
        let result = try await tool.execute(arguments: ["script": AnyCodable(script)])

        #expect(result.isError == false)
        #expect(result.output == "Finder window 1")
        #expect(mock.executedScripts == [script])
    }

    @Test("Whitespace surrounding script is trimmed")
    func testScriptWhitespaceTrimming() async throws {
        let mock = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mock)

        let scriptWithWhitespace = "   \n  beep 2 \n\t "
        let result = try await tool.execute(arguments: ["script": AnyCodable(scriptWithWhitespace)])

        #expect(result.isError == false)
        #expect(mock.executedScripts == ["beep 2"])
    }

    @Test("Throws missingArgument when script is not provided")
    func testMissingScriptArgument() async {
        let mock = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mock)

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: [:])
        }
    }

    @Test("Throws invalidArgument when script is of invalid type")
    func testInvalidTypeScriptArgument() async {
        let mock = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mock)

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["script": 12345])
        }

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["script": true])
        }

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["script": ["nested": "code"]])
        }

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["script": nil])
        }
    }

    @Test("Throws invalidArgument on empty or whitespace-only script")
    func testEmptyScriptValidation() async {
        let mock = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mock)

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["script": ""])
        }

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["script": "    \n\t  "])
        }
    }

    @Test("Throws invalidArgument on oversized script exceeding 64KB")
    func testOversizedScriptValidation() async {
        let mock = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mock)
        let oversized = String(repeating: "A", count: ToolValidation.maxScriptLength + 1)

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["script": AnyCodable(oversized)])
        }
    }

    @Test("Throws invalidArgument when script contains embedded null bytes")
    func testNullByteInScript() async {
        let mock = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mock)

        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["script": "beep\0evil"])
        }
    }

    @Test("Executor throwing error is captured as failure ToolResult")
    func testExecutorFailureHandledGracefully() async throws {
        let mock = MockAppleScriptExecutor()
        mock.errorToThrow = ToolError.executionFailed("Syntax error in AppleScript")
        let tool = RunAppleScriptTool(executor: mock)

        let result = try await tool.execute(arguments: ["script": "bad syntax"])
        #expect(result.isError == true)
        #expect(result.output.contains("Syntax error in AppleScript"))
    }

    @Test("SystemAppleScriptExecutor executes valid script or reports syntax error safely")
    func testSystemExecutorRealExecution() async {
        let executor = SystemAppleScriptExecutor()

        // 1. Valid AppleScript arithmetic
        do {
            let output = try await executor.execute(script: "return 2 + 2")
            #expect(output == "4")
        } catch {
            Issue.record("Valid script should not fail: \(error)")
        }

        // 2. Syntax error should throw a safe executionFailed error rather than crashing
        do {
            _ = try await executor.execute(script: "tell unknown app without end tell")
            Issue.record("Invalid script should throw")
        } catch {
            #expect(error is ToolError)
        }
    }
}
