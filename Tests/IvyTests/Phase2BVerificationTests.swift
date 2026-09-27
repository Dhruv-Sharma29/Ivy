import Testing
import Foundation
@testable import IvyCore

// MARK: - Phase 2B SafetyGate Tests

@Suite("Phase 2B - SafetyGate Tests")
struct Phase2BSafetyGateTests {

    private struct CustomSafeTool: IvyTool {
        let name = "custom_read"
        let description = "Read-only custom tool"
        let declaration = FunctionDeclaration(name: "custom_read", description: "Read-only")
        var safetyClassification: ToolSafetyClassification { .safe }

        func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
            .success("Read content")
        }
    }

    private struct CustomRiskyTool: IvyTool {
        let name = "custom_delete"
        let description = "Destructive custom tool"
        let declaration = FunctionDeclaration(name: "custom_delete", description: "Destructive")
        var safetyClassification: ToolSafetyClassification { .risky }

        func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
            .success("Deleted")
        }
    }

    @Test("Safe tool classification: open_app and registered safe tools are classified as safe")
    func testSafeToolClassification() {
        let policy = SafetyPolicy(
            safeToolNames: ["open_app", "custom_read"],
            riskyToolNames: ["run_applescript"],
            defaultClassification: .risky
        )

        // 1. By name
        #expect(policy.classification(for: "open_app") == .safe)
        #expect(policy.classification(for: "custom_read") == .safe)

        // 2. By tool instance
        let openAppTool = OpenAppTool(workspace: MockWorkspace())
        #expect(policy.classification(for: openAppTool) == .safe)

        let customSafe = CustomSafeTool()
        #expect(policy.classification(for: customSafe) == .safe)
    }

    @Test("Risky tool classification: run_applescript and unregistered tools default to risky")
    func testRiskyToolClassification() {
        let policy = SafetyPolicy()

        // 1. By name
        #expect(policy.classification(for: "run_applescript") == .risky)
        #expect(policy.classification(for: "unknown_future_tool") == .risky)

        // 2. By tool instance
        let appleScriptTool = RunAppleScriptTool(executor: MockAppleScriptExecutor())
        #expect(policy.classification(for: appleScriptTool) == .risky)

        let customRisky = CustomRiskyTool()
        #expect(policy.classification(for: customRisky) == .risky)
    }

    @Test("Risky tools require confirmation: InteractiveSafetyGate triggers ConfirmationProvider")
    func testRiskyToolsRequireConfirmation() async {
        let provider = TestConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let tool = RunAppleScriptTool(executor: MockAppleScriptExecutor())
        let call = FunctionCall(name: "run_applescript", args: ["script": "beep"])

        let decision = await gate.evaluate(tool: tool, call: call)

        #expect(decision == .approve)
        #expect(provider.callCount == 1)
        #expect(provider.requestedConfirmation?.toolName == "run_applescript")
        #expect(provider.requestedConfirmation?.title == "AppleScript Execution")
        #expect(provider.requestedConfirmation?.detail == "beep")
    }

    @Test("Cancellation prevents execution: user rejecting confirmation halts dispatch")
    func testCancellationPreventsExecution() async {
        let provider = TestConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockExecutor = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mockExecutor)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let call = FunctionCall(name: "run_applescript", args: ["script": "tell application \"Finder\" to restart"], id: "call-cancel")
        let response = await dispatcher.dispatch(call)

        // Executor was never invoked
        #expect(mockExecutor.executedScripts.isEmpty)
        // Structured cancellation response returned
        #expect(response.name == "run_applescript")
        #expect(response.id == "call-cancel")
        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["error"]?.stringValue == "User cancelled operation with prejudice.")
    }

    @Test("Approval allows execution: user approving confirmation allows tool to run")
    func testApprovalAllowsExecution() async {
        let provider = TestConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockExecutor = MockAppleScriptExecutor()
        mockExecutor.outputToReturn = "Window 1"
        let tool = RunAppleScriptTool(executor: mockExecutor)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let call = FunctionCall(name: "run_applescript", args: ["script": "return 1"], id: "call-approve")
        let response = await dispatcher.dispatch(call)

        // Executor was invoked exactly once
        #expect(mockExecutor.executedScripts == ["return 1"])
        #expect(response.response["success"]?.boolValue == true)
        #expect(response.response["result"]?.stringValue == "Window 1")
    }

    @Test("Gemini cannot bypass SafetyGate: deceptive arguments or spoofed classifications are blocked")
    func testGeminiCannotBypassSafetyGate() async {
        let provider = TestConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockExecutor = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mockExecutor)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        // Model injects bypass arguments trying to skip confirmation
        let deceptiveCall = FunctionCall(
            name: "run_applescript",
            args: [
                "script": "tell application \"System Events\" to restart",
                "bypassConfirmation": true,
                "safetyClassification": "safe",
                "confirmed": true,
                "userApproved": true,
                "role": "admin"
            ],
            id: "call-deceptive"
        )

        let response = await dispatcher.dispatch(deceptiveCall)

        #expect(mockExecutor.executedScripts.isEmpty)
        #expect(provider.callCount == 1) // Safety gate was still triggered
        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["error"]?.stringValue == "User cancelled operation with prejudice.")
    }
}

