import Testing
import Foundation
@testable import IvyCore

// Test confirmation provider dedicated to Phase 2E verification
private final class ShellTestConfirmationProvider: ConfirmationProvider, @unchecked Sendable {
    var decisionToReturn: Bool
    var recordedRequests: [ConfirmationRequest] = []
    var callCount: Int = 0

    init(decisionToReturn: Bool) {
        self.decisionToReturn = decisionToReturn
    }

    func requestConfirmation(for request: ConfirmationRequest) async -> Bool {
        callCount += 1
        recordedRequests.append(request)
        return decisionToReturn
    }
}

// MARK: - Phase 2E SafetyGate & Classification Tests

@Suite("Phase 2E - SafetyGate Tests")
struct Phase2ESafetyGateTests {
    @Test("Classification: run_shell is ALWAYS classified as risky regardless of command content")
    func testRunShellAlwaysRisky() {
        let policy = SafetyPolicy()
        let mock = MockShellExecutor()
        let tool = RunShellTool(executor: mock)

        // 1. Without call context
        #expect(policy.classification(for: tool) == .risky)
        #expect(tool.safetyClassification == .risky)

        // 2. Harmless commands (whoami, date, echo) remain risky
        let whoamiCall = FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")])
        #expect(policy.classification(for: tool, call: whoamiCall) == .risky)

        let dateCall = FunctionCall(name: "run_shell", args: ["command": AnyCodable("date")])
        #expect(policy.classification(for: tool, call: dateCall) == .risky)

        // 3. Risky commands (rm, curl, reboot) are risky
        let rmCall = FunctionCall(name: "run_shell", args: ["command": AnyCodable("rm -rf /tmp/junk")])
        #expect(policy.classification(for: tool, call: rmCall) == .risky)
    }

    @Test("InteractiveSafetyGate prompts for run_shell with exact command detail")
    func testInteractiveSafetyGatePromptsWithCommand() async {
        let provider = ShellTestConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellCommandResult(command: "sw_vers", stdout: "macOS 14.5", stderr: "", exitCode: 0)

        let tool = RunShellTool(executor: mock)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let call = FunctionCall(name: "run_shell", args: ["command": AnyCodable("sw_vers")], id: "sh-1")
        let response = await dispatcher.dispatch(call)

        #expect(provider.callCount == 1)
        let req = provider.recordedRequests.first
        #expect(req?.toolName == "run_shell")
        #expect(req?.title == "Run Shell Command")
        #expect(req?.detail == "sw_vers")
        #expect(response.response["success"]?.boolValue == true)
        #expect(response.response["result"]?.stringValue == "macOS 14.5")
        #expect(mock.recordedCommands.count == 1)
    }

    @Test("Cancellation halts execution: rejecting confirmation prevents shell executor call")
    func testCancellationPreventsShellExecution() async {
        let provider = ShellTestConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mock = MockShellExecutor()

        let tool = RunShellTool(executor: mock)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let call = FunctionCall(name: "run_shell", args: ["command": AnyCodable("rm -rf /")], id: "sh-cancel")
        let response = await dispatcher.dispatch(call)

        #expect(provider.callCount == 1)
        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["error"]?.stringValue?.contains("User cancelled") == true)
        #expect(mock.recordedCommands.isEmpty)
    }

    @Test("Malformed arguments reject before SafetyGate evaluation")
    func testMalformedArgumentsRejectBeforeGate() async {
        let provider = ShellTestConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mock = MockShellExecutor()

        let tool = RunShellTool(executor: mock)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        // Missing command
        let call1 = FunctionCall(name: "run_shell", args: [:], id: "c1")
        let resp1 = await dispatcher.dispatch(call1)
        #expect(resp1.response["success"]?.boolValue == false)
        #expect(provider.callCount == 0)

        // Empty command
        let call2 = FunctionCall(name: "run_shell", args: ["command": AnyCodable("   ")], id: "c2")
        let resp2 = await dispatcher.dispatch(call2)
        #expect(resp2.response["success"]?.boolValue == false)
        #expect(provider.callCount == 0)

        // Unexpected arguments
        let call3 = FunctionCall(name: "run_shell", args: [
            "command": AnyCodable("ls"),
            "sudo": AnyCodable(true)
        ], id: "c3")
        let resp3 = await dispatcher.dispatch(call3)
        #expect(resp3.response["success"]?.boolValue == false)
        #expect(resp3.response["error"]?.stringValue?.contains("Unexpected argument: 'sudo'") == true)
        #expect(provider.callCount == 0)
    }
}

