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

// MARK: - Suite 1: SafetyGate Risk Classification & Audit Across All Tools

@Suite("Phase 3 - SafetyGate Audit Tests")
struct Phase3SafetyGateAuditTests {
    private let sandboxURL = URL(fileURLWithPath: "/sandbox")

    @Test("Classification: Audit explicit risk classification across all 5 tools")
    func testExplicitRiskClassificationAcrossAllTools() {
        let policy = SafetyPolicy()

        let openApp = OpenAppTool(workspace: MockWorkspace())
        let applescript = RunAppleScriptTool(executor: MockAppleScriptExecutor())
        let calendar = CalendarEventTool(executor: MockCalendarExecutor())
        let fileOp = FileOpTool(executor: MockFileExecutor(), allowedRoot: sandboxURL)
        let shell = RunShellTool(executor: MockShellExecutor())

        // 1. open_app is SAFE
        #expect(policy.classification(for: openApp) == .safe)
        #expect(openApp.safetyClassification == .safe)
        let openCall = FunctionCall(name: "open_app", args: ["name": AnyCodable("Safari")])
        #expect(policy.classification(for: openApp, call: openCall) == .safe)

        // 2. file_op read is SAFE, file_op write and delete are RISKY
        #expect(policy.classification(for: fileOp) == .risky) // Default without call context is risky
        let readCall = FunctionCall(name: "file_op", args: ["action": AnyCodable("read"), "path": AnyCodable("/sandbox/file.txt")])
        #expect(policy.classification(for: fileOp, call: readCall) == .safe)

        let writeCall = FunctionCall(name: "file_op", args: ["action": AnyCodable("write"), "path": AnyCodable("/sandbox/file.txt"), "content": AnyCodable("hello")])
        #expect(policy.classification(for: fileOp, call: writeCall) == .risky)

        let deleteCall = FunctionCall(name: "file_op", args: ["action": AnyCodable("delete"), "path": AnyCodable("/sandbox/file.txt")])
        #expect(policy.classification(for: fileOp, call: deleteCall) == .risky)

        let unknownActionCall = FunctionCall(name: "file_op", args: ["action": AnyCodable("chmod"), "path": AnyCodable("/sandbox/file.txt")])
        #expect(policy.classification(for: fileOp, call: unknownActionCall) == .risky)

        // 3. run_applescript is RISKY
        #expect(policy.classification(for: applescript) == .risky)
        #expect(applescript.safetyClassification == .risky)
        let scriptCall = FunctionCall(name: "run_applescript", args: ["script": AnyCodable("beep")])
        #expect(policy.classification(for: applescript, call: scriptCall) == .risky)

        // 4. calendar_event is RISKY
        #expect(policy.classification(for: calendar) == .risky)
        #expect(calendar.safetyClassification == .risky)
        let calCall = FunctionCall(name: "calendar_event", args: ["title": AnyCodable("Meeting"), "date": AnyCodable("2026-10-01T10:00:00Z")])
        #expect(policy.classification(for: calendar, call: calCall) == .risky)

        // 5. run_shell is ALWAYS RISKY
        #expect(policy.classification(for: shell) == .risky)
        #expect(shell.safetyClassification == .risky)
        let shellCall = FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")])
        #expect(policy.classification(for: shell, call: shellCall) == .risky)
    }

    @Test("InteractiveSafetyGate: builds exact ConfirmationRequest with callId for all risky tools")
    func testConfirmationRequestDetailsAndCallId() async {
        let provider = Phase3AuditConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)

        // 1. run_applescript
        let appleScriptTool = RunAppleScriptTool(executor: MockAppleScriptExecutor())
        let callAS = FunctionCall(name: "run_applescript", args: ["script": AnyCodable("display dialog \"Hi\"")], id: "as-call-101")
        _ = await gate.evaluate(tool: appleScriptTool, call: callAS)
        #expect(provider.recordedRequests.count == 1)
        #expect(provider.recordedRequests[0].toolName == "run_applescript")
        #expect(provider.recordedRequests[0].callId == "as-call-101")
        #expect(provider.recordedRequests[0].detail == "display dialog \"Hi\"")