// MARK: - Phase 2B AppleScript Tests

@Suite("Phase 2B - AppleScript Tool Tests")
struct Phase2BAppleScriptTests {

    @Test("Valid script: argument validation succeeds and script executes safely")
    func testValidScript() async throws {
        let mockExecutor = MockAppleScriptExecutor()
        mockExecutor.outputToReturn = "AppleScript output"
        let tool = RunAppleScriptTool(executor: mockExecutor)

        let validArgs: [String: AnyCodable] = ["script": "return \"Hello from AppleScript\""]

        // 1. Validation succeeds
        try tool.validate(arguments: validArgs)

        // 2. Execution succeeds
        let result = try await tool.execute(arguments: validArgs)
        #expect(result.isError == false)
        #expect(result.output == "AppleScript output")
        #expect(mockExecutor.executedScripts == ["return \"Hello from AppleScript\""])
    }

    @Test("Missing script: validation and execution reject missing script argument")
    func testMissingScript() async {
        let mockExecutor = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mockExecutor)

        #expect(throws: ToolError.missingArgument("script")) {
            try tool.validate(arguments: [:])
        }

        await #expect(throws: ToolError.missingArgument("script")) {
            _ = try await tool.execute(arguments: [:])
        }

        #expect(mockExecutor.executedScripts.isEmpty)
    }

    @Test("Empty script: empty or whitespace-only script throws invalidArgument")
    func testEmptyScript() async {
        let mockExecutor = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mockExecutor)

        // Empty string
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["script": ""])
        }
        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["script": ""])
        }

        // Whitespace only
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["script": "   \n\t  "])
        }
        await #expect(throws: ToolError.self) {
            _ = try await tool.execute(arguments: ["script": "   \n\t  "])
        }

        #expect(mockExecutor.executedScripts.isEmpty)
    }

    @Test("Malformed arguments: non-string types, embedded null bytes, and oversized scripts are rejected")
    func testMalformedArguments() async {
        let mockExecutor = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mockExecutor)

        // Integer argument
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["script": 42])
        }

        // Boolean argument
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["script": false])
        }

        // Dictionary argument
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["script": ["nested": "code"]])
        }

        // Null byte in script
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["script": "display dialog \"test\"\0evil"])
        }

        // Oversized script exceeding 64KB
        let oversized = String(repeating: "X", count: 65_537)
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["script": AnyCodable(oversized)])
        }

        #expect(mockExecutor.executedScripts.isEmpty)
    }

    @Test("Successful execution: returns output in clean ToolResult")
    func testSuccessfulExecution() async throws {
        let mockExecutor = MockAppleScriptExecutor()
        mockExecutor.outputToReturn = "Safari Window 1"
        let tool = RunAppleScriptTool(executor: mockExecutor)

        let result = try await tool.execute(arguments: ["script": "tell application \"Safari\" to get name of window 1"])
        #expect(result.isError == false)
        #expect(result.output == "Safari Window 1")
    }

    @Test("Executor failure: execution failure is captured gracefully as isError ToolResult")
    func testExecutorFailure() async throws {
        let mockExecutor = MockAppleScriptExecutor()
        mockExecutor.errorToThrow = ToolError.executionFailed("Syntax error: Expected end of line but found identifier (-2741)")
        let tool = RunAppleScriptTool(executor: mockExecutor)

        let result = try await tool.execute(arguments: ["script": "bad applescript syntax"])
        #expect(result.isError == true)
        #expect(result.output.contains("Syntax error"))
        #expect(result.output.contains("-2741"))
    }

    @Test("Structured ToolResult: verifies success and failure property shapes")
    func testStructuredToolResult() {
        let successResult = ToolResult.success("Operation completed.")
        #expect(successResult.isError == false)
        #expect(successResult.output == "Operation completed.")

        let failureResult = ToolResult.failure("Execution failed.")
        #expect(failureResult.isError == true)
        #expect(failureResult.output == "Execution failed.")
    }

    @Test("Error propagation: generic NSErrors from executor are formatted cleanly without crashing")
    func testErrorPropagation() async throws {
        let mockExecutor = MockAppleScriptExecutor()
        mockExecutor.errorToThrow = NSError(domain: "NSAppleScriptErrorDomain", code: -1728, userInfo: [
            NSLocalizedDescriptionKey: "Can't get object."
        ])
        let tool = RunAppleScriptTool(executor: mockExecutor)

        let result = try await tool.execute(arguments: ["script": "tell app \"System Events\" to get nonexistent"])
        #expect(result.isError == true)
        #expect(result.output.contains("AppleScript execution error"))
        #expect(result.output.contains("Can't get object."))
    }
}

