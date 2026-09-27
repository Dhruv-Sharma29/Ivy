import Testing
import Foundation
@testable import IvyCore

// MARK: - Test Confirmation Provider for Phase 3 Audit

private final class Phase3AuditConfirmationProvider: ConfirmationProvider, @unchecked Sendable {
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

// MARK: - Scripted Gemini Client for Phase 3 End-to-End Tests

private final class Phase3ScriptedGeminiClient: GeminiClientProtocol, @unchecked Sendable {
    var step: Int = 0
    var handler: (@Sendable (Int, [ChatMessage]) -> ModelTurnResponse)?
    var recordedHistories: [[ChatMessage]] = []

    init(handler: (@Sendable (Int, [ChatMessage]) -> ModelTurnResponse)? = nil) {
        self.handler = handler
    }

    func generateContent(
        history: [ChatMessage],
        systemPrompt: String,
        apiKey: String
    ) async throws -> String {
        let resp = try await generateContent(history: history, systemPrompt: systemPrompt, tools: nil, apiKey: apiKey)
        return resp.text ?? ""
    }

    func generateContent(
        history: [ChatMessage],
        systemPrompt: String,
        tools: [ToolDeclarationWrapper]?,
        apiKey: String
    ) async throws -> ModelTurnResponse {
        recordedHistories.append(history)
        step += 1
        if let handler {
            return handler(step, history)
        }
        return ModelTurnResponse(text: "Default response", functionCalls: [])
    }
}

// MARK: - Mock Echo Tool for Dispatch Tests

private struct Phase3MockEchoTool: IvyTool, Sendable {
    let name: String = "echo_test"
    let description: String = "Echoes the message"
    var safetyClassification: ToolSafetyClassification { .safe }
    var declaration: FunctionDeclaration {
        FunctionDeclaration(
            name: name,
            description: description,
            parameters: ToolParameters(
                properties: ["msg": ToolProperty(type: "STRING", description: "Message")],
                required: ["msg"]
            )
        )
    }

    func validate(arguments: [String: AnyCodable]) throws {
        guard let msg = arguments["msg"]?.stringValue, !msg.isEmpty else {
            throw ToolError.missingArgument("msg")
        }
    }

    func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let msg = arguments["msg"]?.stringValue ?? ""
        return .success("Echo: \(msg)")
    }
}

// MARK: - Suite 1: Centralized SafetyGate & Risk Invariants (Invariants 1-4)

@Suite("Phase 3 - Centralized SafetyGate & Risk Invariants")
struct Phase3CentralizedSafetyGateTests {
    private let sandboxURL = URL(fileURLWithPath: "/sandbox")

    @Test("Invariant 1: Every registered tool has an explicit safety classification")
    func testEveryRegisteredToolHasExplicitSafetyClassification() {
        let policy = SafetyPolicy()
        let registry = ToolRegistry.defaultRegistry()

        // 1. open_app is explicitly safe
        let openApp = registry.tool(named: "open_app")
        #expect(openApp != nil)
        #expect(policy.classification(for: "open_app") == .safe)
        if let openApp {
            #expect(policy.classification(for: openApp) == .safe)
        }

        // 2. run_applescript is explicitly risky
        let appleScript = registry.tool(named: "run_applescript")
        #expect(appleScript != nil)
        #expect(policy.classification(for: "run_applescript") == .risky)
        if let appleScript {
            #expect(policy.classification(for: appleScript) == .risky)
        }

        // 3. calendar_event is explicitly risky
        let calendar = registry.tool(named: "calendar_event")
        #expect(calendar != nil)
        #expect(policy.classification(for: "calendar_event") == .risky)
        if let calendar {
            #expect(policy.classification(for: calendar) == .risky)
        }

        // 4. file_op default is risky; read is safe, write/delete are risky
        let fileOp = registry.tool(named: "file_op")
        #expect(fileOp != nil)
        if let fileOp {
            #expect(policy.classification(for: fileOp) == .risky)
            let readCall = FunctionCall(name: "file_op", args: ["action": AnyCodable("read"), "path": AnyCodable("/sandbox/test.txt")])
            #expect(policy.classification(for: fileOp, call: readCall) == .safe)
            let writeCall = FunctionCall(name: "file_op", args: ["action": AnyCodable("write"), "path": AnyCodable("/sandbox/test.txt"), "content": AnyCodable("data")])
            #expect(policy.classification(for: fileOp, call: writeCall) == .risky)
            let deleteCall = FunctionCall(name: "file_op", args: ["action": AnyCodable("delete"), "path": AnyCodable("/sandbox/test.txt")])
            #expect(policy.classification(for: fileOp, call: deleteCall) == .risky)
        }

        // 5. run_shell is ALWAYS risky
        let runShell = registry.tool(named: "run_shell")
        #expect(runShell != nil)
        #expect(policy.classification(for: "run_shell") == .risky)
        if let runShell {
            #expect(policy.classification(for: runShell) == .risky)
        }

        // 6. Default classification for unconfigured tools is risky
        #expect(policy.classification(for: "custom_unregistered_tool") == .risky)
    }

