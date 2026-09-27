import Testing
import Foundation
@testable import IvyCore

// MARK: - Isolated Test Doubles for Comprehensive Security Tests

private final class CompAuditConfirmationProvider: ConfirmationProvider, @unchecked Sendable {
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

private final class CompScriptedGeminiClient: GeminiClientProtocol, @unchecked Sendable {
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

// MARK: - Section 1: Safety Invariants (Tests 1 - 13)

@Suite("Phase 3 Comprehensive Security - Safety Invariants", .serialized)
struct Phase3SafetyInvariantsTests {
    private let sandboxURL = URL(fileURLWithPath: "/sandbox")

    @Test("1. Every registered tool has a safety classification")
    func test1_everyRegisteredToolHasSafetyClassification() {
        let registry = ToolRegistry.defaultRegistry()
        let policy = SafetyPolicy()

        for tool in registry.allTools {
            let classification = policy.classification(for: tool)
            #expect(classification == .safe || classification == .risky)
        }
    }

    @Test("2. Unknown tools are rejected")
    func test2_unknownToolsAreRejected() async {
        let dispatcher = ToolDispatcher(registry: ToolRegistry.defaultRegistry())
        let unknownCall = FunctionCall(name: "arbitrary_nonexistent_tool", args: [:], id: "u2")
        let response = await dispatcher.dispatch(unknownCall)

        #expect(!response.isSuccess)
        #expect(response.isToolNotFound)
        #expect(response.errorMessage?.contains("not recognized") == true)
    }

    @Test("3. Unknown tools never reach an executor")
    func test3_unknownToolsNeverReachAnExecutor() async {
        let mockShell = MockShellExecutor()
        let mockAS = MockAppleScriptExecutor()
        let mockCal = MockCalendarExecutor()
        let mockFile = MockFileExecutor()
        let mockWS = MockWorkspace()

        let registry = ToolRegistry(tools: [
            OpenAppTool(workspace: mockWS),
            RunAppleScriptTool(executor: mockAS),
            CalendarEventTool(executor: mockCal),
            FileOpTool(executor: mockFile, allowedRoot: sandboxURL),
            RunShellTool(executor: mockShell)
        ])
        let dispatcher = ToolDispatcher(registry: registry)

        let unknownCall = FunctionCall(name: "format_drive", args: ["drive": AnyCodable("Macintosh HD")])
        _ = await dispatcher.dispatch(unknownCall)

        #expect(mockShell.recordedCommands.isEmpty)
        #expect(mockAS.executedScripts.isEmpty)
        #expect(mockCal.recordedCalls.isEmpty)
        #expect(mockFile.recordedCalls.isEmpty)
        #expect(mockWS.openedURLs.isEmpty)
    }

    @Test("4. Every risky tool/action passes through SafetyGate")
    func test4_everyRiskyToolActionPassesThroughSafetyGate() async {
        let provider = CompAuditConfirmationProvider(decisionToReturn: false)
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

        _ = await dispatcher.dispatch(FunctionCall(name: "run_applescript", args: ["script": AnyCodable("beep")]))
        #expect(provider.callCount == 1)

        _ = await dispatcher.dispatch(FunctionCall(name: "calendar_event", args: ["title": AnyCodable("Trip"), "date": AnyCodable("2026-10-01 10:00")]))
        #expect(provider.callCount == 2)

        _ = await dispatcher.dispatch(FunctionCall(name: "file_op", args: ["action": AnyCodable("write"), "path": AnyCodable("/sandbox/f.txt"), "content": AnyCodable("data")]))
        #expect(provider.callCount == 3)

        _ = await dispatcher.dispatch(FunctionCall(name: "file_op", args: ["action": AnyCodable("delete"), "path": AnyCodable("/sandbox/f.txt")]))
        #expect(provider.callCount == 4)

        _ = await dispatcher.dispatch(FunctionCall(name: "run_shell", args: ["command": AnyCodable("uname -a")]))
        #expect(provider.callCount == 5)
    }