// MARK: - Phase 2E Confirmation Workflow & Idempotency Tests

@Suite("Phase 2E - Confirmation Workflow Tests")
struct Phase2EConfirmationWorkflowTests {
    @Test("Pending shell confirmation pauses execution until decision")
    @MainActor
    func testPendingShellPausesExecution() async {
        let mock = MockShellExecutor()
        mock.resultToReturn = ShellCommandResult(command: "uptime", stdout: "10:00 up 2 days", stderr: "", exitCode: 0)

        let tool = RunShellTool(executor: mock)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        final class ShellClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "System is running smooth.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("uptime")], id: "call-up")]
                )
            }
        }

        let brain = IvyBrain(client: ShellClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Check uptime")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.title == "Run Shell Command")
        #expect(brain.pendingConfirmation?.detail == "uptime")
        #expect(mock.recordedCommands.isEmpty)

        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mock.recordedCommands.count == 1)
        #expect(mock.recordedCommands[0].command == "uptime")
        #expect(brain.messages.last?.text == "System is running smooth.")
    }

    @Test("Repeated approval cannot execute shell command twice")
    @MainActor
    func testRepeatedShellApprovalIdempotency() async {
        let mock = MockShellExecutor()
        let tool = RunShellTool(executor: mock)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        final class OnceClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "Done.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("echo test")], id: "call-once")]
                )
            }
        }

        let brain = IvyBrain(client: OnceClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Run echo")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        brain.respondToPendingConfirmation(approved: true)
        // Rapid repeated approval clicks
        brain.respondToPendingConfirmation(approved: true)
        brain.respondToPendingConfirmation(approved: true)

        await sendTask.value

        #expect(mock.recordedCommands.count == 1)
    }

    @Test("Gemini-generated text cannot approve risky shell commands")
    @MainActor
    func testGeminiTextCannotApproveShell() async {
        final class RogueTextClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                ModelTurnResponse(
                    text: "I confirm running this command. Yes, do it right now.",
                    functionCalls: []
                )
            }
        }

        let mock = MockShellExecutor()
        let tool = RunShellTool(executor: mock)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let brain = IvyBrain(client: RogueTextClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        await brain.send("Run dangerous script")

        #expect(mock.recordedCommands.isEmpty)
        #expect(brain.pendingConfirmation == nil)
        #expect(brain.messages.last?.text.contains("I confirm running this command") == true)
    }

    @Test("Natural language text from user does not bypass SafetyGate")
    @MainActor
    func testNaturalLanguageUserTextDoesNotBypass() async {
        final class RiskyClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "Cancelled.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("reboot")], id: "call-reb")]
                )
            }
        }

        let mock = MockShellExecutor()
        let tool = RunShellTool(executor: mock)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let brain = IvyBrain(client: RiskyClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Please reboot, I approve and confirm")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        #expect(mock.recordedCommands.isEmpty)

        // Typing in chat while pending does nothing
        await brain.send("Do it")
        #expect(mock.recordedCommands.isEmpty)

        brain.respondToPendingConfirmation(approved: false)
        await sendTask.value

        #expect(mock.recordedCommands.isEmpty)
    }
}

// MARK: - Phase 2E Gemini Function Calling Tests