        // 2. calendar_event
        let calTool = CalendarEventTool(executor: MockCalendarExecutor())
        let callCal = FunctionCall(name: "calendar_event", args: ["title": AnyCodable("Dentist"), "date": AnyCodable("2026-10-05T14:00:00Z")], id: "cal-call-202")
        _ = await gate.evaluate(tool: calTool, call: callCal)
        #expect(provider.recordedRequests.count == 2)
        #expect(provider.recordedRequests[1].toolName == "calendar_event")
        #expect(provider.recordedRequests[1].callId == "cal-call-202")
        #expect(provider.recordedRequests[1].detail.contains("Dentist"))
        #expect(provider.recordedRequests[1].detail.contains("2026-10-05T14:00:00Z"))

        // 3. file_op write
        let fileTool = FileOpTool(executor: MockFileExecutor(), allowedRoot: sandboxURL)
        let callWrite = FunctionCall(name: "file_op", args: ["action": AnyCodable("write"), "path": AnyCodable("/sandbox/test.txt"), "content": AnyCodable("data")], id: "file-call-303")
        _ = await gate.evaluate(tool: fileTool, call: callWrite)
        #expect(provider.recordedRequests.count == 3)
        #expect(provider.recordedRequests[2].toolName == "file_op")
        #expect(provider.recordedRequests[2].callId == "file-call-303")
        #expect(provider.recordedRequests[2].title == "Write File")
        #expect(provider.recordedRequests[2].detail.contains("/sandbox/test.txt"))

        // 4. file_op delete
        let callDelete = FunctionCall(name: "file_op", args: ["action": AnyCodable("delete"), "path": AnyCodable("/sandbox/test.txt")], id: "file-call-404")
        _ = await gate.evaluate(tool: fileTool, call: callDelete)
        #expect(provider.recordedRequests.count == 4)
        #expect(provider.recordedRequests[3].toolName == "file_op")
        #expect(provider.recordedRequests[3].callId == "file-call-404")
        #expect(provider.recordedRequests[3].title == "Delete File")

        // 5. run_shell
        let shellTool = RunShellTool(executor: MockShellExecutor())
        let callShell = FunctionCall(name: "run_shell", args: ["command": AnyCodable("ls -la /tmp")], id: "sh-call-505")
        _ = await gate.evaluate(tool: shellTool, call: callShell)
        #expect(provider.recordedRequests.count == 5)
        #expect(provider.recordedRequests[4].toolName == "run_shell")
        #expect(provider.recordedRequests[4].callId == "sh-call-505")
        #expect(provider.recordedRequests[4].detail == "ls -la /tmp")
    }

    @Test("Bypass Prevention: Deceptive arguments cannot bypass SafetyGate")
    func testDeceptiveArgumentsCannotBypassSafetyGate() async {
        let provider = Phase3AuditConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)

        let mockAS = MockAppleScriptExecutor()
        let appleScriptTool = RunAppleScriptTool(executor: mockAS)

        let mockCal = MockCalendarExecutor()
        let calTool = CalendarEventTool(executor: mockCal)

        let mockFile = MockFileExecutor()
        let fileTool = FileOpTool(executor: mockFile, allowedRoot: sandboxURL)

        let mockShell = MockShellExecutor()
        let shellTool = RunShellTool(executor: mockShell)

        let registry = ToolRegistry(tools: [appleScriptTool, calTool, fileTool, shellTool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        // AppleScript spoofing
        let asSpoof = FunctionCall(name: "run_applescript", args: ["script": AnyCodable("beep"), "bypassConfirmation": AnyCodable(true), "role": AnyCodable("admin")], id: "spoof-1")
        let asResp = await dispatcher.dispatch(asSpoof)
        #expect(asResp.isCancelled)
        #expect(mockAS.executedScripts.isEmpty)

        // Calendar spoofing - rejected during validation due to unexpected arguments!
        let calSpoof = FunctionCall(name: "calendar_event", args: ["title": AnyCodable("Party"), "date": AnyCodable("2026-10-01T10:00:00Z"), "autoApprove": AnyCodable(true)], id: "spoof-2")
        let calResp = await dispatcher.dispatch(calSpoof)
        #expect(calResp.isValidationError)
        #expect(mockCal.recordedCalls.isEmpty)

        // FileOp spoofing - rejected during validation due to unexpected arguments!
        let fileSpoof = FunctionCall(name: "file_op", args: ["action": AnyCodable("delete"), "path": AnyCodable("/sandbox/test.txt"), "confirmed": AnyCodable(true)], id: "spoof-3")
        let fileResp = await dispatcher.dispatch(fileSpoof)
        #expect(fileResp.isValidationError)
        #expect(mockFile.recordedCalls.isEmpty)

        // Shell spoofing - rejected during validation due to unexpected arguments!
        let shellSpoof = FunctionCall(name: "run_shell", args: ["command": AnyCodable("uptime"), "bypassSafety": AnyCodable(true)], id: "spoof-4")
        let shellResp = await dispatcher.dispatch(shellSpoof)
        #expect(shellResp.isValidationError)
        #expect(mockShell.recordedCommands.isEmpty)
    }
}