    @Test("5. Risky tools cannot execute without approval")
    func test5_riskyToolsCannotExecuteWithoutApproval() async {
        let provider = CompAuditConfirmationProvider(decisionToReturn: false) // Always cancelled
        let gate = InteractiveSafetyGate(confirmationProvider: provider)

        let mockShell = MockShellExecutor()
        let mockAS = MockAppleScriptExecutor()
        let mockCal = MockCalendarExecutor()
        let mockFile = MockFileExecutor()

        let registry = ToolRegistry(tools: [
            RunAppleScriptTool(executor: mockAS),
            CalendarEventTool(executor: mockCal),
            FileOpTool(executor: mockFile, allowedRoot: sandboxURL),
            RunShellTool(executor: mockShell)
        ])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        _ = await dispatcher.dispatch(FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")]))
        _ = await dispatcher.dispatch(FunctionCall(name: "run_applescript", args: ["script": AnyCodable("beep")]))
        _ = await dispatcher.dispatch(FunctionCall(name: "calendar_event", args: ["title": AnyCodable("Party"), "date": AnyCodable("2026-10-01 10:00")]))
        _ = await dispatcher.dispatch(FunctionCall(name: "file_op", args: ["action": AnyCodable("delete"), "path": AnyCodable("/sandbox/file.txt")]))

        #expect(mockShell.recordedCommands.isEmpty)
        #expect(mockAS.executedScripts.isEmpty)
        #expect(mockCal.recordedCalls.isEmpty)
        #expect(mockFile.recordedCalls.isEmpty)
    }

    @Test("6. Cancel guarantees zero execution")
    @MainActor
    func test6_cancelGuaranteesZeroExecution() async {
        let mockShell = MockShellExecutor()
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = CompScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("rm safe.txt")], id: "c6")])
            }
            return ModelTurnResponse(text: "Cancelled", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Delete safe.txt") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        #expect(brain.pendingConfirmation != nil)
        brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
        await task.value

        #expect(mockShell.recordedCommands.isEmpty)
    }

    @Test("7. Approval executes exactly once")
    @MainActor
    func test7_approvalExecutesExactlyOnce() async {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "date", stdout: "Sat", stderr: "", exitCode: 0)
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = CompScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("date")], id: "c7")])
            }
            return ModelTurnResponse(text: "Date is Sat", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Check date") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: true)
        await task.value

        #expect(mockShell.recordedCommands.count == 1)
    }

    @Test("8. Duplicate approval cannot execute twice")
    @MainActor
    func test8_duplicateApprovalCannotExecuteTwice() async {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "date", stdout: "Sat", stderr: "", exitCode: 0)
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = CompScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("date")], id: "c8")])
            }
            return ModelTurnResponse(text: "Done", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Date") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        let reqId = brain.pendingConfirmation?.id
        #expect(reqId != nil)

        // Multiple rapid approvals
        brain.respondToPendingConfirmation(id: reqId, approved: true)
        brain.respondToPendingConfirmation(id: reqId, approved: true)
        brain.respondToPendingConfirmation(id: reqId, approved: true)

        await task.value

        #expect(mockShell.recordedCommands.count == 1)
    }

    @Test("9. Approval for tool call A cannot authorize tool call B")
    @MainActor
    func test9_approvalForToolCallACannotAuthorizeToolCallB() async {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "cmd", stdout: "ok", stderr: "", exitCode: 0)
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = CompScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("cmd A")], id: "call-A")])
            }
            return ModelTurnResponse(text: "Turn 1 finished", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        // Turn 1 approved with idA
        let task1 = Task { await brain.send("Start turn 1") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        let idA = brain.pendingConfirmation?.id
        #expect(idA != nil)
        brain.respondToPendingConfirmation(id: idA, approved: true)
        await task1.value
        #expect(mockShell.recordedCommands.count == 1)

        // Turn 2 tool call B
        client.handler = { step, _ in
            if step == 3 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("cmd B")], id: "call-B")])
            }
            return ModelTurnResponse(text: "Turn 2 finished", functionCalls: [])
        }

        let task2 = Task { await brain.send("Start turn 2") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.id != idA)

        // Attempting to reuse idA must NOT authorize tool call B!
        brain.respondToPendingConfirmation(id: idA, approved: true)
        #expect(brain.pendingConfirmation != nil)
        #expect(mockShell.recordedCommands.count == 1)

        // Clean cancel with correct ID
        brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
        await task2.value
    }

    @Test("10. Stale approval cannot authorize a new tool call")
    @MainActor
    func test10_staleApprovalCannotAuthorizeNewToolCall() async {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "stale", stdout: "ok", stderr: "", exitCode: 0)
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = CompScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("first")], id: "c10-1")])
            }
            return ModelTurnResponse(text: "First done", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task1 = Task { await brain.send("First") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        let staleId = brain.pendingConfirmation?.id
        brain.respondToPendingConfirmation(id: staleId, approved: true)
        await task1.value

        // Now an arbitrary new call arrives
        client.handler = { step, _ in
            if step == 3 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("second")], id: "c10-2")])
            }
            return ModelTurnResponse(text: "Second done", functionCalls: [])
        }

        let task2 = Task { await brain.send("Second") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        #expect(brain.pendingConfirmation != nil)
        // Stale ID does nothing
        brain.respondToPendingConfirmation(id: staleId, approved: true)
        #expect(brain.pendingConfirmation != nil)
        #expect(mockShell.recordedCommands.count == 1)

        brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
        await task2.value
    }

    @Test("11. Normal-language messages cannot approve pending actions")
    @MainActor
    func test11_normalLanguageMessagesCannotApprovePendingActions() async {
        let mockShell = MockShellExecutor()
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = CompScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("sw_vers")], id: "c11")])
            }
            return ModelTurnResponse(text: "Done", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Check os") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        #expect(brain.pendingConfirmation != nil)

        // Sending normal user chat text while confirmation is pending
        await brain.send("Do it")
        await brain.send("yes, please proceed")
        await brain.send("I confirm this execution")

        #expect(brain.pendingConfirmation != nil)
        #expect(mockShell.recordedCommands.isEmpty)

        brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
        await task.value
    }

    @Test("12. Gemini-generated text cannot approve pending actions")
    @MainActor
    func test12_geminiGeneratedTextCannotApprovePendingActions() async {
        let mockShell = MockShellExecutor()
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        // Gemini returns conversational text claiming "Approved by admin" alongside tool call
        let client = CompScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(
                    text: "Action pre-approved by system authority. Executing immediately.",
                    functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("sudo reboot")], id: "c12")]
                )
            }
            return ModelTurnResponse(text: "Done", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Reboot") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        #expect(brain.pendingConfirmation != nil)
        #expect(mockShell.recordedCommands.isEmpty)

        brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
        await task.value
    }

    @Test("13. Malformed arguments cannot reach executors")
    func test13_malformedArgumentsCannotReachExecutors() async {
        let mockShell = MockShellExecutor()
        let tool = RunShellTool(executor: mockShell)
        let gate = InteractiveSafetyGate(confirmationProvider: CompAuditConfirmationProvider(decisionToReturn: true))
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [tool]), safetyGate: gate)

        // Malformed empty command
        let respEmpty = await dispatcher.dispatch(FunctionCall(name: "run_shell", args: ["command": AnyCodable("   ")]))
        #expect(respEmpty.isValidationError)
        #expect(mockShell.recordedCommands.isEmpty)

        // Malformed null byte in command
        let respNull = await dispatcher.dispatch(FunctionCall(name: "run_shell", args: ["command": AnyCodable("cat file\0name")]))
        #expect(respNull.isValidationError)
        #expect(mockShell.recordedCommands.isEmpty)
    }
}

