import Testing
import Foundation
@testable import IvyCore

final class TestConfirmationProvider: ConfirmationProvider, @unchecked Sendable {
    var requestedConfirmation: ConfirmationRequest?
    var decisionToReturn: Bool = true
    var callCount: Int = 0

    init(decisionToReturn: Bool = true) {
        self.decisionToReturn = decisionToReturn
    }

    func requestConfirmation(for request: ConfirmationRequest) async -> Bool {
        callCount += 1
        requestedConfirmation = request
        return decisionToReturn
    }
}

@Suite("SafetyGate and Confirmation Tests")
struct SafetyGateTests {

    private struct MockSafeTool: IvyTool {
        let name = "mock_safe"
        let description = "Safe test tool"
        let declaration = FunctionDeclaration(name: "mock_safe", description: "Safe")
        var safetyClassification: ToolSafetyClassification { .safe }

        func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
            .success("Safe output")
        }
    }

    private struct MockRiskyTool: IvyTool {
        let name = "mock_risky"
        let description = "Risky test tool"
        let declaration = FunctionDeclaration(name: "mock_risky", description: "Risky")
        var safetyClassification: ToolSafetyClassification { .risky }

        func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
            .success("Risky output")
        }
    }

    @Test("Safe tools are auto-approved without invoking ConfirmationProvider")
    func testSafeToolAutoApproved() async {
        let provider = TestConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let tool = MockSafeTool()
        let call = FunctionCall(name: "mock_safe", args: [:])

        let decision = await gate.evaluate(tool: tool, call: call)

        #expect(decision == .approve)
        #expect(provider.callCount == 0)
    }

    @Test("Risky tools invoke ConfirmationProvider and approve when user accepts")
    func testRiskyToolApprovedByUser() async {
        let provider = TestConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let tool = MockRiskyTool()
        let call = FunctionCall(name: "mock_risky", args: ["action": "nuke"])

        let decision = await gate.evaluate(tool: tool, call: call)

        #expect(decision == .approve)
        #expect(provider.callCount == 1)
        #expect(provider.requestedConfirmation?.toolName == "mock_risky")
        #expect(provider.requestedConfirmation?.prompt.contains("don't blame me") == true)
    }

    @Test("Risky tools invoke ConfirmationProvider and return safe cancellation error when user rejects")
    func testRiskyToolCancelledByUser() async {
        let provider = TestConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let tool = MockRiskyTool()
        let call = FunctionCall(name: "mock_risky", args: [:])

        let decision = await gate.evaluate(tool: tool, call: call)

        #expect(decision == .reject(reason: "User cancelled operation with prejudice."))
        #expect(provider.callCount == 1)
    }

    @Test("RunAppleScriptTool confirmation request displays script in detail and Ivy persona prompt")
    func testRunAppleScriptConfirmationRequest() async {
        let provider = TestConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let tool = RunAppleScriptTool(executor: MockAppleScriptExecutor())
        let script = "tell application \"Finder\" to empty trash"
        let call = FunctionCall(name: "run_applescript", args: ["script": AnyCodable(script)])

        let decision = await gate.evaluate(tool: tool, call: call)

        #expect(decision == .approve)
        #expect(provider.requestedConfirmation?.toolName == "run_applescript")
        #expect(provider.requestedConfirmation?.title == "AppleScript Execution")
        #expect(provider.requestedConfirmation?.detail == script)
        #expect(provider.requestedConfirmation?.prompt == "You're about to run an AppleScript. If you regret this, don't blame me. Do it or chicken out?")
    }

    @Test("Gemini model cannot bypass SafetyGate on risky tools")
    func testGeminiCannotBypassSafetyGate() async {
        let provider = TestConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let tool = RunAppleScriptTool(executor: MockAppleScriptExecutor())
        let call = FunctionCall(name: "run_applescript", args: [
            "script": "return 1",
            "safetyClassification": "safe",
            "bypass": true
        ])

        let decision = await gate.evaluate(tool: tool, call: call)
        #expect(decision == .reject(reason: "User cancelled operation with prejudice."))
    }
}