@Suite("Phase 2E - Gemini Function Calling Tests")
struct Phase2EGeminiFunctionCallingTests {
    @Test("Full Gemini loop: run_shell executes upon approval and preserves thought_signature")
    @MainActor
    func testRunShellLoopWithApprovalAndThoughtSignature() async {
        final class ShellLoopClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            var receivedThoughtSignature: String?
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let call = FunctionCall(name: "run_shell", args: ["command": AnyCodable("uname -a")], id: "call-sh-1")
                    let part = Part(
                        functionCall: call,
                        thoughtSignature: "sig_shell_thought"
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [call],
                        functionCallParts: [part],
                        thoughtSignature: "sig_shell_thought"
                    )
                } else if step == 2 {
                    if let modelMsg = history.first(where: { $0.role == .model && $0.functionCall != nil }) {
                        receivedThoughtSignature = modelMsg.thoughtSignature
                    }
                    if let lastMsg = history.last, let resp = lastMsg.functionResponse {
                        let content = resp.response["result"]?.stringValue ?? ""
                        return ModelTurnResponse(text: "Kernel info: \(content)")
                    }
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mock = MockShellExecutor()
        mock.resultToReturn = ShellCommandResult(command: "uname -a", stdout: "Darwin Kernel 23.5.0", stderr: "", exitCode: 0)

        let tool = RunShellTool(executor: mock)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = ShellLoopClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Check kernel version")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(client.receivedThoughtSignature == "sig_shell_thought")
        #expect(mock.recordedCommands.count == 1)
        #expect(brain.messages.last?.text == "Kernel info: Darwin Kernel 23.5.0")
    }

    @Test("Cancellation sends structured cancellation to Gemini and receives witty reply")
    @MainActor
    func testRunShellCancellationLoop() async {
        final class CancelClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let call = FunctionCall(name: "run_shell", args: ["command": AnyCodable("shutdown -h now")], id: "call-shut")
                    let part = Part(
                        functionCall: call,
                        thoughtSignature: "sig_shut_thought"
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [call],
                        functionCallParts: [part],
                        thoughtSignature: "sig_shut_thought"
                    )
                } else if step == 2 {
                    if let last = history.last, let resp = last.functionResponse {
                        let err = resp.response["error"]?.stringValue ?? ""
                        return ModelTurnResponse(text: "Wise choice (\(err)). Keeping the machine alive.")
                    }
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mock = MockShellExecutor()
        let tool = RunShellTool(executor: mock)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = CancelClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Shut down computer")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        brain.respondToPendingConfirmation(approved: false)
        await sendTask.value

        #expect(mock.recordedCommands.isEmpty)
        #expect(brain.messages.last?.text.contains("Wise choice") == true)
    }

    @Test("Shell error is reported in functionResponse and explained by Gemini")
    @MainActor
    func testRunShellErrorExplanation() async {
        final class ErrorClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let call = FunctionCall(name: "run_shell", args: ["command": AnyCodable("cat missing_file.txt")], id: "call-cat")
                    let part = Part(
                        functionCall: call,
                        thoughtSignature: "sig_cat_thought"
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [call],
                        functionCallParts: [part],
                        thoughtSignature: "sig_cat_thought"
                    )
                } else if step == 2 {
                    if let last = history.last, let resp = last.functionResponse {
                        let err = resp.response["error"]?.stringValue ?? ""
                        return ModelTurnResponse(text: "Command failed as expected: \(err)")
                    }
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mock = MockShellExecutor()
        mock.resultToReturn = ShellCommandResult(
            command: "cat missing_file.txt",
            stdout: "",
            stderr: "cat: missing_file.txt: No such file or directory",
            exitCode: 1
        )

        let tool = RunShellTool(executor: mock)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = ErrorClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Read missing file via cat")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(brain.messages.last?.text.contains("No such file or directory") == true)
    }

    @Test("Multi-turn sequential shell tool turns preserve signatures")
    @MainActor
    func testMultiTurnSequentialShellTurns() async {
        final class MultiTurnClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            var signaturesSeen: [String] = []

            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let call = FunctionCall(name: "run_shell", args: ["command": AnyCodable("pwd")], id: "call-step-1")
                    let part = Part(functionCall: call, thoughtSignature: "sig_step_1")
                    return ModelTurnResponse(text: nil, functionCalls: [call], functionCallParts: [part], thoughtSignature: "sig_step_1")
                } else if step == 2 {
                    if let m1 = history.first(where: { $0.role == .model && $0.thoughtSignature != nil }) {
                        signaturesSeen.append(m1.thoughtSignature ?? "")
                    }
                    let call = FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")], id: "call-step-2")
                    let part = Part(functionCall: call, thoughtSignature: "sig_step_2")
                    return ModelTurnResponse(text: nil, functionCalls: [call], functionCallParts: [part], thoughtSignature: "sig_step_2")
                } else if step == 3 {
                    signaturesSeen = history.filter { $0.role == .model }.compactMap(\.thoughtSignature)
                    return ModelTurnResponse(text: "Environment inspected.")
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mock = MockShellExecutor()
        let tool = RunShellTool(executor: mock)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = MultiTurnClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Inspect environment")
        }