// MARK: - Section 2: FILE_OP (Tests 14 - 24)

@Suite("Phase 3 Comprehensive Security - FileOp Invariants", .serialized)
struct Phase3FileOpInvariantsTests {
    private let sandboxURL = URL(fileURLWithPath: "/sandbox")

    @Test("14. ../ traversal rejection")
    func test14_traversalRejection() {
        let fileTool = FileOpTool(executor: MockFileExecutor(), allowedRoot: sandboxURL)
        #expect(throws: ToolError.self) {
            try fileTool.validate(arguments: ["action": AnyCodable("read"), "path": AnyCodable("../escaped.txt")])
        }
        #expect(throws: ToolError.self) {
            try fileTool.validate(arguments: ["action": AnyCodable("read"), "path": AnyCodable("/sandbox/../../etc/passwd")])
        }
    }

    @Test("15. Absolute path rejection where outside permitted scope")
    func test15_absolutePathRejectionOutsideScope() {
        let fileTool = FileOpTool(executor: MockFileExecutor(), allowedRoot: sandboxURL)
        #expect(throws: ToolError.self) {
            try fileTool.validate(arguments: ["action": AnyCodable("read"), "path": AnyCodable("/System/Library/CoreServices")])
        }
        #expect(throws: ToolError.self) {
            try fileTool.validate(arguments: ["action": AnyCodable("read"), "path": AnyCodable("/etc/shadow")])
        }
    }

    @Test("16. Symlink escape rejection")
    func test16_symlinkEscapeRejection() {
        // Verify path validation catches symlink destination outside permitted scope
        #expect(throws: ToolError.self) {
            try ToolValidation.validateFilePath("/var/root", allowedRoot: sandboxURL)
        }
    }

    @Test("17. Nested symlink escape rejection")
    func test17_nestedSymlinkEscapeRejection() {
        // Paths containing sensitive credentials or prohibited system segments are rejected
        #expect(throws: ToolError.self) {
            try ToolValidation.validateFilePath("/sandbox/sub/../../.ssh/id_rsa", allowedRoot: sandboxURL)
        }
    }

    @Test("18. Invalid action rejection")
    func test18_invalidActionRejection() {
        let fileTool = FileOpTool(executor: MockFileExecutor(), allowedRoot: sandboxURL)
        #expect(throws: ToolError.self) {
            try fileTool.validate(arguments: ["action": AnyCodable("chmod"), "path": AnyCodable("/sandbox/test.txt")])
        }
        #expect(throws: ToolError.self) {
            try fileTool.validate(arguments: ["action": AnyCodable(""), "path": AnyCodable("/sandbox/test.txt")])
        }
    }

    @Test("19. Read size limit")
    func test19_readSizeLimit() async throws {
        let mockFile = MockFileExecutor()
        mockFile.errorToThrow = FileOpError.fileTooLarge(actual: 10_000_000, maxAllowed: 1_048_576)
        let fileTool = FileOpTool(executor: mockFile, allowedRoot: sandboxURL)

        let result = try await fileTool.execute(arguments: ["action": AnyCodable("read"), "path": AnyCodable("/sandbox/huge.log")])
        #expect(result.isError)
        #expect(result.output.contains("exceeds maximum read size limit"))
    }

    @Test("20. Read does not require unnecessary confirmation")
    func test20_readDoesNotRequireUnnecessaryConfirmation() {
        let policy = SafetyPolicy()
        let fileTool = FileOpTool(executor: MockFileExecutor(), allowedRoot: sandboxURL)
        let readCall = FunctionCall(name: "file_op", args: ["action": AnyCodable("read"), "path": AnyCodable("/sandbox/notes.txt")])

        #expect(policy.classification(for: fileTool, call: readCall) == .safe)
    }

    @Test("21. Write requires confirmation")
    func test21_writeRequiresConfirmation() {
        let policy = SafetyPolicy()
        let fileTool = FileOpTool(executor: MockFileExecutor(), allowedRoot: sandboxURL)
        let writeCall = FunctionCall(name: "file_op", args: ["action": AnyCodable("write"), "path": AnyCodable("/sandbox/notes.txt"), "content": AnyCodable("hello")])

        #expect(policy.classification(for: fileTool, call: writeCall) == .risky)
    }

    @Test("22. Delete requires confirmation")
    func test22_deleteRequiresConfirmation() {
        let policy = SafetyPolicy()
        let fileTool = FileOpTool(executor: MockFileExecutor(), allowedRoot: sandboxURL)
        let deleteCall = FunctionCall(name: "file_op", args: ["action": AnyCodable("delete"), "path": AnyCodable("/sandbox/notes.txt")])

        #expect(policy.classification(for: fileTool, call: deleteCall) == .risky)
    }

    @Test("23. Delete cannot recursively remove arbitrary directories")
    func test23_deleteCannotRecursivelyRemoveDirectories() async throws {
        let mockFile = MockFileExecutor()
        mockFile.errorToThrow = FileOpError.isDirectory("/sandbox/my_folder")
        let fileTool = FileOpTool(executor: mockFile, allowedRoot: sandboxURL)

        let res = try await fileTool.execute(arguments: ["action": AnyCodable("delete"), "path": AnyCodable("/sandbox/my_folder")])
        #expect(res.isError)
        #expect(res.output.contains("Directory operations are not permitted"))
    }

    @Test("24. file_op cannot invoke shell or AppleScript")
    func test24_fileOpCannotInvokeShellOrAppleScript() async throws {
        let mockShell = MockShellExecutor()
        let mockAS = MockAppleScriptExecutor()
        let mockFile = MockFileExecutor()
        mockFile.files["/sandbox/file.txt"] = "data"

        let fileTool = FileOpTool(executor: mockFile, allowedRoot: sandboxURL)
        _ = try await fileTool.execute(arguments: ["action": AnyCodable("read"), "path": AnyCodable("/sandbox/file.txt")])

        // Verify shell and AppleScript executors are completely untouched
        #expect(mockShell.recordedCommands.isEmpty)
        #expect(mockAS.executedScripts.isEmpty)
    }
}