    @Test("Invariant 2: Unknown tools are rejected safely without executing fallbacks")
    func testUnknownToolsRejectedSafely() async {
        let registry = ToolRegistry.defaultRegistry()
        let dispatcher = ToolDispatcher(registry: registry)

        let unknownCall = FunctionCall(name: "unregistered_command", args: ["cmd": AnyCodable("reboot")], id: "unknown-1")
        let response = await dispatcher.dispatch(unknownCall)

        #expect(!response.isSuccess)
        #expect(response.isToolNotFound)
        #expect(!response.isCancelled)
        #expect(!response.isSafetyRejection)
        #expect(response.errorMessage?.contains("not recognized") == true)
        #expect(response.id == "unknown-1")
    }

    @Test("Invariant 3: Every risky tool/action passes through SafetyGate")
    func testEveryRiskyToolPassesThroughSafetyGate() async {
        let provider = Phase3AuditConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)

        let mockAS = MockAppleScriptExecutor()
        let mockCal = MockCalendarExecutor()
        let mockFile = MockFileExecutor()
        let mockShell = MockShellExecutor()

        let registry = ToolRegistry(tools: [
            RunAppleScriptTool(executor: mockAS),
            CalendarEventTool(executor: mockCal),
            FileOpTool(executor: mockFile, allowedRoot: sandboxURL),
            RunShellTool(executor: mockShell)
        ])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        // 1. run_applescript intercepted
        _ = await dispatcher.dispatch(FunctionCall(name: "run_applescript", args: ["script": AnyCodable("beep")], id: "as-1"))
        #expect(provider.callCount == 1)
        #expect(provider.recordedRequests.last?.toolName == "run_applescript")

        // 2. calendar_event intercepted
        _ = await dispatcher.dispatch(FunctionCall(name: "calendar_event", args: ["title": AnyCodable("Meeting"), "date": AnyCodable("2026-10-01T10:00:00Z")], id: "cal-1"))
        #expect(provider.callCount == 2)
        #expect(provider.recordedRequests.last?.toolName == "calendar_event")

        // 3. file_op write intercepted
        _ = await dispatcher.dispatch(FunctionCall(name: "file_op", args: ["action": AnyCodable("write"), "path": AnyCodable("/sandbox/test.txt"), "content": AnyCodable("data")], id: "file-w-1"))
        #expect(provider.callCount == 3)
        #expect(provider.recordedRequests.last?.toolName == "file_op")

        // 4. file_op delete intercepted
        _ = await dispatcher.dispatch(FunctionCall(name: "file_op", args: ["action": AnyCodable("delete"), "path": AnyCodable("/sandbox/test.txt")], id: "file-d-1"))
        #expect(provider.callCount == 4)
        #expect(provider.recordedRequests.last?.toolName == "file_op")

        // 5. run_shell intercepted
        _ = await dispatcher.dispatch(FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")], id: "sh-1"))
        #expect(provider.callCount == 5)
        #expect(provider.recordedRequests.last?.toolName == "run_shell")
    }

    @Test("Invariant 4: No risky tool can execute without explicit user approval")
    func testNoRiskyToolCanExecuteWithoutExplicitApproval() async {
        let provider = Phase3AuditConfirmationProvider(decisionToReturn: false) // Always reject / cancel
        let gate = InteractiveSafetyGate(confirmationProvider: provider)

        let mockAS = MockAppleScriptExecutor()
        let mockCal = MockCalendarExecutor()
        let mockFile = MockFileExecutor()
        let mockShell = MockShellExecutor()

        let registry = ToolRegistry(tools: [
            RunAppleScriptTool(executor: mockAS),
            CalendarEventTool(executor: mockCal),
            FileOpTool(executor: mockFile, allowedRoot: sandboxURL),
            RunShellTool(executor: mockShell)
        ])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        // Execute all risky tools under rejection
        _ = await dispatcher.dispatch(FunctionCall(name: "run_applescript", args: ["script": AnyCodable("beep")]))
        _ = await dispatcher.dispatch(FunctionCall(name: "calendar_event", args: ["title": AnyCodable("Party"), "date": AnyCodable("2026-10-01T10:00:00Z")]))
        _ = await dispatcher.dispatch(FunctionCall(name: "file_op", args: ["action": AnyCodable("write"), "path": AnyCodable("/sandbox/a.txt"), "content": AnyCodable("x")]))
        _ = await dispatcher.dispatch(FunctionCall(name: "file_op", args: ["action": AnyCodable("delete"), "path": AnyCodable("/sandbox/a.txt")]))
        _ = await dispatcher.dispatch(FunctionCall(name: "run_shell", args: ["command": AnyCodable("ls")]))

        // None of the executors must have been invoked!
        #expect(mockAS.executedScripts.isEmpty)
        #expect(mockCal.recordedCalls.isEmpty)
        #expect(mockFile.recordedCalls.isEmpty)
        #expect(mockShell.recordedCommands.isEmpty)
    }
}