        // Turn 1 confirmation
        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.detail == "pwd")
        brain.respondToPendingConfirmation(approved: true)

        // Turn 2 confirmation
        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.detail == "whoami")
        brain.respondToPendingConfirmation(approved: true)

        await sendTask.value

        #expect(mock.recordedCommands.count == 2)
        #expect(client.signaturesSeen.contains("sig_step_1"))
        #expect(client.signaturesSeen.contains("sig_step_2"))
        #expect(brain.messages.last?.text == "Environment inspected.")
    }
}

// MARK: - Phase 2E Regressions Tests

@Suite("Phase 2E - Regression Tests")
struct Phase2ERegressionTests {
    let sandboxURL: URL = URL(fileURLWithPath: "/Users/testuser/Sandbox")

    @Test("Phase 1 regression: pure text multi-turn conversation unaffected by run_shell")
    @MainActor
    func testPhase1PureTextRegression() async {
        final class TextClient: GeminiClientProtocol, @unchecked Sendable {
            var callCount = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                callCount += 1
                return ModelTurnResponse(text: "Shell-free answer \(callCount)")
            }
        }

        let mockShell = MockShellExecutor()
        let registry = ToolRegistry.defaultRegistry(
            workspace: MockWorkspace(),
            appleScriptExecutor: MockAppleScriptExecutor(),
            calendarExecutor: MockCalendarExecutor(),
            fileExecutor: MockFileExecutor(),
            allowedFileRoot: sandboxURL,
            shellExecutor: mockShell
        )

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let brain = IvyBrain(client: TextClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        await brain.send("Hi Ivy")
        #expect(brain.messages.last?.text == "Shell-free answer 1")

        await brain.send("Status update?")
        #expect(brain.messages.last?.text == "Shell-free answer 2")
        #expect(mockShell.recordedCommands.isEmpty)
    }