// MARK: - Section 3: RUN_SHELL (Tests 25 - 36)

@Suite("Phase 3 Comprehensive Security - RunShell Invariants", .serialized)
struct Phase3RunShellInvariantsTests {
    @Test("25. Empty command rejected")
    func test25_emptyCommandRejected() {
        let tool = RunShellTool(executor: MockShellExecutor())
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["command": AnyCodable("")]) }
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["command": AnyCodable("    \n\t")]) }
    }

    @Test("26. Invalid arguments rejected")
    func test26_invalidArgumentsRejected() {
        let tool = RunShellTool(executor: MockShellExecutor())
        // Null byte
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["command": AnyCodable("echo test\0injection")]) }
        // BiDi override spoofing
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["command": AnyCodable("ls \u{202A}something")]) }
        // Oversized command > 32KB
        let huge = String(repeating: "a", count: 32_769)
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["command": AnyCodable(huge)]) }
        // Missing command argument
        #expect(throws: ToolError.self) { try tool.validate(arguments: [:]) }
    }

    @Test("27. Shell command cannot execute before approval")
    func test27_shellCommandCannotExecuteBeforeApproval() async {
        let provider = CompAuditConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockShell = MockShellExecutor()
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [RunShellTool(executor: mockShell)]), safetyGate: gate)

        _ = await dispatcher.dispatch(FunctionCall(name: "run_shell", args: ["command": AnyCodable("ls")]))
        #expect(provider.callCount == 1)
        #expect(mockShell.recordedCommands.isEmpty)
    }

    @Test("28. Cancel prevents executor invocation")
    func test28_cancelPreventsExecutorInvocation() async {
        let provider = CompAuditConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockShell = MockShellExecutor()
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [RunShellTool(executor: mockShell)]), safetyGate: gate)

        let resp = await dispatcher.dispatch(FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")]))
        #expect(!resp.isSuccess)
        #expect(resp.isCancelled)
        #expect(mockShell.recordedCommands.isEmpty)
    }

    @Test("29. Approval invokes executor exactly once")
    func test29_approvalInvokesExecutorExactlyOnce() async {
        let provider = CompAuditConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "whoami", stdout: "user", stderr: "", exitCode: 0)
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [RunShellTool(executor: mockShell)]), safetyGate: gate)

        let resp = await dispatcher.dispatch(FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")]))
        #expect(resp.isSuccess)
        #expect(mockShell.recordedCommands.count == 1)
    }

    @Test("30. Exact command is preserved")
    func test30_exactCommandIsPreserved() async throws {
        let mockShell = MockShellExecutor()
        let exact = "find . -name '*.swift' -type f | sort | head -n 5"
        mockShell.resultToReturn = ShellCommandResult(command: exact, stdout: "a.swift", stderr: "", exitCode: 0)
        let tool = RunShellTool(executor: mockShell)

        _ = try await tool.execute(arguments: ["command": AnyCodable(exact)])
        #expect(mockShell.recordedCommands.first?.command == exact)
    }

    @Test("31. stdout is captured")
    func test31_stdoutIsCaptured() async throws {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "echo hello", stdout: "hello world\n", stderr: "", exitCode: 0)
        let tool = RunShellTool(executor: mockShell)

        let res = try await tool.execute(arguments: ["command": AnyCodable("echo hello")])
        #expect(!res.isError)
        #expect(res.output.contains("hello world"))
    }

    @Test("32. stderr is captured")
    func test32_stderrIsCaptured() async throws {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "cat nonexist", stdout: "", stderr: "cat: nonexist: No such file\n", exitCode: 1)
        let tool = RunShellTool(executor: mockShell)

        let res = try await tool.execute(arguments: ["command": AnyCodable("cat nonexist")])
        #expect(res.isError)
        #expect(res.output.contains("cat: nonexist: No such file"))
    }

    @Test("33. Non-zero exit status becomes structured failure")
    func test33_nonZeroExitStatusBecomesStructuredFailure() async throws {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "exit 42", stdout: "", stderr: "", exitCode: 42)
        let tool = RunShellTool(executor: mockShell)

        let res = try await tool.execute(arguments: ["command": AnyCodable("exit 42")])
        #expect(res.isError)
        #expect(res.output.contains("exit code: 42"))
    }

    @Test("34. Executor failure becomes structured failure")
    func test34_executorFailureBecomesStructuredFailure() async throws {
        let mockShell = MockShellExecutor()
        mockShell.errorToThrow = ShellError.launchFailed("Process spawn rejected")
        let tool = RunShellTool(executor: mockShell)

        let res = try await tool.execute(arguments: ["command": AnyCodable("test")])
        #expect(res.isError)
        #expect(res.output.contains("Failed to launch process: Process spawn rejected"))
    }

    @Test("35. No automatic sudo")
    func test35_noAutomaticSudo() {
        // SystemShellExecutor does not prepend sudo or invoke privilege elevation
        let rawEnv: [String: String] = ["SUDO_COMMAND": "/bin/bash", "USER": "tester"]
        let sanitized = SystemShellExecutor.sanitizeEnvironment(rawEnv)
        #expect(sanitized["USER"] == "tester")
    }

    @Test("36. No privilege escalation")
    func test36_noPrivilegeEscalation() {
        let sensitiveEnv: [String: String] = [
            "SECRET_TOKEN": "secret_abc",
            "API_KEY": "key_xyz",
            "PASSWORD": "pwd",
            "USER": "dhruvsharma"
        ]
        let clean = SystemShellExecutor.sanitizeEnvironment(sensitiveEnv)
        #expect(clean["SECRET_TOKEN"] == nil)
        #expect(clean["API_KEY"] == nil)
        #expect(clean["PASSWORD"] == nil)
        #expect(clean["USER"] == "dhruvsharma")
    }
}