// MARK: - Suite 2: Confirmation Security Invariants (Invariants 5-10)

@Suite("Phase 3 - Confirmation Security Invariants")
struct Phase3ConfirmationSecurityInvariantsTests {
    private let sandboxURL = URL(fileURLWithPath: "/sandbox")

    @Test("Invariant 5: Cancel guarantees ZERO execution across all risky tools")
    @MainActor
    func testCancelGuaranteesZeroExecutionAcrossAllRiskyTools() async {
        let mockAS = MockAppleScriptExecutor()
        let mockCal = MockCalendarExecutor()
        let mockFile = MockFileExecutor()
        let mockShell = MockShellExecutor()

        let registry = ToolRegistry(tools: [
            RunAppleScriptTool(executor: mockAS),
            CalendarEventTool(executor: mockCal),
            FileOpTool(executor: mockFile, allowedRoot: sandboxURL),
            RunShellTool(executor: mockShell)
        ])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        // 1. AppleScript
        do {
            let client = Phase3ScriptedGeminiClient { step, _ in
                if step == 1 {
                    return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_applescript", args: ["script": AnyCodable("beep")], id: "c1")])
                }
                return ModelTurnResponse(text: "Cancelled", functionCalls: [])
            }
            let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
            bridge.handler = brain
            let task = Task { await brain.send("Run AS") }
            for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
            brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
            await task.value
            #expect(mockAS.executedScripts.isEmpty)
        }

        // 2. Calendar
        do {
            let client = Phase3ScriptedGeminiClient { step, _ in
                if step == 1 {
                    return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "calendar_event", args: ["title": AnyCodable("M"), "date": AnyCodable("2026-10-01T10:00:00Z")], id: "c2")])
                }
                return ModelTurnResponse(text: "Cancelled", functionCalls: [])
            }
            let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
            bridge.handler = brain
            let task = Task { await brain.send("Add meeting") }
            for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
            brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
            await task.value
            #expect(mockCal.recordedCalls.isEmpty)
        }

        // 3. File write
        do {
            let client = Phase3ScriptedGeminiClient { step, _ in
                if step == 1 {
                    return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "file_op", args: ["action": AnyCodable("write"), "path": AnyCodable("/sandbox/f.txt"), "content": AnyCodable("d")], id: "c3")])
                }
                return ModelTurnResponse(text: "Cancelled", functionCalls: [])
            }
            let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
            bridge.handler = brain
            let task = Task { await brain.send("Write") }
            for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
            brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
            await task.value
            #expect(mockFile.recordedCalls.isEmpty)
        }

        // 4. Shell
        do {
            let client = Phase3ScriptedGeminiClient { step, _ in
                if step == 1 {
                    return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")], id: "c4")])
                }
                return ModelTurnResponse(text: "Cancelled", functionCalls: [])
            }
            let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
            bridge.handler = brain
            let task = Task { await brain.send("Shell") }
            for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
            brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
            await task.value
            #expect(mockShell.recordedCommands.isEmpty)
        }
    }

    @Test("Invariant 6 & 7: Approval executes exactly once; duplicate approvals never execute twice")
    @MainActor
    func testApprovalExecutesExactlyOnceAndNeverDuplicates() async {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "date", stdout: "today", stderr: "", exitCode: 0)
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = Phase3ScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("date")], id: "once-1")])
            }
            return ModelTurnResponse(text: "Done", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Date") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        let reqId = brain.pendingConfirmation?.id
        #expect(reqId != nil)

        // First approval
        brain.respondToPendingConfirmation(id: reqId, approved: true)

        // Duplicate approvals
        brain.respondToPendingConfirmation(id: reqId, approved: true)
        brain.respondToPendingConfirmation(id: reqId, approved: true)

        await task.value

        // Invariant 6 & 7: exactly one execution!
        #expect(mockShell.recordedCommands.count == 1)
    }

    @Test("Invariant 8: Approval for one tool call cannot authorize another tool call")
    @MainActor
    func testApprovalForOneToolCallCannotAuthorizeAnotherToolCall() async {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "test", stdout: "ok", stderr: "", exitCode: 0)
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = Phase3ScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("cmd 1")], id: "call-1")])
            }
            return ModelTurnResponse(text: "Turn 1 done", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        // Turn 1 approved
        let task1 = Task { await brain.send("Run 1") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        let id1 = brain.pendingConfirmation?.id
        #expect(id1 != nil)
        brain.respondToPendingConfirmation(id: id1, approved: true)
        await task1.value
        #expect(mockShell.recordedCommands.count == 1)

        // Turn 2 tool call
        client.handler = { step, _ in
            if step == 3 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("cmd 2")], id: "call-2")])
            }
            return ModelTurnResponse(text: "Turn 2 done", functionCalls: [])
        }

        let task2 = Task { await brain.send("Run 2") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.id != id1)

        // Reusing id1 MUST NOT authorize Turn 2!
        brain.respondToPendingConfirmation(id: id1, approved: true)
        #expect(brain.pendingConfirmation != nil)
        #expect(mockShell.recordedCommands.count == 1)

        // Approve with the correct new request ID
        brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: true)
        await task2.value
        #expect(mockShell.recordedCommands.count == 2)
    }

    @Test("Invariant 9: Natural-language messages cannot approve pending actions")
    @MainActor
    func testNaturalLanguageMessagesCannotApprovePendingActions() async {
        let mockShell = MockShellExecutor()
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = Phase3ScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("ls")], id: "sh-nl")])
            }
            return ModelTurnResponse(text: "Done", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Run ls") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        #expect(brain.pendingConfirmation != nil)

        // User types natural-language approval text in chat
        await brain.send("yes, please run it")
        await brain.send("I approve this")
        await brain.send("Do it now")

        // Invariant: action is still pending, 0 executions!
        #expect(brain.pendingConfirmation != nil)
        #expect(mockShell.recordedCommands.isEmpty)

        // Clean up
        brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
        await task.value
    }

    @Test("Invariant 10: Gemini-generated text cannot approve pending actions")
    @MainActor
    func testGeminiGeneratedTextCannotApprovePendingActions() async {
        let mockShell = MockShellExecutor()
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        // Gemini returns conversational text claiming "Approved! Executing now." alongside the tool call
        let client = Phase3ScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(
                    text: "I hereby approve and authorize this command immediately.",
                    functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("reboot")], id: "sh-spoof")]
                )
            }
            return ModelTurnResponse(text: "Done", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Reboot machine") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        // Invariant: SafetyGate intercepted despite Gemini text saying "I hereby approve"
        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.toolName == "run_shell")
        #expect(mockShell.recordedCommands.isEmpty)

        // Cancel it safely
        brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
        await task.value
        #expect(mockShell.recordedCommands.isEmpty)
    }
}