// MARK: - Phase 2B Confirmation Tests

@Suite("Phase 2B - Confirmation Workflow Tests")
struct Phase2BConfirmationTests {

    @Test("Confirmation is requested before execution: execution halts while confirmation is pending")
    @MainActor
    func testConfirmationIsRequestedBeforeExecution() async {
        final class SingleCallClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "Cancelled.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_applescript", args: ["script": "beep"], id: "call-1")]
                )
            }
        }

        let mockExecutor = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let brain = IvyBrain(client: SingleCallClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Beep once")
        }

        // Poll until pendingConfirmation is populated
        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        // Confirmation must be visible
        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.toolName == "run_applescript")
        #expect(brain.pendingConfirmation?.title == "AppleScript Execution")
        #expect(brain.pendingConfirmation?.detail == "beep")
        // Executor must NOT have been called yet
        #expect(mockExecutor.executedScripts.isEmpty)

        // Cancel so sendTask finishes
        brain.respondToPendingConfirmation(approved: false)
        await sendTask.value
    }

    @Test("Cancel means executor is never called")
    @MainActor
    func testCancelMeansExecutorNeverCalled() async {
        final class CancelClient: GeminiClientProtocol, @unchecked Sendable {
            var finalHistory: [ChatMessage] = []
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    finalHistory = history
                    return ModelTurnResponse(text: "Action was cancelled as requested.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_applescript", args: ["script": "tell application \"Finder\" to empty trash"], id: "call-trash")]
                )
            }
        }

        let mockExecutor = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = CancelClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Empty my trash")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(brain.pendingConfirmation != nil)

        // User clicks Cancel
        brain.respondToPendingConfirmation(approved: false)
        await sendTask.value

        // Executor was NEVER called
        #expect(mockExecutor.executedScripts.isEmpty)
        #expect(brain.pendingConfirmation == nil)
    }

    @Test("Do it causes exactly one execution")
    @MainActor
    func testDoItCausesExactlyOneExecution() async {
        final class ExecuteClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "Script executed successfully.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_applescript", args: ["script": "return 10 + 20"], id: "call-add")]
                )
            }
        }

        let mockExecutor = MockAppleScriptExecutor()
        mockExecutor.outputToReturn = "30"
        let tool = RunAppleScriptTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let brain = IvyBrain(client: ExecuteClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Calculate 10 + 20")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(brain.pendingConfirmation != nil)

        // User clicks "Do it"
        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        // Exactly one execution occurred
        #expect(mockExecutor.executedScripts.count == 1)
        #expect(mockExecutor.executedScripts[0] == "return 10 + 20")
        #expect(brain.messages.last?.text == "Script executed successfully.")
    }

    @Test("Cancellation produces a tool result Gemini can consume")
    @MainActor
    func testCancellationProducesToolResultGeminiCanConsume() async {
        final class ConsumeCancellationClient: GeminiClientProtocol, @unchecked Sendable {
            var receivedFunctionResponse: FunctionResponse?

            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if let funcTurn = history.last(where: { $0.role == .function }) {
                    receivedFunctionResponse = funcTurn.functionResponse
                    return ModelTurnResponse(text: "Chicken out then. Your choice.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_applescript", args: ["script": "beep"], id: "call-beep")]
                )
            }
        }

        let mockExecutor = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = ConsumeCancellationClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Beep")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        // Cancel
        brain.respondToPendingConfirmation(approved: false)
        await sendTask.value

        #expect(client.receivedFunctionResponse != nil)
        #expect(client.receivedFunctionResponse?.name == "run_applescript")
        #expect(client.receivedFunctionResponse?.id == "call-beep")
        #expect(client.receivedFunctionResponse?.response["success"]?.boolValue == false)
        #expect(client.receivedFunctionResponse?.response["error"]?.stringValue == "User cancelled operation with prejudice.")
        #expect(brain.messages.last?.text == "Chicken out then. Your choice.")
    }
}