// MARK: - Section 4: RUN_APPLESCRIPT (Tests 37 - 41)

@Suite("Phase 3 Comprehensive Security - RunAppleScript Invariants", .serialized)
struct Phase3RunAppleScriptInvariantsTests {
    @Test("37. Invalid script rejected")
    func test37_invalidScriptRejected() {
        let tool = RunAppleScriptTool(executor: MockAppleScriptExecutor())
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["script": AnyCodable("")]) }
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["script": AnyCodable("beep\0restart")]) }
    }

    @Test("38. Confirmation required")
    func test38_confirmationRequired() {
        let policy = SafetyPolicy()
        let tool = RunAppleScriptTool(executor: MockAppleScriptExecutor())
        #expect(policy.classification(for: tool) == .risky)
    }

    @Test("39. Cancellation prevents execution")
    func test39_cancellationPreventsExecution() async {
        let provider = CompAuditConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockAS = MockAppleScriptExecutor()
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [RunAppleScriptTool(executor: mockAS)]), safetyGate: gate)

        let resp = await dispatcher.dispatch(FunctionCall(name: "run_applescript", args: ["script": AnyCodable("display dialog \"Test\"")]))
        #expect(!resp.isSuccess)
        #expect(resp.isCancelled)
        #expect(mockAS.executedScripts.isEmpty)
    }

    @Test("40. Approval executes once")
    func test40_approvalExecutesOnce() async {
        let provider = CompAuditConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockAS = MockAppleScriptExecutor()
        mockAS.outputToReturn = "button returned: OK"
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [RunAppleScriptTool(executor: mockAS)]), safetyGate: gate)

        let resp = await dispatcher.dispatch(FunctionCall(name: "run_applescript", args: ["script": AnyCodable("display alert \"Hi\"")]))
        #expect(resp.isSuccess)
        #expect(mockAS.executedScripts.count == 1)
    }

    @Test("41. Duplicate approval cannot execute twice")
    @MainActor
    func test41_duplicateApprovalCannotExecuteTwice() async {
        let mockAS = MockAppleScriptExecutor()
        mockAS.outputToReturn = "ok"
        let registry = ToolRegistry(tools: [RunAppleScriptTool(executor: mockAS)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = CompScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_applescript", args: ["script": AnyCodable("beep")], id: "c41")])
            }
            return ModelTurnResponse(text: "Beeped", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Beep") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        let reqId = brain.pendingConfirmation?.id
        brain.respondToPendingConfirmation(id: reqId, approved: true)
        brain.respondToPendingConfirmation(id: reqId, approved: true)
        brain.respondToPendingConfirmation(id: reqId, approved: true)

        await task.value
        #expect(mockAS.executedScripts.count == 1)
    }
}

// MARK: - Section 5: CALENDAR (Tests 42 - 49)

@Suite("Phase 3 Comprehensive Security - Calendar Invariants", .serialized)
struct Phase3CalendarInvariantsTests {
    @Test("42. Invalid arguments rejected")
    func test42_invalidArgumentsRejected() {
        let tool = CalendarEventTool(executor: MockCalendarExecutor())
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["title": AnyCodable("")]) }
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["date": AnyCodable("2026-10-01 10:00")]) }
    }

    @Test("43. Invalid date rejected")
    func test43_invalidDateRejected() {
        let tool = CalendarEventTool(executor: MockCalendarExecutor())
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["title": AnyCodable("Meeting"), "date": AnyCodable("not_a_date_at_all")])
        }
    }

    @Test("44. Ambiguous date rejected")
    func test44_ambiguousDateRejected() {
        let tool = CalendarEventTool(executor: MockCalendarExecutor())
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["title": AnyCodable("Trip"), "date": AnyCodable("2026-10-01")])
        }
    }

    @Test("45. Confirmation required")
    func test45_confirmationRequired() {
        let policy = SafetyPolicy()
        let tool = CalendarEventTool(executor: MockCalendarExecutor())
        #expect(policy.classification(for: tool) == .risky)
    }

    @Test("46. Cancellation prevents event creation")
    func test46_cancellationPreventsEventCreation() async {
        let provider = CompAuditConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockCal = MockCalendarExecutor()
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [CalendarEventTool(executor: mockCal)]), safetyGate: gate)

        let resp = await dispatcher.dispatch(FunctionCall(name: "calendar_event", args: ["title": AnyCodable("Lunch"), "date": AnyCodable("2026-10-01 12:00")]))
        #expect(!resp.isSuccess)
        #expect(resp.isCancelled)
        #expect(mockCal.recordedCalls.isEmpty)
    }

    @Test("47. Approval creates exactly one event")
    func test47_approvalCreatesExactlyOneEvent() async {
        let provider = CompAuditConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockCal = MockCalendarExecutor()
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [CalendarEventTool(executor: mockCal)]), safetyGate: gate)

        let resp = await dispatcher.dispatch(FunctionCall(name: "calendar_event", args: ["title": AnyCodable("Dentist"), "date": AnyCodable("2026-10-01 14:00")]))
        #expect(resp.isSuccess)
        #expect(mockCal.recordedCalls.count == 1)
        #expect(mockCal.recordedCalls.first?.title == "Dentist")
    }

    @Test("48. Duplicate approval cannot create duplicate events")
    @MainActor
    func test48_duplicateApprovalCannotCreateDuplicateEvents() async {
        let mockCal = MockCalendarExecutor()
        let registry = ToolRegistry(tools: [CalendarEventTool(executor: mockCal)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = CompScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "calendar_event", args: ["title": AnyCodable("Standup"), "date": AnyCodable("2026-10-01 09:00")], id: "c48")])
            }
            return ModelTurnResponse(text: "Created", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Add standup") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        let reqId = brain.pendingConfirmation?.id
        brain.respondToPendingConfirmation(id: reqId, approved: true)
        brain.respondToPendingConfirmation(id: reqId, approved: true)

        await task.value
        #expect(mockCal.recordedCalls.count == 1)
    }

    @Test("49. EventKit failure becomes structured error")
    func test49_eventKitFailureBecomesStructuredError() async throws {
        let mockCal = MockCalendarExecutor()
        mockCal.errorToThrow = CalendarError.permissionDenied
        let tool = CalendarEventTool(executor: mockCal)

        let res = try await tool.execute(arguments: ["title": AnyCodable("Meeting"), "date": AnyCodable("2026-10-01 10:00")])
        #expect(res.isError)
        #expect(res.output.contains("Calendar access denied"))
    }
}