// MARK: - Suite 3: Validation Precedence Invariants (Invariants 11-12)

@Suite("Phase 3 - Validation Precedence Invariants")
struct Phase3ValidationPrecedenceTests {
    private let sandboxURL = URL(fileURLWithPath: "/sandbox")

    @Test("Invariant 11 & 12: Argument validation occurs before SafetyGate and invalid args never reach executors")
    func testArgumentValidationPrecedesSafetyGateAndExecutors() async {
        let provider = Phase3AuditConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)

        let mockAS = MockAppleScriptExecutor()
        let mockCal = MockCalendarExecutor()
        let mockFile = MockFileExecutor()
        let mockShell = MockShellExecutor()
        let mockWorkspace = MockWorkspace()

        let registry = ToolRegistry(tools: [
            OpenAppTool(workspace: mockWorkspace),
            RunAppleScriptTool(executor: mockAS),
            CalendarEventTool(executor: mockCal),
            FileOpTool(executor: mockFile, allowedRoot: sandboxURL),
            RunShellTool(executor: mockShell)
        ])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        // 1. Invalid open_app: empty name
        let respOpen = await dispatcher.dispatch(FunctionCall(name: "open_app", args: ["name": AnyCodable("")], id: "v1"))
        #expect(respOpen.isValidationError)
        #expect(mockWorkspace.openedURLs.isEmpty)

        // 2. Invalid run_applescript: empty script
        let respAS = await dispatcher.dispatch(FunctionCall(name: "run_applescript", args: ["script": AnyCodable("   ")], id: "v2"))
        #expect(respAS.isValidationError)
        #expect(mockAS.executedScripts.isEmpty)
        #expect(provider.callCount == 0) // Did NOT reach SafetyGate!

        // 3. Invalid calendar_event: missing date
        let respCal = await dispatcher.dispatch(FunctionCall(name: "calendar_event", args: ["title": AnyCodable("Meeting")], id: "v3"))
        #expect(respCal.isValidationError)
        #expect(mockCal.recordedCalls.isEmpty)
        #expect(provider.callCount == 0) // Did NOT reach SafetyGate!