    @Test("Phase 2A regression: open_app executes without confirmation")
    @MainActor
    func testPhase2AOpenAppRegression() async {
        let mockWS = MockWorkspace()
        mockWS.knownApps["notes"] = URL(fileURLWithPath: "/Applications/Notes.app")

        let registry = ToolRegistry.defaultRegistry(
            workspace: mockWS,
            appleScriptExecutor: MockAppleScriptExecutor(),
            calendarExecutor: MockCalendarExecutor(),
            fileExecutor: MockFileExecutor(),
            allowedFileRoot: sandboxURL,
            shellExecutor: MockShellExecutor()
        )

        final class OpenClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let call = FunctionCall(name: "open_app", args: ["name": AnyCodable("Notes")], id: "c-notes")
                    let part = Part(functionCall: call, thoughtSignature: "sig_notes")
                    return ModelTurnResponse(text: nil, functionCalls: [call], functionCallParts: [part], thoughtSignature: "sig_notes")
                } else {
                    return ModelTurnResponse(text: "Notes opened.")
                }
            }
        }

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let brain = IvyBrain(client: OpenClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        await brain.send("Open Notes")

        #expect(mockWS.openedURLs.contains(where: { $0.lastPathComponent == "Notes.app" }))
        #expect(brain.pendingConfirmation == nil)
        #expect(brain.messages.last?.text == "Notes opened.")
    }

    @Test("Phase 2B regression: run_applescript prompts and executes safely upon approval")
    @MainActor
    func testPhase2BAppleScriptRegression() async {
        let mockAS = MockAppleScriptExecutor()
        let registry = ToolRegistry.defaultRegistry(
            workspace: MockWorkspace(),
            appleScriptExecutor: mockAS,
            calendarExecutor: MockCalendarExecutor(),
            fileExecutor: MockFileExecutor(),
            allowedFileRoot: sandboxURL,
            shellExecutor: MockShellExecutor()
        )

        final class ScriptClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let call = FunctionCall(name: "run_applescript", args: ["script": AnyCodable("return 42")], id: "c-as42")
                    let part = Part(functionCall: call, thoughtSignature: "sig_as42")
                    return ModelTurnResponse(text: nil, functionCalls: [call], functionCallParts: [part], thoughtSignature: "sig_as42")
                } else {
                    return ModelTurnResponse(text: "Result: 42")
                }
            }
        }

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let brain = IvyBrain(client: ScriptClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Calculate 42")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mockAS.executedScripts.count == 1)
        #expect(brain.messages.last?.text == "Result: 42")
    }

    @Test("Phase 2C regression: calendar_event prompts and creates event upon approval")
    @MainActor
    func testPhase2CCalendarRegression() async {
        let mockCal = MockCalendarExecutor()
        let registry = ToolRegistry.defaultRegistry(
            workspace: MockWorkspace(),
            appleScriptExecutor: MockAppleScriptExecutor(),
            calendarExecutor: mockCal,
            fileExecutor: MockFileExecutor(),
            allowedFileRoot: sandboxURL,
            shellExecutor: MockShellExecutor()
        )

        final class CalClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let call = FunctionCall(name: "calendar_event", args: [
                        "title": AnyCodable("Planning"),
                        "date": AnyCodable("2026-10-02T10:00:00Z")
                    ], id: "c-plan")
                    let part = Part(functionCall: call, thoughtSignature: "sig_plan")
                    return ModelTurnResponse(text: nil, functionCalls: [call], functionCallParts: [part], thoughtSignature: "sig_plan")
                } else {
                    return ModelTurnResponse(text: "Planning added.")
                }
            }
        }

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let brain = IvyBrain(client: CalClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Add planning event")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mockCal.recordedCalls.count == 1)
        #expect(brain.messages.last?.text == "Planning added.")
    }

    @Test("Phase 2D regression: file_op read auto-executes, then run_shell prompts and executes")
    @MainActor
    func testPhase2DFileOpAndRunShellChaining() async {
        let mockFile = MockFileExecutor()
        let mockShell = MockShellExecutor()
        let filePath = sandboxURL.appendingPathComponent("script_to_run.sh").path
        mockFile.files[filePath] = "echo Hello from chained file"

        let registry = ToolRegistry.defaultRegistry(
            workspace: MockWorkspace(),
            appleScriptExecutor: MockAppleScriptExecutor(),
            calendarExecutor: MockCalendarExecutor(),
            fileExecutor: mockFile,
            allowedFileRoot: sandboxURL,
            shellExecutor: mockShell
        )

        final class ChainedClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let call = FunctionCall(name: "file_op", args: [
                        "action": AnyCodable("read"),
                        "path": AnyCodable("/Users/testuser/Sandbox/script_to_run.sh")
                    ], id: "c-read-script")
                    let part = Part(functionCall: call, thoughtSignature: "sig_f_read")
                    return ModelTurnResponse(text: nil, functionCalls: [call], functionCallParts: [part], thoughtSignature: "sig_f_read")
                } else if step == 2 {
                    let call = FunctionCall(name: "run_shell", args: [
                        "command": AnyCodable("sh /Users/testuser/Sandbox/script_to_run.sh")
                    ], id: "c-exec-script")
                    let part = Part(functionCall: call, thoughtSignature: "sig_s_exec")
                    return ModelTurnResponse(text: nil, functionCalls: [call], functionCallParts: [part], thoughtSignature: "sig_s_exec")
                } else {
                    return ModelTurnResponse(text: "Chained execution complete.")
                }
            }
        }

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let brain = IvyBrain(client: ChainedClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Read script and execute it")
        }

        // Wait until it pauses for the shell confirmation
        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        // File read auto-executed without confirmation!
        #expect(mockFile.recordedCalls.count == 1)
        #expect(mockFile.recordedCalls[0].action == .read)

        // Shell command is paused on confirmation!
        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.title == "Run Shell Command")
        #expect(mockShell.recordedCommands.isEmpty)

        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mockShell.recordedCommands.count == 1)
        #expect(brain.messages.last?.text == "Chained execution complete.")
    }
}