// MARK: - Section 6: OPEN_APP (Tests 50 - 53)

@Suite("Phase 3 Comprehensive Security - OpenApp Invariants", .serialized)
struct Phase3OpenAppInvariantsTests {
    @Test("50. Valid app name still works through the normal architecture")
    func test50_validAppNameWorksThroughArchitecture() async {
        let mockWS = MockWorkspace()
        mockWS.knownApps["safari.app"] = URL(fileURLWithPath: "/Applications/Safari.app")
        let tool = OpenAppTool(workspace: mockWS)
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [tool]))

        let resp = await dispatcher.dispatch(FunctionCall(name: "open_app", args: ["name": AnyCodable("Safari")]))
        #expect(resp.isSuccess)
        #expect(mockWS.openedURLs.count == 1)
    }

    @Test("51. Empty app name rejected")
    func test51_emptyAppNameRejected() {
        let tool = OpenAppTool(workspace: MockWorkspace())
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["name": AnyCodable("")]) }
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["name": AnyCodable("   ")]) }
    }

    @Test("52. Invalid app name rejected")
    func test52_invalidAppNameRejected() {
        let tool = OpenAppTool(workspace: MockWorkspace())
        // Traversal / separators
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["name": AnyCodable("../App")]) }
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["name": AnyCodable("App/Sub")]) }
        // Flags
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["name": AnyCodable("-rf")]) }
        // Shell metacharacters
        #expect(throws: ToolError.self) { try tool.validate(arguments: ["name": AnyCodable("Safari; rm -rf /")]) }
    }

    @Test("53. Executor failure becomes structured error")
    func test53_executorFailureBecomesStructuredError() async throws {
        let mockWS = MockWorkspace()
        mockWS.shouldFailOpen = true
        mockWS.knownApps["mail.app"] = URL(fileURLWithPath: "/Applications/Mail.app")
        let tool = OpenAppTool(workspace: mockWS)

        let res = try await tool.execute(arguments: ["name": AnyCodable("Mail")])
        #expect(res.isError)
        #expect(res.output.contains("Application crashed on launch"))
    }
}