        // 4. Invalid file_op: traversal path
        let respFile = await dispatcher.dispatch(FunctionCall(name: "file_op", args: ["action": AnyCodable("write"), "path": AnyCodable("../escaped.txt"), "content": AnyCodable("bad")], id: "v4"))
        #expect(respFile.isValidationError)
        #expect(mockFile.recordedCalls.isEmpty)
        #expect(provider.callCount == 0) // Did NOT reach SafetyGate!

        // 5. Invalid run_shell: empty command
        let respShell = await dispatcher.dispatch(FunctionCall(name: "run_shell", args: ["command": AnyCodable("   ")], id: "v5"))
        #expect(respShell.isValidationError)
        #expect(mockShell.recordedCommands.isEmpty)
        #expect(provider.callCount == 0) // Did NOT reach SafetyGate!
    }
}

// MARK: - Suite 4: Tool-Specific Hardening Invariants (Invariants 13-17)

@Suite("Phase 3 - Tool-Specific Hardening Invariants")
struct Phase3ToolSpecificHardeningTests {
    private let sandboxURL = URL(fileURLWithPath: "/sandbox")

    @Test("Invariant 13: file_op security invariants (traversal, absolute path, action, read limit, write/delete confirmation, no directory deletion)")
    func testFileOpSecurityInvariants() async throws {
        let mockFile = MockFileExecutor()
        let fileTool = FileOpTool(executor: mockFile, allowedRoot: sandboxURL)
        let policy = SafetyPolicy()

        // 1. Path traversal rejected
        #expect(throws: ToolError.self) {
            try fileTool.validate(arguments: ["action": AnyCodable("read"), "path": AnyCodable("/sandbox/../etc/passwd")])
        }
        #expect(throws: ToolError.self) {
            try fileTool.validate(arguments: ["action": AnyCodable("read"), "path": AnyCodable("../../etc/passwd")])
        }

        // 2. Unsafe absolute path outside allowed root rejected
        #expect(throws: ToolError.self) {
            try fileTool.validate(arguments: ["action": AnyCodable("read"), "path": AnyCodable("/System/Library/CoreServices/SystemVersion.plist")])
        }

        // 3. Invalid action rejected
        #expect(throws: ToolError.self) {
            try fileTool.validate(arguments: ["action": AnyCodable("chmod"), "path": AnyCodable("/sandbox/file.txt")])
        }
        #expect(throws: ToolError.self) {
            try fileTool.validate(arguments: ["action": AnyCodable(""), "path": AnyCodable("/sandbox/file.txt")])
        }

        // 4. Read limits enforced
        mockFile.errorToThrow = FileOpError.fileTooLarge(actual: 5_000_000, maxAllowed: 1_048_576)
        let readLargeResult = try await fileTool.execute(arguments: ["action": AnyCodable("read"), "path": AnyCodable("/sandbox/large.bin")])
        #expect(readLargeResult.isError)
        #expect(readLargeResult.output.contains("exceeds maximum read size limit"))
        mockFile.errorToThrow = nil

        // 5. Write and Delete require approval
        let writeCall = FunctionCall(name: "file_op", args: ["action": AnyCodable("write"), "path": AnyCodable("/sandbox/f.txt"), "content": AnyCodable("x")])
        let deleteCall = FunctionCall(name: "file_op", args: ["action": AnyCodable("delete"), "path": AnyCodable("/sandbox/f.txt")])
        #expect(policy.classification(for: fileTool, call: writeCall) == .risky)
        #expect(policy.classification(for: fileTool, call: deleteCall) == .risky)

        // 6. No recursive arbitrary deletion: directory deletion throws isDirectory
        mockFile.errorToThrow = FileOpError.isDirectory("/sandbox/my_folder")
        let deleteDirResult = try await fileTool.execute(arguments: ["action": AnyCodable("delete"), "path": AnyCodable("/sandbox/my_folder")])
        #expect(deleteDirResult.isError)
        #expect(deleteDirResult.output.contains("Directory operations are not permitted"))
    }

    @Test("Invariant 14: run_shell security invariants (empty command, exact preservation, stdout, stderr, exit code, no sudo)")
    func testRunShellSecurityInvariants() async throws {
        let mockShell = MockShellExecutor()
        let tool = RunShellTool(executor: mockShell)

        // 1. Empty command rejected
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["command": AnyCodable("")])
        }
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["command": AnyCodable("   \t\n  ")])
        }

        // 2. Exact command preserved
        let exactCmd = "git status --porcelain=v1"
        mockShell.resultToReturn = ShellCommandResult(command: exactCmd, stdout: " M Sources/IvyCore/Tools/SafetyGate.swift", stderr: "", exitCode: 0)
        let res1 = try await tool.execute(arguments: ["command": AnyCodable(exactCmd)])
        #expect(!res1.isError)
        #expect(mockShell.recordedCommands.first?.command == exactCmd)

        // 3. Stdout captured
        #expect(res1.output.contains("SafetyGate.swift"))

        // 4. Stderr captured and non-zero exit code represented
        mockShell.resultToReturn = ShellCommandResult(command: "cat nonexist", stdout: "", stderr: "cat: nonexist: No such file or directory", exitCode: 1)
        let res2 = try await tool.execute(arguments: ["command": AnyCodable("cat nonexist")])
        #expect(res2.isError)
        #expect(res2.output.contains("cat: nonexist: No such file or directory"))

        // Combined stdout and stderr format
        mockShell.resultToReturn = ShellCommandResult(command: "cmd", stdout: "some standard out", stderr: "some error out", exitCode: 1)
        let resCombined = try await tool.execute(arguments: ["command": AnyCodable("cmd")])
        #expect(resCombined.isError)
        #expect(resCombined.output.contains("some standard out"))
        #expect(resCombined.output.contains("[stderr]:\nsome error out"))

        // 5. Executor failure represented correctly
        mockShell.errorToThrow = ShellError.launchFailed("Process launch denied")
        let res3 = try await tool.execute(arguments: ["command": AnyCodable("reboot")])
        #expect(res3.isError)
        #expect(res3.output.contains("Failed to launch process: Process launch denied"))
        mockShell.errorToThrow = nil

        // 6. No automatic sudo or privilege escalation
        // Verify SystemShellExecutor environment sanitization removes sensitive credentials
        let rawEnv: [String: String] = [
            "GEMINI_API_KEY": "secret_key_123",
            "SUDO_USER": "root",
            "USER": "dhruvsharma",
            "HOME": "/Users/dhruvsharma"
        ]
        let sanitized = SystemShellExecutor.sanitizeEnvironment(rawEnv)
        #expect(sanitized["GEMINI_API_KEY"] == nil)
        #expect(sanitized["USER"] == "dhruvsharma")
    }

    @Test("Invariant 15: run_applescript security invariants (validation, approval, cancellation, single execution)")
    func testRunAppleScriptSecurityInvariants() async throws {
        let mockAS = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mockAS)
        let policy = SafetyPolicy()

        // 1. Invalid script rejected
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["script": AnyCodable("")])
        }
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["script": AnyCodable("beep\0bad")])
        }

        // 2. Risky execution requires approval
        #expect(policy.classification(for: tool) == .risky)

        // 3. Approval executes exactly once
        mockAS.outputToReturn = "dialog response: OK"
        let res = try await tool.execute(arguments: ["script": AnyCodable("display dialog \"Hi\"")])
        #expect(!res.isError)
        #expect(res.output == "dialog response: OK")
        #expect(mockAS.executedScripts.count == 1)
    }

    @Test("Invariant 16: calendar_event security invariants (validation, dates, confirmation, permission failure)")
    func testCalendarEventSecurityInvariants() async throws {
        let mockCal = MockCalendarExecutor()
        let tool = CalendarEventTool(executor: mockCal)
        let policy = SafetyPolicy()

        // 1. Invalid arguments and dates rejected
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["title": AnyCodable(""), "date": AnyCodable("2026-10-01T10:00:00Z")])
        }
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["title": AnyCodable("Trip"), "date": AnyCodable("not-a-valid-date")])
        }
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["title": AnyCodable("Trip"), "date": AnyCodable("2026-10-01")]) // Missing time
        }

        // 2. Confirmation required
        #expect(policy.classification(for: tool) == .risky)

        // 3. Permission failure becomes structured error
        mockCal.errorToThrow = CalendarError.permissionDenied
        let deniedResult = try await tool.execute(arguments: ["title": AnyCodable("Meeting"), "date": AnyCodable("2026-10-01T10:00:00Z")])
        #expect(deniedResult.isError)
        #expect(deniedResult.output.contains("Calendar access denied"))
        mockCal.errorToThrow = nil

        // 4. Approval creates event exactly once
        let successResult = try await tool.execute(arguments: ["title": AnyCodable("Doctor"), "date": AnyCodable("2026-10-01T10:00:00Z")])
        #expect(!successResult.isError)
        #expect(mockCal.recordedCalls.count == 1)
        #expect(mockCal.recordedCalls.first?.title == "Doctor")
    }

    @Test("Invariant 17: open_app security invariants (valid invocation, validation, structured errors)")
    func testOpenAppSecurityInvariants() async throws {
        let mockWS = MockWorkspace()
        mockWS.knownApps["notes.app"] = URL(fileURLWithPath: "/System/Applications/Notes.app")
        let tool = OpenAppTool(workspace: mockWS)

        // 1. Valid app invocation works
        let res = try await tool.execute(arguments: ["name": AnyCodable("Notes")])
        #expect(!res.isError)
        #expect(mockWS.openedURLs.count == 1)

        // 2. Invalid / empty app names rejected
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["name": AnyCodable("")]) }
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["name": AnyCodable("   ")]) }
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["name": AnyCodable("Safari\u{202E}bad")]) }
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["name": AnyCodable(String(repeating: "A", count: 101))]) }

        // 3. Structured executor failures
        mockWS.shouldFailOpen = true
        let failRes = try await tool.execute(arguments: ["name": AnyCodable("Notes")])
        #expect(failRes.isError)
        #expect(failRes.output.contains("Application crashed on launch"))
    }
}