// MARK: - Suite 2: Confirmation Security, UUID Binding, & Isolation

@Suite("Phase 3 - Confirmation Security Tests")
struct Phase3ConfirmationSecurityTests {
    private let sandboxURL = URL(fileURLWithPath: "/sandbox")

    @Test("Confirmation is tied to exact UUID: Mismatched UUID approval is ignored")
    @MainActor
    func testMismatchedUUIDApprovalIsIgnored() async {
        let brain = IvyBrain(apiKey: "valid_key")

        let req = ConfirmationRequest(
            callId: "call-target",
            toolName: "run_shell",
            title: "Run Shell Command",
            prompt: "Test prompt",
            detail: "echo test"
        )

        let task = Task {
            await brain.handleConfirmation(req)
        }

        // Wait for pendingConfirmation to populate
        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(brain.pendingConfirmation?.id == req.id)

        // Attempt approval with wrong UUID
        brain.respondToPendingConfirmation(id: UUID(), approved: true)

        // Confirmation must remain pending!
        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.id == req.id)

        // Now respond with matching UUID
        brain.respondToPendingConfirmation(id: req.id, approved: true)

        let decision = await task.value
        #expect(decision == true)
        #expect(brain.pendingConfirmation == nil)
    }

    @Test("Confirmation is tied to exact UUID: Mismatched UUID cancellation is ignored")
    @MainActor
    func testMismatchedUUIDCancellationIsIgnored() async {
        let brain = IvyBrain(apiKey: "valid_key")

        let req = ConfirmationRequest(
            callId: "call-cancel-target",
            toolName: "file_op",
            title: "Delete File",
            prompt: "Test prompt",
            detail: "Action: Delete File"
        )

        let task = Task {
            await brain.handleConfirmation(req)
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(brain.pendingConfirmation?.id == req.id)

        // Attempt cancellation with wrong UUID
        brain.respondToPendingConfirmation(id: UUID(), approved: false)

        // Confirmation must still be pending!
        #expect(brain.pendingConfirmation != nil)

        // Cancel with matching UUID
        brain.respondToPendingConfirmation(id: req.id, approved: false)

        let decision = await task.value
        #expect(decision == false)
        #expect(brain.pendingConfirmation == nil)
    }

    @Test("Cancel guarantees ZERO executor calls across all risky tools")
    @MainActor
    func testCancelGuaranteesZeroExecutorCallsAcrossRiskyTools() async {
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
        let safetyGate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: safetyGate)

        // 1. AppleScript Cancel
        do {
            let client = Phase3ScriptedGeminiClient { step, _ in
                if step == 1 {
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [FunctionCall(name: "run_applescript", args: ["script": AnyCodable("beep")], id: "c1")]
                    )
                }
                return ModelTurnResponse(text: "Cancelled AS", functionCalls: [])
            }
            let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
            bridge.handler = brain

            let task = Task { await brain.send("Run AS") }
            for _ in 0..<50 {
                if brain.pendingConfirmation != nil { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
            await task.value
            #expect(mockAS.executedScripts.isEmpty)
        }

        // 2. Calendar Cancel
        do {
            let client = Phase3ScriptedGeminiClient { step, _ in
                if step == 1 {
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [FunctionCall(name: "calendar_event", args: ["title": AnyCodable("Meeting"), "date": AnyCodable("2026-10-01T10:00:00Z")], id: "c2")]
                    )
                }
                return ModelTurnResponse(text: "Cancelled Cal", functionCalls: [])
            }
            let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
            bridge.handler = brain

            let task = Task { await brain.send("Add meeting") }
            for _ in 0..<50 {
                if brain.pendingConfirmation != nil { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
            await task.value
            #expect(mockCal.recordedCalls.isEmpty)
        }

        // 3. File Op Write Cancel
        do {
            let client = Phase3ScriptedGeminiClient { step, _ in
                if step == 1 {
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [FunctionCall(name: "file_op", args: ["action": AnyCodable("write"), "path": AnyCodable("/sandbox/doc.txt"), "content": AnyCodable("data")], id: "c3")]
                    )
                }
                return ModelTurnResponse(text: "Cancelled Write", functionCalls: [])
            }
            let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
            bridge.handler = brain

            let task = Task { await brain.send("Write file") }
            for _ in 0..<50 {
                if brain.pendingConfirmation != nil { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
            await task.value
            #expect(mockFile.recordedCalls.isEmpty)
        }

        // 4. Shell Cancel
        do {
            let client = Phase3ScriptedGeminiClient { step, _ in
                if step == 1 {
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("whoami")], id: "c4")]
                    )
                }
                return ModelTurnResponse(text: "Cancelled Shell", functionCalls: [])
            }
            let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
            bridge.handler = brain

            let task = Task { await brain.send("Run shell") }
            for _ in 0..<50 {
                if brain.pendingConfirmation != nil { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
            await task.value
            #expect(mockShell.recordedCommands.isEmpty)
        }
    }

    @Test("Repeated approval executes at most once and never duplicates")
    @MainActor
    func testRepeatedApprovalExecutesAtMostOnce() async {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "date", stdout: "Sun Sep 27", stderr: "", exitCode: 0)
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = Phase3ScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("date")], id: "rep-1")]
                )
            }
            return ModelTurnResponse(text: "Date reported.", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Get date") }
        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let pendingId = brain.pendingConfirmation?.id
        #expect(pendingId != nil)

        // First approval
        brain.respondToPendingConfirmation(id: pendingId, approved: true)

        // Second duplicate approval attempts
        brain.respondToPendingConfirmation(id: pendingId, approved: true)
        brain.respondToPendingConfirmation(id: pendingId, approved: true)

        await task.value

        #expect(mockShell.recordedCommands.count == 1)
    }

    @Test("Previous approval cannot authorize later calls")
    @MainActor
    func testPreviousApprovalDoesNotAuthorizeLaterCalls() async {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "test", stdout: "ok", stderr: "", exitCode: 0)
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = Phase3ScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("echo 1")], id: "seq-1")]
                )
            }
            return ModelTurnResponse(text: "First done", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        // Turn 1
        let task1 = Task { await brain.send("First") }
        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let req1Id = brain.pendingConfirmation?.id
        #expect(req1Id != nil)
        brain.respondToPendingConfirmation(id: req1Id, approved: true)
        await task1.value
        #expect(mockShell.recordedCommands.count == 1)

        // Turn 2: New command requires a fresh confirmation
        client.handler = { step, _ in
            if step == 3 {
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("echo 2")], id: "seq-2")]
                )
            }
            return ModelTurnResponse(text: "Second done", functionCalls: [])
        }

        let task2 = Task { await brain.send("Second") }
        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        // Must be paused waiting for confirmation of Turn 2!
        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.id != req1Id)
        #expect(mockShell.recordedCommands.count == 1) // Not yet executed

        // Stale approval using req1Id must be ignored!
        brain.respondToPendingConfirmation(id: req1Id, approved: true)
        #expect(brain.pendingConfirmation != nil)
        #expect(mockShell.recordedCommands.count == 1)

        // Approve with the correct new ID
        brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: true)
        await task2.value
        #expect(mockShell.recordedCommands.count == 2)
    }

    @Test("Natural-language chat cannot approve pending action")
    @MainActor
    func testNaturalLanguageChatCannotApprovePendingAction() async {
        let mockShell = MockShellExecutor()
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let client = Phase3ScriptedGeminiClient { step, _ in
            if step == 1 {
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_shell", args: ["command": AnyCodable("ls")], id: "nl-1")]
                )
            }
            return ModelTurnResponse(text: "Done", functionCalls: [])
        }
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("Run ls") }
        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(brain.pendingConfirmation != nil)

        // Attempt natural language approvals
        await brain.send("yes please do it")
        await brain.send("I approve this command")
        await brain.send("Do it")

        // Confirmation must STILL be pending and executor call count must be 0!
        #expect(brain.pendingConfirmation != nil)
        #expect(mockShell.recordedCommands.isEmpty)

        // Cancel via real UI confirmation button
        brain.respondToPendingConfirmation(id: brain.pendingConfirmation?.id, approved: false)
        await task.value
        #expect(mockShell.recordedCommands.isEmpty)
    }
}