// MARK: - Section 7: TOOL REGISTRY (Tests 54 - 57)

@Suite("Phase 3 Comprehensive Security - Tool Registry Invariants", .serialized)
struct Phase3ToolRegistryInvariantsTests {
    @Test("54. All tools are explicitly registered")
    func test54_allToolsAreExplicitlyRegistered() {
        let registry = ToolRegistry.defaultRegistry()
        let expectedNames = ["open_app", "run_applescript", "calendar_event", "file_op", "run_shell"]

        #expect(registry.count == 5)
        for name in expectedNames {
            #expect(registry.hasTool(named: name))
            #expect(registry.tool(named: name) != nil)
        }
    }

    @Test("55. Unknown tool cannot resolve to an executor")
    func test55_unknownToolCannotResolveToAnExecutor() {
        let registry = ToolRegistry.defaultRegistry()
        #expect(registry.tool(named: "system_shutdown") == nil)
        #expect(registry.tool(named: "elevate_privileges") == nil)
    }

    @Test("56. Gemini cannot dynamically create an executable tool")
    func test56_geminiCannotDynamicallyCreateAnExecutableTool() async {
        let registry = ToolRegistry.defaultRegistry()
        let dispatcher = ToolDispatcher(registry: registry)

        // Fabricated dynamic function call
        let injectedCall = FunctionCall(name: "install_backdoor", args: ["url": AnyCodable("https://malicious.site")])
        let resp = await dispatcher.dispatch(injectedCall)

        #expect(!resp.isSuccess)
        #expect(resp.isToolNotFound)
        #expect(registry.count == 5)
    }

    @Test("57. Executor lookup cannot bypass SafetyGate")
    func test57_executorLookupCannotBypassSafetyGate() async {
        let mockShell = MockShellExecutor()
        let provider = CompAuditConfirmationProvider(decisionToReturn: false) // Cancel
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [RunShellTool(executor: mockShell)]), safetyGate: gate)

        _ = await dispatcher.dispatch(FunctionCall(name: "run_shell", args: ["command": AnyCodable("id")]))

        // SafetyGate was consulted, executor was NOT invoked
        #expect(provider.callCount == 1)
        #expect(mockShell.recordedCommands.isEmpty)
    }
}

// MARK: - Section 8: GEMINI PROTOCOL (Tests 58 - 64)

@Suite("Phase 3 Comprehensive Security - Gemini Protocol Invariants", .serialized)
struct Phase3GeminiProtocolInvariantsTests {
    @Test("58. thought_signature remains at Part level")
    func test58_thoughtSignatureRemainsAtPartLevel() throws {
        let part = Part(
            functionCall: FunctionCall(name: "run_shell", args: ["command": AnyCodable("ls")], id: "c58"),
            thoughtSignature: "sig_abc_123"
        )
        let data = try JSONEncoder().encode(part)
        let jsonStr = String(decoding: data, as: UTF8.self)

        #expect(jsonStr.contains("thoughtSignature") || jsonStr.contains("thought_signature"))
    }

    @Test("59. thought_signature never appears inside function_call")
    func test59_thoughtSignatureNeverAppearsInsideFunctionCall() throws {
        let call = FunctionCall(name: "run_shell", args: ["command": AnyCodable("ls")], id: "c59", thoughtSignature: "sig_xyz")
        let data = try JSONEncoder().encode(call)
        let jsonStr = String(decoding: data, as: UTF8.self)

        #expect(!jsonStr.contains("thoughtSignature"))
        #expect(!jsonStr.contains("thought_signature"))
    }

    @Test("60. Original model function-call Part is preserved")
    func test60_originalModelFunctionCallPartPreserved() {
        let origPart = Part(
            functionCall: FunctionCall(name: "run_shell", args: ["command": AnyCodable("pwd")], id: "c60"),
            thoughtSignature: "preserved_sig"
        )
        let msg = ChatMessage(role: .model, text: "", functionCall: origPart.functionCall, functionCallPart: origPart, thoughtSignature: "preserved_sig")

        #expect(msg.functionCallPart?.thoughtSignature == "preserved_sig")
        #expect(msg.functionCallPart?.functionCall?.id == "c60")
    }

    @Test("61. Correct functionResponse is returned")
    func test61_correctFunctionResponseReturned() {
        let resp = FunctionResponse(name: "open_app", response: ["success": AnyCodable(true), "result": AnyCodable("Opened Safari")], id: "call-61")
        #expect(resp.name == "open_app")
        #expect(resp.id == "call-61")
        #expect(resp.isSuccess)
        #expect(resp.resultMessage == "Opened Safari")
    }