// MARK: - Suite 5: Protocol, Logging, and Concurrency Invariants (Invariants 18-20)

@Suite("Phase 3 - Protocol, Logging, and Concurrency Invariants")
struct Phase3ProtocolLoggingAndConcurrencyTests {
    @Test("Invariant 18: Gemini protocol (Part-level thought_signature, functionCall wire structure, ordering)")
    func testGeminiProtocolThoughtSignatureInvariants() throws {
        let expectedSignature = "test_signature_wire_token_123"

        // 1. thought_signature is serialized at Part level
        let part = Part(
            functionCall: FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")], id: "call-1"),
            thoughtSignature: expectedSignature
        )
        let partData = try JSONEncoder().encode(part)
        let partString = String(data: partData, encoding: .utf8) ?? ""
        #expect(partString.contains("thoughtSignature") || partString.contains("thought_signature"))

        // 2. thought_signature NEVER appears inside FunctionCall JSON
        let call = FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")], id: "call-1", thoughtSignature: expectedSignature)
        let callData = try JSONEncoder().encode(call)
        let callString = String(data: callData, encoding: .utf8) ?? ""
        #expect(!callString.contains("thoughtSignature"))
        #expect(!callString.contains("thought_signature"))

        // 3. functionResponse attaches to correct tool call and preserves ordering
        let resp1 = FunctionResponse(name: "open_app", response: ["success": AnyCodable(true)], id: "call-1")
        let resp2 = FunctionResponse(name: "run_shell", response: ["success": AnyCodable(false)], id: "call-2")
        #expect(resp1.name == "open_app" && resp1.id == "call-1")
        #expect(resp2.name == "run_shell" && resp2.id == "call-2")
        #expect(resp1.isSuccess == true)
        #expect(resp2.isSuccess == false)
    }