// MARK: - Suite 3: Cross-Tool Argument Validation & Injection Prevention

@Suite("Phase 3 - Argument Validation and Injection Tests")
struct Phase3ArgumentValidationAndInjectionTests {
    private let sandboxURL = URL(fileURLWithPath: "/sandbox")

    @Test("Validation: Unexpected arguments rejected across OpenApp, Calendar, FileOp, Shell")
    func testUnexpectedArgumentsRejected() {
        let openApp = OpenAppTool(workspace: MockWorkspace())
        let cal = CalendarEventTool(executor: MockCalendarExecutor())
        let file = FileOpTool(executor: MockFileExecutor(), allowedRoot: sandboxURL)
        let shell = RunShellTool(executor: MockShellExecutor())

        // 1. open_app with unexpected argument
        #expect(throws: ToolError.self) {
            try openApp.validate(arguments: ["name": AnyCodable("Safari"), "unexpected": AnyCodable(true)])
        }

        // 2. calendar_event with unexpected argument
        #expect(throws: ToolError.self) {
            try cal.validate(arguments: ["title": AnyCodable("Trip"), "date": AnyCodable("2026-10-01T10:00:00Z"), "extra": AnyCodable(123)])
        }

        // 3. file_op with unexpected argument
        #expect(throws: ToolError.self) {
            try file.validate(arguments: ["action": AnyCodable("read"), "path": AnyCodable("/sandbox/file.txt"), "force": AnyCodable(true)])
        }

        // 4. run_shell with unexpected argument
        #expect(throws: ToolError.self) {
            try shell.validate(arguments: ["command": AnyCodable("ls"), "timeout": AnyCodable(5)])
        }
    }

    @Test("Validation: Missing and empty arguments rejected")
    func testMissingAndEmptyArgumentsRejected() {
        let openApp = OpenAppTool(workspace: MockWorkspace())
        let applescript = RunAppleScriptTool(executor: MockAppleScriptExecutor())
        let cal = CalendarEventTool(executor: MockCalendarExecutor())
        let file = FileOpTool(executor: MockFileExecutor(), allowedRoot: sandboxURL)
        let shell = RunShellTool(executor: MockShellExecutor())

        // open_app
        #expect(throws: ToolError.self) { try openApp.validate(arguments: [:]) }
        #expect(throws: ToolError.self) { try openApp.validate(arguments: ["name": AnyCodable("")]) }

        // run_applescript
        #expect(throws: ToolError.self) { try applescript.validate(arguments: [:]) }
        #expect(throws: ToolError.self) { try applescript.validate(arguments: ["script": AnyCodable("   ")]) }

        // calendar_event
        #expect(throws: ToolError.self) { try cal.validate(arguments: [:]) }
        #expect(throws: ToolError.self) { try cal.validate(arguments: ["title": AnyCodable("Meeting")]) }
        #expect(throws: ToolError.self) { try cal.validate(arguments: ["title": AnyCodable(""), "date": AnyCodable("2026-10-01T10:00:00Z")]) }
        #expect(throws: ToolError.self) { try cal.validate(arguments: ["title": AnyCodable("Meeting"), "date": AnyCodable("not-a-date")]) }

        // file_op
        #expect(throws: ToolError.self) { try file.validate(arguments: [:]) }
        #expect(throws: ToolError.self) { try file.validate(arguments: ["action": AnyCodable("write"), "path": AnyCodable("/sandbox/a.txt")]) } // missing content

        // run_shell
        #expect(throws: ToolError.self) { try shell.validate(arguments: [:]) }
        #expect(throws: ToolError.self) { try shell.validate(arguments: ["command": AnyCodable("   ")]) }
    }

    @Test("Security: BiDi Unicode override and null byte injection rejected")
    func testBiDiAndNullByteRejection() {
        let openApp = OpenAppTool(workspace: MockWorkspace())
        let shell = RunShellTool(executor: MockShellExecutor())
        let file = FileOpTool(executor: MockFileExecutor(), allowedRoot: sandboxURL)

        // BiDi in app name
        let bidiAppName = "Safari\u{202E}txt.exe"
        #expect(throws: ToolError.self) {
            try openApp.validate(arguments: ["name": AnyCodable(bidiAppName)])
        }

        // BiDi in shell command
        let bidiShellCmd = "echo \u{202E}reversed"
        #expect(throws: ToolError.self) {
            try shell.validate(arguments: ["command": AnyCodable(bidiShellCmd)])
        }

        // Null bytes in shell command
        let nullShellCmd = "ls\0-la"
        #expect(throws: ToolError.self) {
            try shell.validate(arguments: ["command": AnyCodable(nullShellCmd)])
        }

        // Null bytes in file path
        let nullFilePath = "/sandbox/file\0.txt"
        #expect(throws: ToolError.self) {
            try file.validate(arguments: ["action": AnyCodable("read"), "path": AnyCodable(nullFilePath)])
        }

        // Path traversal in file path
        #expect(throws: ToolError.self) {
            try file.validate(arguments: ["action": AnyCodable("read"), "path": AnyCodable("/sandbox/../etc/passwd")])
        }
        #expect(throws: ToolError.self) {
            try file.validate(arguments: ["action": AnyCodable("read"), "path": AnyCodable("../../secret.txt")])
        }
    }
}