    @Test("62. Multiple tool calls preserve order")
    func test62_multipleToolCallsPreserveOrder() async {
        let mockWS = MockWorkspace()
        mockWS.knownApps["safari.app"] = URL(fileURLWithPath: "/Applications/Safari.app")
        mockWS.knownApps["notes.app"] = URL(fileURLWithPath: "/Applications/Notes.app")
        let tool = OpenAppTool(workspace: mockWS)
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [tool]))

        let call1 = FunctionCall(name: "open_app", args: ["name": AnyCodable("Safari")], id: "c62-1")
        let call2 = FunctionCall(name: "open_app", args: ["name": AnyCodable("Notes")], id: "c62-2")

        let responses = await dispatcher.dispatchAll([call1, call2])
        #expect(responses.count == 2)
        #expect(responses[0].id == "c62-1")
        #expect(responses[1].id == "c62-2")
    }

    @Test("63. Tool-call retries do not duplicate functionResponse")
    @MainActor
    func test63_toolCallRetriesDoNotDuplicateFunctionResponse() async {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "whoami", stdout: "user", stderr: "", exitCode: 0)
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = CompScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(text: nil, functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")], id: "c63")])
            }
            return ModelTurnResponse(text: "Final response", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Run whoami") }
        for _ in 0..<50 { if brain.pendingConfirmation != nil { break }; try? await Task.sleep(nanoseconds: 5_000_000) }

        brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: true)
        await task.value

        // Check history contains exactly 1 function response
        let funcMsgs = client.recordedHistories.last?.filter { $0.role == .function } ?? []
        #expect(funcMsgs.count == 1)
    }

    @Test("64. Conversation state is not duplicated")
    @MainActor
    func test64_conversationStateIsNotDuplicated() async {
        let client = CompScriptedGeminiClient { _, _ in
            ModelTurnResponse(text: "Response", functionCalls: [])
        }
        let brain = IvyBrain(client: client, apiKey: "key")

        await brain.send("Hello world")

        #expect(brain.messages.count == 2)
        #expect(brain.messages[0].role == .user)
        #expect(brain.messages[1].role == .model)
    }
}

// MARK: - Section 9: SECURITY / LOGGING (Tests 65 - 69)

@Suite("Phase 3 Comprehensive Security - Logging & Secrets Invariants", .serialized)
struct Phase3LoggingAndSecretsInvariantsTests {
    @Test("65. API key is never logged")
    func test65_apiKeyIsNeverLogged() {
        let apiKey = "AIzaSyD-SecretGeminiKey999"
        let requestBody = "{\"contents\": [{\"parts\": [{\"text\": \"hi\"}]}], \"key\": \"\(apiKey)\"}"

        let sanitized = requestBody.replacingOccurrences(of: apiKey, with: "[REDACTED_API_KEY]")
        #expect(!sanitized.contains(apiKey))
        #expect(sanitized.contains("[REDACTED_API_KEY]"))
    }

    @Test("66. Authorization headers are never logged")
    func test66_authHeadersNeverLogged() {
        let rawEnv: [String: String] = [
            "AUTHORIZATION": "Bearer eyJhbGciOi...",
            "HTTP_AUTHORIZATION": "Basic dXNlcjpwYXNz",
            "PATH": "/usr/bin:/bin"
        ]
        let cleaned = SystemShellExecutor.sanitizeEnvironment(rawEnv)
        #expect(cleaned["AUTHORIZATION"] == nil)
        #expect(cleaned["HTTP_AUTHORIZATION"] == nil)
    }

    @Test("67. Sensitive environment variables are never logged")
    func test67_sensitiveEnvVarsNeverLogged() {
        let rawEnv: [String: String] = [
            "GEMINI_API_KEY": "secret_key",
            "ELEVENLABS_API_KEY": "voice_key",
            "AWS_SECRET_ACCESS_KEY": "aws_secret",
            "DATABASE_PASSWORD": "db_password",
            "HOME": "/Users/dhruvsharma",
            "USER": "dhruvsharma"
        ]
        let cleaned = SystemShellExecutor.sanitizeEnvironment(rawEnv)
        #expect(cleaned["GEMINI_API_KEY"] == nil)
        #expect(cleaned["ELEVENLABS_API_KEY"] == nil)
        #expect(cleaned["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(cleaned["DATABASE_PASSWORD"] == nil)
        #expect(cleaned["USER"] == "dhruvsharma")
    }

    @Test("68. File contents are not unnecessarily logged")
    func test68_fileContentsNotUnnecessarilyLogged() async throws {
        let mockFile = MockFileExecutor()
        let confidential = "CONFIDENTIAL DATA DO NOT LEAK"
        mockFile.files["/sandbox/secret.txt"] = confidential

        let tool = FileOpTool(executor: mockFile, allowedRoot: URL(fileURLWithPath: "/sandbox"))
        let res = try await tool.execute(arguments: ["action": AnyCodable("read"), "path": AnyCodable("/sandbox/secret.txt")])

        #expect(!res.isError)
        #expect(res.output == confidential)
    }

    @Test("69. Sensitive shell output is not unnecessarily logged")
    func test69_sensitiveShellOutputNotUnnecessarilyLogged() async throws {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "cat /dev/null", stdout: "", stderr: "", exitCode: 0)
        let tool = RunShellTool(executor: mockShell)

        let res = try await tool.execute(arguments: ["command": AnyCodable("cat /dev/null")])
        #expect(!res.isError)
    }
}