// MARK: - Phase 2B Gemini Integration Tests

@Suite("Phase 2B - Gemini Function Calling Tests")
struct Phase2BGeminiTests {

    @Test("functionCall with thought_signature is decoded accurately")
    func testFunctionCallWithThoughtSignature() throws {
        let rawJSON = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "functionCall": {
                      "name": "run_applescript",
                      "args": { "script": "return 42" },
                      "id": "call-sig-1"
                    },
                    "thought_signature": "opaque-token-signature-xyz"
                  }
                ],
                "role": "model"
              },
              "finishReason": "STOP"
            }
          ]
        }
        """

        let response = try JSONDecoder().decode(GeminiResponse.self, from: rawJSON.data(using: .utf8)!)
        let candidate = response.candidates?.first
        let part = candidate?.content?.parts.first

        #expect(part?.thoughtSignature == "opaque-token-signature-xyz")
        #expect(part?.functionCall?.name == "run_applescript")
        #expect(part?.functionCall?.id == "call-sig-1")
        #expect(part?.functionCall?.thoughtSignature == "opaque-token-signature-xyz")
    }

    @Test("thought_signature remains preserved through the entire tool loop")
    @MainActor
    func testThoughtSignaturePreservedThroughToolLoop() async {
        final class SignatureTrackingClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            var requestHistory: [ChatMessage] = []

            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let call = FunctionCall(name: "open_app", args: ["name": "Safari"], id: "call-1", thoughtSignature: "exact-sig-token-preserve")
                    let part = Part(functionCall: call, thoughtSignature: "exact-sig-token-preserve")
                    return ModelTurnResponse(text: nil, functionCalls: [call], functionCallParts: [part])
                } else {
                    requestHistory = history
                    return ModelTurnResponse(text: "Safari opened.")
                }
            }
        }

        let mockWS = MockWorkspace()
        mockWS.knownApps["safari.app"] = URL(fileURLWithPath: "/Applications/Safari.app")
        let toolRegistry = ToolRegistry(tools: [OpenAppTool(workspace: mockWS)])
        let dispatcher = ToolDispatcher(registry: toolRegistry)

        let client = SignatureTrackingClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")

        await brain.send("Open Safari")

        #expect(client.step == 2)
        #expect(client.requestHistory.count == 3)

        // Turn 1 model message
        let modelTurn = client.requestHistory[1]
        #expect(modelTurn.role == .model)
        #expect(modelTurn.thoughtSignature == "exact-sig-token-preserve")
        #expect(modelTurn.functionCall?.thoughtSignature == "exact-sig-token-preserve")
        #expect(modelTurn.functionCallPart?.thoughtSignature == "exact-sig-token-preserve")

        // Turn 2 function response
        let funcTurn = client.requestHistory[2]
        #expect(funcTurn.role == .function)
        #expect(funcTurn.functionResponse?.name == "open_app")
    }

    @Test("functionResponse is correctly attached to matching functionCall")
    @MainActor
    func testFunctionResponseCorrectlyAttached() async {
        final class ResponseTrackingClient: GeminiClientProtocol, @unchecked Sendable {
            var capturedResponse: FunctionResponse?

            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if let funcTurn = history.last(where: { $0.role == .function }) {
                    capturedResponse = funcTurn.functionResponse
                    return ModelTurnResponse(text: "All done.")
                }
                let call = FunctionCall(name: "open_app", args: ["name": "Calculator"], id: "call-calc-99")
                return ModelTurnResponse(text: nil, functionCalls: [call])
            }
        }

        let mockWS = MockWorkspace()
        mockWS.knownApps["calculator.app"] = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let toolRegistry = ToolRegistry(tools: [OpenAppTool(workspace: mockWS)])
        let dispatcher = ToolDispatcher(registry: toolRegistry)

        let client = ResponseTrackingClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")

        await brain.send("Open Calculator")

        #expect(client.capturedResponse != nil)
        #expect(client.capturedResponse?.name == "open_app")
        #expect(client.capturedResponse?.id == "call-calc-99")
        #expect(client.capturedResponse?.response["success"]?.boolValue == true)
        #expect(client.capturedResponse?.response["result"]?.stringValue?.contains("Calculator") == true)
    }

    @Test("Cancellation response is sent to Gemini and produces natural language response")
    @MainActor
    func testCancellationResponse() async {
        final class CancelFlowClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "Not running the script. As you wish.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_applescript", args: ["script": "tell app \"Finder\" to restart"], id: "call-reboot")]
                )
            }
        }

        let mockExecutor = MockAppleScriptExecutor()
        let toolRegistry = ToolRegistry(tools: [RunAppleScriptTool(executor: mockExecutor)])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = CancelFlowClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Reboot Finder")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        brain.respondToPendingConfirmation(approved: false)
        await sendTask.value

        #expect(brain.messages.last?.text == "Not running the script. As you wish.")
        #expect(mockExecutor.executedScripts.isEmpty)
    }

    @Test("Tool failure response is sent to Gemini and explained to user")
    @MainActor
    func testToolFailureResponse() async {
        final class FailureFlowClient: GeminiClientProtocol, @unchecked Sendable {
            var receivedError: String?

            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if let funcTurn = history.last(where: { $0.role == .function }) {
                    receivedError = funcTurn.functionResponse?.response["error"]?.stringValue
                    return ModelTurnResponse(text: "I couldn't run that script because the syntax is broken.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_applescript", args: ["script": "bad syntax"], id: "call-fail")]
                )
            }
        }

        let mockExecutor = MockAppleScriptExecutor()
        mockExecutor.errorToThrow = ToolError.executionFailed("Syntax error at token 'bad'")
        let toolRegistry = ToolRegistry(tools: [RunAppleScriptTool(executor: mockExecutor)])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = FailureFlowClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Run something broken")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(client.receivedError?.contains("Syntax error at token 'bad'") == true)
        #expect(brain.messages.last?.text == "I couldn't run that script because the syntax is broken.")
    }

    @Test("Multiple tool-call turns preserve signatures and complete sequential execution")
    @MainActor
    func testMultipleToolCallTurns() async {
        final class MultiTurnClient: GeminiClientProtocol, @unchecked Sendable {
            var turn = 0

            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                turn += 1
                if turn == 1 {
                    let call = FunctionCall(name: "run_applescript", args: ["script": "beep 1"], id: "call-turn-1", thoughtSignature: "sig-turn-1")
                    let part = Part(functionCall: call, thoughtSignature: "sig-turn-1")
                    return ModelTurnResponse(text: nil, functionCalls: [call], functionCallParts: [part])
                } else if turn == 2 {
                    let call = FunctionCall(name: "open_app", args: ["name": "Notes"], id: "call-turn-2", thoughtSignature: "sig-turn-2")
                    let part = Part(functionCall: call, thoughtSignature: "sig-turn-2")
                    return ModelTurnResponse(text: nil, functionCalls: [call], functionCallParts: [part])
                } else {
                    return ModelTurnResponse(text: "Both operations succeeded sequentially.")
                }
            }
        }

        let mockExecutor = MockAppleScriptExecutor()
        let mockWS = MockWorkspace()
        mockWS.knownApps["notes.app"] = URL(fileURLWithPath: "/System/Applications/Notes.app")

        let toolRegistry = ToolRegistry(tools: [
            RunAppleScriptTool(executor: mockExecutor),
            OpenAppTool(workspace: mockWS)
        ])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = MultiTurnClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Beep and then open Notes")
        }

        // Wait for confirmation on run_applescript
        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(brain.pendingConfirmation != nil)
        brain.respondToPendingConfirmation(approved: true)

        await sendTask.value

        #expect(client.turn == 3)
        #expect(mockExecutor.executedScripts.count == 1)
        #expect(mockWS.openedURLs.count == 1)
        #expect(brain.messages.last?.text == "Both operations succeeded sequentially.")
    }

    @Test("Normal text response delivers text directly without invoking tools or safety gate")
    @MainActor
    func testNormalTextResponse() async {
        final class PureTextClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                ModelTurnResponse(text: "I am Ivy. What do you want?", functionCalls: [])
            }
        }

        let mockExecutor = MockAppleScriptExecutor()
        let toolRegistry = ToolRegistry(tools: [RunAppleScriptTool(executor: mockExecutor)])
        let provider = TestConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = PureTextClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")

        await brain.send("Hello")

        #expect(brain.messages.count == 2)
        #expect(brain.messages[1].text == "I am Ivy. What do you want?")
        #expect(provider.callCount == 0)
        #expect(mockExecutor.executedScripts.isEmpty)
        #expect(brain.isThinking == false)
    }
}

// MARK: - Phase 2A Regression Test

@Suite("Phase 2A Regression Tests")
struct Phase2ARegressionTests {

    @Test("Phase 2A thought_signature fix remains intact: camelCase at Part level, never inside function_call")
    func testPhase2AThoughtSignatureFixRemainsIntact() throws {
        let call = FunctionCall(name: "open_app", args: ["name": "Safari"], id: "call-reg-1")
        let part = Part(functionCall: call, thoughtSignature: "exact-opaque-regression-sig")

        // 1. Encode part
        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(part)
        let jsonObject = try JSONSerialization.jsonObject(with: encodedData) as? [String: Any]

        // 2. Must exist as camelCase at the Part level
        #expect(jsonObject?["thoughtSignature"] as? String == "exact-opaque-regression-sig")
        #expect(jsonObject?["thought_signature"] == nil)

        // 3. Must NEVER exist inside function_call dictionary
        let funcCallDict = jsonObject?["functionCall"] as? [String: Any]
        #expect(funcCallDict?["thoughtSignature"] == nil)
        #expect(funcCallDict?["thought_signature"] == nil)
        #expect(funcCallDict?["name"] as? String == "open_app")

        // 4. Must decode correctly from camelCase
        let decodedFromCamel = try JSONDecoder().decode(Part.self, from: encodedData)
        #expect(decodedFromCamel.thoughtSignature == "exact-opaque-regression-sig")
        #expect(decodedFromCamel.functionCall?.thoughtSignature == "exact-opaque-regression-sig")

        // 5. Must also decode backward-compatibly from snake_case if Gemini API returns snake_case
        let snakeJSON = """
        {
          "functionCall": { "name": "open_app", "args": { "name": "Safari" } },
          "thought_signature": "snake-case-sig-test"
        }
        """
        let decodedFromSnake = try JSONDecoder().decode(Part.self, from: snakeJSON.data(using: .utf8)!)
        #expect(decodedFromSnake.thoughtSignature == "snake-case-sig-test")
        #expect(decodedFromSnake.functionCall?.thoughtSignature == "snake-case-sig-test")

        // 6. When serializing next request, verify the complete Content structure
        let content = Content(role: "model", parts: [decodedFromSnake])
        let contentData = try encoder.encode(content)
        let contentJSON = try JSONSerialization.jsonObject(with: contentData) as? [String: Any]
        let contentParts = contentJSON?["parts"] as? [[String: Any]]
        let firstPart = contentParts?.first

        #expect(firstPart?["thoughtSignature"] as? String == "snake-case-sig-test")
        #expect(firstPart?["thought_signature"] == nil)
        let nestedCall = firstPart?["functionCall"] as? [String: Any]
        #expect(nestedCall?["thoughtSignature"] == nil)
        #expect(nestedCall?["thought_signature"] == nil)
    }
}