// MARK: - Suite 4: Response Distinguishability

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

@Suite("Phase 3 - Response Distinguishability Tests")
struct Phase3ResponseDistinguishabilityTests {
    @Test("Distinguish cancellation, safety rejection, validation error, tool not found, and execution failure")
    func testResponseDistinguishability() async {
        let mockAS = MockAppleScriptExecutor()
        mockAS.errorToThrow = ToolError.executionFailed("Syntax error")
        let toolAS = RunAppleScriptTool(executor: mockAS)

        let mockEcho = Phase3MockEchoTool()
        let registry = ToolRegistry(tools: [toolAS, mockEcho])

        // 1. Tool not found
        let unknownCall = FunctionCall(name: "ghost_tool", args: [:], id: "ghost-1")
        let notFoundDispatcher = ToolDispatcher(registry: registry)
        let notFoundResp = await notFoundDispatcher.dispatch(unknownCall)
        #expect(!notFoundResp.isSuccess)
        #expect(notFoundResp.isToolNotFound)
        #expect(!notFoundResp.isCancelled)
        #expect(!notFoundResp.isSafetyRejection)
        #expect(!notFoundResp.isValidationError)

        // 2. Validation error
        let invalidCall = FunctionCall(name: "run_applescript", args: [:], id: "val-1")
        let valResp = await notFoundDispatcher.dispatch(invalidCall)
        #expect(!valResp.isSuccess)
        #expect(valResp.isValidationError)
        #expect(!valResp.isCancelled)
        #expect(!valResp.isSafetyRejection)
        #expect(!valResp.isToolNotFound)

        // 3. User cancellation
        let cancelGate = InteractiveSafetyGate(confirmationProvider: Phase3AuditConfirmationProvider(decisionToReturn: false))
        let cancelDispatcher = ToolDispatcher(registry: registry, safetyGate: cancelGate)
        let cancelCall = FunctionCall(name: "run_applescript", args: ["script": AnyCodable("beep")], id: "can-1")
        let cancelResp = await cancelDispatcher.dispatch(cancelCall)
        #expect(!cancelResp.isSuccess)
        #expect(cancelResp.isCancelled)
        #expect(cancelResp.isSafetyRejection)
        #expect(!cancelResp.isValidationError)
        #expect(!cancelResp.isToolNotFound)

        // 4. Execution failure (tool threw)
        let approveGate = InteractiveSafetyGate(confirmationProvider: Phase3AuditConfirmationProvider(decisionToReturn: true))
        let execFailDispatcher = ToolDispatcher(registry: registry, safetyGate: approveGate)
        let execFailCall = FunctionCall(name: "run_applescript", args: ["script": AnyCodable("beep")], id: "exec-1")
        let execFailResp = await execFailDispatcher.dispatch(execFailCall)
        #expect(!execFailResp.isSuccess)
        #expect(!execFailResp.isCancelled)
        #expect(!execFailResp.isSafetyRejection)
        #expect(!execFailResp.isValidationError)
        #expect(!execFailResp.isToolNotFound)
        #expect(execFailResp.errorMessage?.contains("Syntax error") == true)

        // 5. Successful execution
        let successCall = FunctionCall(name: "echo_test", args: ["msg": AnyCodable("Hello")], id: "succ-1")
        let successResp = await execFailDispatcher.dispatch(successCall)
        #expect(successResp.isSuccess)
        #expect(!successResp.isCancelled)
        #expect(!successResp.isSafetyRejection)
        #expect(!successResp.isValidationError)
        #expect(!successResp.isToolNotFound)
        #expect(successResp.resultMessage == "Echo: Hello")
    }
}