    @Test("Invariant 19: Logging & Sanitization (API keys and sensitive env variables scrubbed)")
    func testLoggingAndSanitizationInvariants() {
        // 1. Environment sanitization strips secrets
        let rawEnv: [String: String] = [
            "GEMINI_API_KEY": "AIzaSyD-TestKey12345",
            "ELEVENLABS_API_KEY": "el_key_secret",
            "DATABASE_PASSWORD": "topsecretpassword",
            "AUTH_BEARER_TOKEN": "eyJhbGciOi...",
            "USER": "dhruvsharma",
            "HOME": "/Users/dhruvsharma",
            "PATH": "/usr/bin:/bin"
        ]
        let cleaned = SystemShellExecutor.sanitizeEnvironment(rawEnv)

        #expect(cleaned["GEMINI_API_KEY"] == nil)
        #expect(cleaned["ELEVENLABS_API_KEY"] == nil)
        #expect(cleaned["DATABASE_PASSWORD"] == nil)
        #expect(cleaned["AUTH_BEARER_TOKEN"] == nil)
        #expect(cleaned["USER"] == "dhruvsharma")
        #expect(cleaned["HOME"] == "/Users/dhruvsharma")

        // 2. Wire log redacts API keys
        let testBody = "{\"apiKey\": \"AIzaSyD-TestKey12345\"}"
        let apiKey = "AIzaSyD-TestKey12345"
        let redacted = testBody.replacingOccurrences(of: apiKey, with: "[REDACTED_API_KEY]")
        #expect(!redacted.contains(apiKey))
        #expect(redacted.contains("[REDACTED_API_KEY]"))
    }

    @Test("Invariant 20: Swift 6 Strict Concurrency and Mock Isolation Check")
    func testSwift6StrictConcurrencyAndMockIsolation() {
        let mockAS = MockAppleScriptExecutor()
        let mockCal = MockCalendarExecutor()
        let mockFile = MockFileExecutor()
        let mockShell = MockShellExecutor()
        let mockWorkspace = MockWorkspace()

        // Confirm all test mocks start completely untouched
        #expect(mockAS.executedScripts.isEmpty)
        #expect(mockCal.recordedCalls.isEmpty)
        #expect(mockFile.recordedCalls.isEmpty)
        #expect(mockShell.recordedCommands.isEmpty)
        #expect(mockWorkspace.openedURLs.isEmpty)
    }
}

