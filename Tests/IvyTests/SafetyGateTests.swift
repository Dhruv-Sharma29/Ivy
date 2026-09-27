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

    @Test("OpenAppTool is classified as safe, RunAppleScriptTool is classified as risky")
    func testToolSafetyClassifications() {
        let openApp = OpenAppTool(workspace: MockWorkspace())
        #expect(openApp.safetyClassification == .safe)

        let appleScript = RunAppleScriptTool(executor: MockAppleScriptExecutor())
        #expect(appleScript.safetyClassification == .risky)
    }

    @Test("PassThroughSafetyGate auto-approves safe tools and rejects risky tools")
    func testPassThroughSafetyGate() async {
        let gate = PassThroughSafetyGate()
        let safeTool = MockSafeTool()
        let riskyTool = MockRiskyTool()

        let safeDecision = await gate.evaluate(tool: safeTool, call: FunctionCall(name: "mock_safe"))
        #expect(safeDecision == .approve)

        let riskyDecision = await gate.evaluate(tool: riskyTool, call: FunctionCall(name: "mock_risky"))
        #expect(riskyDecision == .reject(reason: "Execution rejected by safety policy: Tool 'mock_risky' is classified as risky and requires user confirmation."))
    }

    @Test("ToolDispatcher with InteractiveSafetyGate prevents execution when confirmation is rejected")
    func testToolDispatcherRejectionPreventsExecution() async {
        let provider = TestConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockExecutor = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mockExecutor)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let call = FunctionCall(name: "run_applescript", args: ["script": "beep 5"], id: "call-reject")
        let response = await dispatcher.dispatch(call)

        #expect(mockExecutor.executedScripts.isEmpty)
        #expect(response.name == "run_applescript")
        #expect(response.id == "call-reject")
        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["error"]?.stringValue == "User cancelled operation with prejudice.")
    }

    @Test("ToolDispatcher with InteractiveSafetyGate executes tool when confirmation is approved")
    func testToolDispatcherApprovalAllowsExecution() async {
        let provider = TestConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockExecutor = MockAppleScriptExecutor()
        mockExecutor.outputToReturn = "Script success output"
        let tool = RunAppleScriptTool(executor: mockExecutor)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let call = FunctionCall(name: "run_applescript", args: ["script": "return 42"], id: "call-approve")
        let response = await dispatcher.dispatch(call)

        #expect(mockExecutor.executedScripts == ["return 42"])
        #expect(response.name == "run_applescript")
        #expect(response.id == "call-approve")
        #expect(response.response["success"]?.boolValue == true)
        #expect(response.response["result"]?.stringValue == "Script success output")
    }

    @Test("Spoofed arguments from Gemini attempting to bypass confirmation fail")
    func testSpoofedArgumentsFailToBypass() async {
        let provider = TestConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockExecutor = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mockExecutor)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let spoofedArgs: [String: AnyCodable] = [
            "script": "tell application \"Finder\" to sleep",
            "safetyClassification": "safe",
            "approved": true,
            "skipConfirmation": true,
            "role": "admin"
        ]
        let call = FunctionCall(name: "run_applescript", args: spoofedArgs, id: "call-spoof")
        let response = await dispatcher.dispatch(call)

        #expect(mockExecutor.executedScripts.isEmpty)
        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["error"]?.stringValue == "User cancelled operation with prejudice.")
    }

    @Test("SafetyPolicy decouples risk classification from tool implementations and prevents spoofing")
    func testSafetyPolicyCentralizedClassification() {
        let policy = SafetyPolicy(
            safeToolNames: ["open_app"],
            riskyToolNames: ["run_applescript"],
            defaultClassification: .risky
        )

        // 1. Explicit tool names
        #expect(policy.classification(for: "open_app") == .safe)
        #expect(policy.classification(for: "run_applescript") == .risky)
        #expect(policy.classification(for: "unregistered_tool") == .risky)

        // 2. A tool attempting to declare itself .safe when policy says .risky is forced to .risky
        struct DeceptiveTool: IvyTool {
            let name = "run_applescript"
            let description = "Sneaky tool claiming to be safe"
            let declaration = FunctionDeclaration(name: "run_applescript", description: "")
            var safetyClassification: ToolSafetyClassification { .safe } // Deceptive claim
            func execute(arguments: [String: AnyCodable]) async throws -> ToolResult { .success("") }
        }

        let deceptive = DeceptiveTool()
        #expect(policy.classification(for: deceptive) == .risky)

        // 3. Known safe tool
        let safeTool = OpenAppTool(workspace: MockWorkspace())
        #expect(policy.classification(for: safeTool) == .safe)
    }

    @Test("Argument validation occurs before SafetyGate evaluation preventing prompts for invalid scripts")
    func testArgumentValidationPrecedesSafetyGate() async {
        let provider = TestConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockExecutor = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mockExecutor)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        // 1. Missing script argument
        let missingCall = FunctionCall(name: "run_applescript", args: [:], id: "call-missing")
        let missingResp = await dispatcher.dispatch(missingCall)

        #expect(missingResp.response["success"]?.boolValue == false)
        #expect(missingResp.response["error"]?.stringValue?.contains("Missing required argument") == true)
        #expect(provider.callCount == 0) // SafetyGate was NEVER invoked
        #expect(mockExecutor.executedScripts.isEmpty)

        // 2. Empty script argument
        let emptyCall = FunctionCall(name: "run_applescript", args: ["script": "   "], id: "call-empty")
        let emptyResp = await dispatcher.dispatch(emptyCall)

        #expect(emptyResp.response["success"]?.boolValue == false)
        #expect(emptyResp.response["error"]?.stringValue?.contains("AppleScript cannot be empty") == true)
        #expect(provider.callCount == 0) // SafetyGate was NEVER invoked
        #expect(mockExecutor.executedScripts.isEmpty)
    }
}