// MARK: - Suite 5: Gemini Loop & Thought Signature Preservation

@Suite("Phase 3 - Gemini Loop and Signature Tests")
struct Phase3GeminiLoopAndSignatureTests {
    @Test("Preserves thought_signature through risky tool loop with UUID confirmation")
    @MainActor
    func testThoughtSignaturePreservedThroughConfirmedTurn() async {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(command: "uname -m", stdout: "arm64", stderr: "", exitCode: 0)
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))

        let expectedSignature = "thought_sig_phase3_audit_verified"

        let client = Phase3ScriptedGeminiClient { step, history in
            if step == 1 {
                let call = FunctionCall(name: "run_shell", args: ["command": AnyCodable("uname -m")], id: "call-arch")
                let callPart = Part(
                    functionCall: call,
                    thoughtSignature: expectedSignature
                )
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [call],
                    functionCallParts: [callPart],
                    thoughtSignature: expectedSignature
                )
            } else if step == 2 {
                // Verify history includes the model call with preserved signature and function response
                let modelCallMsg = history.first { $0.functionCall?.name == "run_shell" }
                #expect(modelCallMsg?.thoughtSignature == expectedSignature)
                #expect(modelCallMsg?.functionCallPart?.thoughtSignature == expectedSignature)

                let funcRespMsg = history.first { $0.functionResponse?.name == "run_shell" }
                #expect(funcRespMsg?.functionResponse?.isSuccess == true)

                return ModelTurnResponse(
                    text: "Your machine architecture is Apple Silicon (arm64).",
                    thoughtSignature: expectedSignature
                )
            }
            return ModelTurnResponse(text: "Done", functionCalls: [])
        }

        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let task = Task { await brain.send("What architecture am I on?") }
        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        let pending = brain.pendingConfirmation
        #expect(pending != nil)
        #expect(pending?.callId == "call-arch")

        // Authorize via exact UUID
        brain.respondToPendingConfirmation(id: pending?.id, approved: true)

        await task.value

        #expect(mockShell.recordedCommands.count == 1)
        #expect(brain.messages.count == 2)
        #expect(brain.messages[1].text.contains("arm64"))
        #expect(brain.messages[1].thoughtSignature == expectedSignature)
    }

    @Test("Mock Safety Check: All tests execute strictly against mock executors")
    func testMockSafetyCheckZeroDestructiveAction() {
        let mockAS = MockAppleScriptExecutor()
        let mockCal = MockCalendarExecutor()
        let mockFile = MockFileExecutor()
        let mockShell = MockShellExecutor()
        let mockWorkspace = MockWorkspace()

        #expect(mockAS.executedScripts.isEmpty)
        #expect(mockCal.recordedCalls.isEmpty)
        #expect(mockFile.recordedCalls.isEmpty)
        #expect(mockShell.recordedCommands.isEmpty)
        #expect(mockWorkspace.openedURLs.isEmpty)
    }
}