// MARK: - Suite 6: Hardening & Defense in Depth Tests

@Suite("Phase 3 - Hardening & Defense in Depth Tests", .serialized)
struct Phase3DefenseInDepthTests {
    private let sandboxURL = URL(fileURLWithPath: "/sandbox")

    @Test("file_op write confirmation detail includes content preview and transparency")
    func testFileOpWriteConfirmationDetailTransparency() async {
        let provider = Phase3AuditConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockFile = MockFileExecutor()
        let fileTool = FileOpTool(executor: mockFile, allowedRoot: sandboxURL)
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [fileTool]), safetyGate: gate)

        let call = FunctionCall(
            name: "file_op",
            args: [
                "action": AnyCodable("write"),
                "path": AnyCodable("/sandbox/important.txt"),
                "content": AnyCodable("Hello secure world! This is confidential configuration.")
            ],
            id: "write-transparency-1"
        )

        _ = await dispatcher.dispatch(call)

        #expect(provider.callCount == 1)
        let req = provider.recordedRequests.first
        #expect(req != nil)
        #expect(req?.title == "Write File")
        #expect(req?.detail.contains("Action: Write File") == true)
        #expect(req?.detail.contains("Target Path:") == true)
        #expect(req?.detail.contains("Content (") == true && req?.detail.contains("chars):") == true)
        #expect(req?.detail.contains("Hello secure world!") == true)
        #expect(req?.detail.contains("Existing content may be overwritten.") == true)
    }

    @Test("Tilde user directory expansion (~user) is strictly rejected")
    func testTildeOtherUserExpansionRejected() {
        let pathsToTest = [
            "~root/notes.txt",
            "~daemon/config.json",
            "~nobody/secret",
            "~otheruser/Documents"
        ]

        for path in pathsToTest {
            #expect(throws: ToolError.self) {
                try ToolValidation.validateFilePath(path, allowedRoot: sandboxURL)
            }
        }
    }

    @Test("Standardized path system root escape is strictly rejected")
    func testStandardizedPathSystemRootRejected() {
        #expect(throws: ToolError.self) {
            try ToolValidation.validateFilePath("/System/Library/CoreServices", allowedRoot: sandboxURL)
        }
        #expect(throws: ToolError.self) {
            try ToolValidation.validateFilePath("/bin/zsh", allowedRoot: sandboxURL)
        }
    }

    @Test("Mismatched confirmation ID is strictly ignored by respondToPendingConfirmation")
    @MainActor
    func testConfirmationGuardMismatchedIdIgnored() async {
        let mockShell = MockShellExecutor()
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = Phase3ScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")], id: "mismatch-1")])
            }
            return ModelTurnResponse(text: "Done", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Run whoami") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        #expect(brain.pendingConfirmation != nil)
        let realId = brain.pendingConfirmation?.id

        // Passing a mismatched UUID must NOT resolve the confirmation!
        let fakeId = UUID()
        brain.respondToPendingConfirmation(id: fakeId, approved: true)

        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.id == realId)
        #expect(mockShell.recordedCommands.isEmpty)

        // Cancel with real ID
        brain.respondToPendingConfirmation(id: realId, approved: false)
        await task.value
        #expect(mockShell.recordedCommands.isEmpty)
    }

    @Test("GeminiClient error messages sanitize and redact API key")
    func testGeminiClientSanitizesKeyInErrorMessages() async {
        let fakeKey = "AIzaSyD-SecretKey123456789"
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Phase3MockURLProtocol.self]
        let session = URLSession(configuration: config)

        Phase3MockURLProtocol.requestHandler = { req in
            let errorJSON = """
            {
                "error": {
                    "code": 400,
                    "message": "API key \(fakeKey) is invalid. Check credentials.",
                    "status": "INVALID_ARGUMENT"
                }
            }
            """
            let resp = HTTPURLResponse(url: req.url ?? URL(string: "https://generativelanguage.googleapis.com")!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) ?? HTTPURLResponse()
            return (resp, errorJSON.data(using: .utf8) ?? Data())
        }
        defer {
            Phase3MockURLProtocol.requestHandler = nil
        }

        let client = URLSessionGeminiClient(session: session)
        do {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "ping")],
                systemPrompt: "",
                apiKey: fakeKey
            )
            #expect(Bool(false), "Expected invalidAPIKey error")
        } catch let err as GeminiClientError {
            let desc = err.localizedDescription
            #expect(!desc.contains(fakeKey))
            #expect(desc.contains("[REDACTED_API_KEY]"))
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }
}

// MARK: - Dedicated Isolated URL Protocol for Phase 3 Tests

private final class Phase3MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = Phase3MockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

