import Testing
import Foundation
@testable import IvyCore

private final class FileTestConfirmationProvider: ConfirmationProvider, @unchecked Sendable {
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

// MARK: - Phase 2D SafetyGate & Classification Tests

@Suite("Phase 2D - SafetyGate Tests")
struct Phase2DSafetyGateTests {
    let sandboxURL: URL = URL(fileURLWithPath: "/Users/testuser/Sandbox")

    @Test("Classification: read is safe, write and delete are risky")
    func testFileOpClassification() {
        let policy = SafetyPolicy()
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)

        // 1. read action -> safe
        let readCall = FunctionCall(name: "file_op", args: [
            "action": AnyCodable("read"),
            "path": AnyCodable("/Users/testuser/Sandbox/note.txt")
        ])
        #expect(policy.classification(for: tool, call: readCall) == .safe)

        // 2. write action -> risky
        let writeCall = FunctionCall(name: "file_op", args: [
            "action": AnyCodable("write"),
            "path": AnyCodable("/Users/testuser/Sandbox/note.txt"),
            "content": AnyCodable("data")
        ])
        #expect(policy.classification(for: tool, call: writeCall) == .risky)

        // 3. delete action -> risky
        let deleteCall = FunctionCall(name: "file_op", args: [
            "action": AnyCodable("delete"),
            "path": AnyCodable("/Users/testuser/Sandbox/note.txt")
        ])
        #expect(policy.classification(for: tool, call: deleteCall) == .risky)

        // 4. Default without call -> risky
        #expect(policy.classification(for: tool) == .risky)
    }

    @Test("Safe tool file_op read auto-executes under InteractiveSafetyGate without prompting")
    func testSafeReadAutoExecutes() async {
        let provider = FileTestConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mock = MockFileExecutor()
        let filePath = sandboxURL.appendingPathComponent("data.txt").path
        mock.files[filePath] = "Secret file content"

        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let call = FunctionCall(name: "file_op", args: [
            "action": AnyCodable("read"),
            "path": AnyCodable(filePath)
        ], id: "read-call")

        let response = await dispatcher.dispatch(call)

        #expect(provider.callCount == 0)
        #expect(response.response["success"]?.boolValue == true)
        #expect(response.response["result"]?.stringValue == "Secret file content")
        #expect(mock.recordedCalls.count == 1)
    }

    @Test("Risky tool file_op write triggers confirmation with warning about content replacement")
    func testRiskyWriteTriggersConfirmation() async {
        let provider = FileTestConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mock = MockFileExecutor()
        let filePath = sandboxURL.appendingPathComponent("data.txt").path
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let call = FunctionCall(name: "file_op", args: [
            "action": AnyCodable("write"),
            "path": AnyCodable(filePath),
            "content": AnyCodable("New data")
        ], id: "write-call")

        let response = await dispatcher.dispatch(call)

        #expect(provider.callCount == 1)
        let req = provider.recordedRequests.first
        #expect(req?.toolName == "file_op")
        #expect(req?.title == "Write File")
        #expect(req?.detail.contains("Existing content may be overwritten") == true)
        #expect(req?.detail.contains("Target Path: \(filePath)") == true)
        #expect(response.response["success"]?.boolValue == true)
        #expect(mock.recordedCalls.count == 1)
        #expect(mock.files[filePath] == "New data")
    }

    @Test("Risky tool file_op delete triggers confirmation with permanent deletion warning")
    func testRiskyDeleteTriggersConfirmation() async {
        let provider = FileTestConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mock = MockFileExecutor()
        let filePath = sandboxURL.appendingPathComponent("remove.txt").path
        mock.files[filePath] = "old"
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let call = FunctionCall(name: "file_op", args: [
            "action": AnyCodable("delete"),
            "path": AnyCodable(filePath)
        ], id: "delete-call")

        let response = await dispatcher.dispatch(call)

        #expect(provider.callCount == 1)
        let req = provider.recordedRequests.first
        #expect(req?.toolName == "file_op")
        #expect(req?.title == "Delete File")
        #expect(req?.detail.contains("Permanent deletion cannot be undone") == true)
        #expect(req?.detail.contains("Target Path: \(filePath)") == true)
        #expect(response.response["success"]?.boolValue == true)
        #expect(mock.files[filePath] == nil)
        #expect(mock.recordedCalls.count == 1)
    }

    @Test("Cancellation halts execution: user rejecting confirmation prevents write or delete")
    func testCancellationPreventsExecution() async {
        let provider = FileTestConfirmationProvider(decisionToReturn: false)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mock = MockFileExecutor()
        let filePath = sandboxURL.appendingPathComponent("untouched.txt").path
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let call = FunctionCall(name: "file_op", args: [
            "action": AnyCodable("write"),
            "path": AnyCodable(filePath),
            "content": AnyCodable("Malicious payload")
        ], id: "cancel-call")

        let response = await dispatcher.dispatch(call)

        #expect(provider.callCount == 1)
        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["error"]?.stringValue?.contains("User cancelled") == true)
        #expect(mock.recordedCalls.isEmpty)
        #expect(mock.files[filePath] == nil)
    }

    @Test("Malformed arguments reject before SafetyGate evaluation")
    func testMalformedArgumentsRejectBeforeGate() async {
        let provider = FileTestConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        // 1. Missing action
        let call1 = FunctionCall(name: "file_op", args: ["path": AnyCodable("/Users/testuser/Sandbox/file.txt")], id: "c1")
        let resp1 = await dispatcher.dispatch(call1)
        #expect(resp1.response["success"]?.boolValue == false)
        #expect(provider.callCount == 0)

        // 2. Traversal path
        let call2 = FunctionCall(name: "file_op", args: [
            "action": AnyCodable("write"),
            "path": AnyCodable("../../etc/passwd"),
            "content": AnyCodable("root:x:0:0")
        ], id: "c2")
        let resp2 = await dispatcher.dispatch(call2)
        #expect(resp2.response["success"]?.boolValue == false)
        #expect(resp2.response["error"]?.stringValue?.contains("Path traversal sequence '..' is prohibited") == true)
        #expect(provider.callCount == 0)

        // 3. Write missing content
        let call3 = FunctionCall(name: "file_op", args: [
            "action": AnyCodable("write"),
            "path": AnyCodable("/Users/testuser/Sandbox/note.txt")
        ], id: "c3")
        let resp3 = await dispatcher.dispatch(call3)
        #expect(resp3.response["success"]?.boolValue == false)
        #expect(resp3.response["error"]?.stringValue?.contains("Missing required argument: 'content'") == true)
        #expect(provider.callCount == 0)
    }
}

// MARK: - Phase 2D Confirmation Workflow & Idempotency Tests

@Suite("Phase 2D - Confirmation Workflow Tests")
struct Phase2DConfirmationWorkflowTests {
    let sandboxURL: URL = URL(fileURLWithPath: "/Users/testuser/Sandbox")

    @Test("Pending write confirmation pauses execution until decision")
    @MainActor
    func testPendingWritePausesExecution() async {
        let mock = MockFileExecutor()
        let filePath = sandboxURL.appendingPathComponent("draft.txt").path
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        final class WriteClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "File written successfully.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "file_op", args: [
                        "action": AnyCodable("write"),
                        "path": AnyCodable("/Users/testuser/Sandbox/draft.txt"),
                        "content": AnyCodable("Draft text")
                    ], id: "call-w1")]
                )
            }
        }

        let brain = IvyBrain(client: WriteClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Save draft")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.title == "Write File")
        #expect(mock.recordedCalls.isEmpty)

        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mock.recordedCalls.count == 1)
        #expect(mock.files[filePath] == "Draft text")
    }

    @Test("Repeated approval cannot execute write twice")
    @MainActor
    func testRepeatedWriteApprovalIdempotency() async {
        let mock = MockFileExecutor()
        let filePath = sandboxURL.appendingPathComponent("log.txt").path
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
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
                    functionCalls: [FunctionCall(name: "file_op", args: [
                        "action": AnyCodable("write"),
                        "path": AnyCodable("/Users/testuser/Sandbox/log.txt"),
                        "content": AnyCodable("entry 1")
                    ], id: "call-once")]
                )
            }
        }

        let brain = IvyBrain(client: OnceClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Append to log")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        brain.respondToPendingConfirmation(approved: true)
        // Rapid second and third click
        brain.respondToPendingConfirmation(approved: true)
        brain.respondToPendingConfirmation(approved: true)

        await sendTask.value

        #expect(mock.recordedCalls.count == 1)
        #expect(mock.files[filePath] == "entry 1")
    }

    @Test("Pending delete confirmation pauses execution until decision")
    @MainActor
    func testPendingDeletePausesExecution() async {
        let mock = MockFileExecutor()
        let filePath = sandboxURL.appendingPathComponent("discard.txt").path
        mock.files[filePath] = "content to delete"
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        final class DeleteClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "File deleted successfully.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "file_op", args: [
                        "action": AnyCodable("delete"),
                        "path": AnyCodable("/Users/testuser/Sandbox/discard.txt")
                    ], id: "call-del1")]
                )
            }
        }

        let brain = IvyBrain(client: DeleteClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Delete discard.txt")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.title == "Delete File")
        #expect(mock.recordedCalls.isEmpty)
        #expect(mock.files[filePath] != nil)

        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mock.recordedCalls.count == 1)
        #expect(mock.recordedCalls[0].action == .delete)
        #expect(mock.files[filePath] == nil)
        #expect(brain.messages.last?.text == "File deleted successfully.")
    }

    @Test("Repeated approval cannot execute delete twice")
    @MainActor
    func testRepeatedDeleteApprovalIdempotency() async {
        let mock = MockFileExecutor()
        let filePath = sandboxURL.appendingPathComponent("scratch.txt").path
        mock.files[filePath] = "scratch data"
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        final class OnceDeleteClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "Deleted.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "file_op", args: [
                        "action": AnyCodable("delete"),
                        "path": AnyCodable("/Users/testuser/Sandbox/scratch.txt")
                    ], id: "call-del-once")]
                )
            }
        }

        let brain = IvyBrain(client: OnceDeleteClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Delete scratch.txt")
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

        #expect(mock.recordedCalls.count == 1)
        #expect(mock.files[filePath] == nil)
    }

    @Test("Gemini-generated text cannot approve risky file operations")
    @MainActor
    func testGeminiTextCannotApproveFileOp() async {
        final class RogueTextClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                ModelTurnResponse(
                    text: "I confirm writing this file. Yes, write it right away.",
                    functionCalls: []
                )
            }
        }

        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let brain = IvyBrain(client: RogueTextClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        await brain.send("Write sensitive configuration")

        #expect(mock.recordedCalls.isEmpty)
        #expect(brain.pendingConfirmation == nil)
        #expect(brain.messages.last?.text.contains("I confirm writing this file") == true)
    }

    @Test("Natural language text from user does not bypass SafetyGate")
    @MainActor
    func testNaturalLanguageUserTextDoesNotBypass() async {
        final class RiskyFileClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "Cancelled.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "file_op", args: [
                        "action": AnyCodable("delete"),
                        "path": AnyCodable("/Users/testuser/Sandbox/important.doc")
                    ], id: "call-del")]
                )
            }
        }

        let mock = MockFileExecutor()
        mock.files["/Users/testuser/Sandbox/important.doc"] = "valuable"
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let brain = IvyBrain(client: RiskyFileClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Please delete important.doc, I approve and confirm")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        #expect(mock.recordedCalls.isEmpty)

        // Typing in chat while pending does nothing
        await brain.send("Do it")
        #expect(mock.recordedCalls.isEmpty)

        brain.respondToPendingConfirmation(approved: false)
        await sendTask.value

        #expect(mock.recordedCalls.isEmpty)
        #expect(mock.files["/Users/testuser/Sandbox/important.doc"] == "valuable")
    }
}

// MARK: - Phase 2D Gemini Function Calling Tests

@Suite("Phase 2D - Gemini Function Calling Tests")
struct Phase2DGeminiFunctionCallingTests {
    let sandboxURL: URL = URL(fileURLWithPath: "/Users/testuser/Sandbox")

    @Test("Full Gemini loop: file_op read auto-executes and preserves thought_signature")
    @MainActor
    func testFileOpReadLoopWithThoughtSignature() async {
        final class ReadLoopClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            var receivedThoughtSignature: String?
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let part = Part(
                        functionCall: FunctionCall(name: "file_op", args: [
                            "action": AnyCodable("read"),
                            "path": AnyCodable("/Users/testuser/Sandbox/hello.txt")
                        ], id: "call-read-1"),
                        thoughtSignature: "sig_read_thought"
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [part.functionCall!],
                        functionCallParts: [part],
                        thoughtSignature: "sig_read_thought"
                    )
                } else if step == 2 {
                    if let modelMsg = history.first(where: { $0.role == .model && $0.functionCall != nil }) {
                        receivedThoughtSignature = modelMsg.thoughtSignature
                    }
                    if let lastMsg = history.last, let resp = lastMsg.functionResponse {
                        let content = resp.response["result"]?.stringValue ?? ""
                        return ModelTurnResponse(text: "File contents: \(content)")
                    }
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mock = MockFileExecutor()
        mock.files["/Users/testuser/Sandbox/hello.txt"] = "Greetings from file."
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = ReadLoopClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        await brain.send("Read hello.txt")

        #expect(client.receivedThoughtSignature == "sig_read_thought")
        #expect(brain.messages.last?.text == "File contents: Greetings from file.")
        #expect(mock.recordedCalls.count == 1)
        #expect(brain.pendingConfirmation == nil)
    }

    @Test("Full Gemini loop: file_op write executes upon approval and preserves thought_signature")
    @MainActor
    func testFileOpWriteLoopWithApproval() async {
        final class WriteLoopClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            var receivedThoughtSignature: String?
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let part = Part(
                        functionCall: FunctionCall(name: "file_op", args: [
                            "action": AnyCodable("write"),
                            "path": AnyCodable("/Users/testuser/Sandbox/new.txt"),
                            "content": AnyCodable("Content saved")
                        ], id: "call-write-1"),
                        thoughtSignature: "sig_write_thought"
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [part.functionCall!],
                        functionCallParts: [part],
                        thoughtSignature: "sig_write_thought"
                    )
                } else if step == 2 {
                    if let modelMsg = history.first(where: { $0.role == .model && $0.functionCall != nil }) {
                        receivedThoughtSignature = modelMsg.thoughtSignature
                    }
                    return ModelTurnResponse(text: "I wrote the file. Don't lose it.")
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mock = MockFileExecutor()
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = WriteLoopClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Write new.txt")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(client.receivedThoughtSignature == "sig_write_thought")
        #expect(mock.files["/Users/testuser/Sandbox/new.txt"] == "Content saved")
        #expect(brain.messages.last?.text == "I wrote the file. Don't lose it.")
    }

    @Test("Cancellation sends structured cancellation to Gemini and receives witty reply")
    @MainActor
    func testFileOpCancellationLoop() async {
        final class CancelClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let part = Part(
                        functionCall: FunctionCall(name: "file_op", args: [
                            "action": AnyCodable("delete"),
                            "path": AnyCodable("/Users/testuser/Sandbox/junk.txt")
                        ], id: "call-del-1"),
                        thoughtSignature: "sig_del_thought"
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [part.functionCall!],
                        functionCallParts: [part],
                        thoughtSignature: "sig_del_thought"
                    )
                } else if step == 2 {
                    if let last = history.last, let resp = last.functionResponse {
                        let err = resp.response["error"]?.stringValue ?? ""
                        return ModelTurnResponse(text: "You chickened out (\(err)). Junk remains intact.")
                    }
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mock = MockFileExecutor()
        mock.files["/Users/testuser/Sandbox/junk.txt"] = "garbage"
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = CancelClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Delete junk")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        brain.respondToPendingConfirmation(approved: false)
        await sendTask.value

        #expect(mock.files["/Users/testuser/Sandbox/junk.txt"] == "garbage")
        #expect(mock.recordedCalls.isEmpty)
        #expect(brain.messages.last?.text.contains("You chickened out") == true)
    }

    @Test("File executor error is reported in functionResponse and explained by Gemini")
    @MainActor
    func testFileOpErrorExplanation() async {
        final class ErrorClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let part = Part(
                        functionCall: FunctionCall(name: "file_op", args: [
                            "action": AnyCodable("read"),
                            "path": AnyCodable("/Users/testuser/Sandbox/absent.txt")
                        ], id: "call-err-1"),
                        thoughtSignature: "sig_err"
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [part.functionCall!],
                        functionCallParts: [part],
                        thoughtSignature: "sig_err"
                    )
                } else if step == 2 {
                    if let last = history.last, let resp = last.functionResponse {
                        let err = resp.response["error"]?.stringValue ?? ""
                        return ModelTurnResponse(text: "That file doesn't exist: \(err)")
                    }
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mock = MockFileExecutor()
        // File absent.txt not added
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = ErrorClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        await brain.send("Read absent.txt")

        #expect(brain.messages.last?.text.contains("File not found") == true)
    }

    @Test("Multi-turn sequential file operations preserve respective thought_signatures and responses")
    @MainActor
    func testMultiTurnSequentialFileOpTurns() async {
        final class MultiTurnFileClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            var signaturesSeen: [String] = []

            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let part = Part(
                        functionCall: FunctionCall(name: "file_op", args: [
                            "action": AnyCodable("read"),
                            "path": AnyCodable("/Users/testuser/Sandbox/source.txt")
                        ], id: "call-step-1"),
                        thoughtSignature: "sig_seq_1"
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [part.functionCall!],
                        functionCallParts: [part],
                        thoughtSignature: "sig_seq_1"
                    )
                } else if step == 2 {
                    if let m1 = history.first(where: { $0.role == .model && $0.thoughtSignature != nil }) {
                        signaturesSeen.append(m1.thoughtSignature ?? "")
                    }
                    let part = Part(
                        functionCall: FunctionCall(name: "file_op", args: [
                            "action": AnyCodable("write"),
                            "path": AnyCodable("/Users/testuser/Sandbox/backup.txt"),
                            "content": AnyCodable("Source: sample content")
                        ], id: "call-step-2"),
                        thoughtSignature: "sig_seq_2"
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [part.functionCall!],
                        functionCallParts: [part],
                        thoughtSignature: "sig_seq_2"
                    )
                } else if step == 3 {
                    let modelSignatures = history.filter({ $0.role == .model }).compactMap({ $0.thoughtSignature })
                    signaturesSeen = modelSignatures
                    return ModelTurnResponse(text: "Backup completed successfully.")
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mock = MockFileExecutor()
        mock.files["/Users/testuser/Sandbox/source.txt"] = "sample content"
        let tool = FileOpTool(executor: mock, allowedRoot: sandboxURL)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = MultiTurnFileClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Backup source.txt")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.title == "Write File")

        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mock.recordedCalls.count == 2)
        #expect(mock.recordedCalls[0].action == .read)
        #expect(mock.recordedCalls[1].action == .write)
        #expect(mock.files["/Users/testuser/Sandbox/backup.txt"] == "Source: sample content")
        #expect(client.signaturesSeen.contains("sig_seq_1"))
        #expect(client.signaturesSeen.contains("sig_seq_2"))
        #expect(brain.messages.last?.text == "Backup completed successfully.")
    }
}

// MARK: - Phase 2D Regressions Tests

@Suite("Phase 2D - Regression Tests")
struct Phase2DRegressionTests {
    let sandboxURL: URL = URL(fileURLWithPath: "/Users/testuser/Sandbox")

    @Test("Phase 1 regression: pure text multi-turn conversation unaffected by file_op")
    @MainActor
    func testPhase1PureTextRegression() async {
        final class TextClient: GeminiClientProtocol, @unchecked Sendable {
            var callCount = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                callCount += 1
                return ModelTurnResponse(text: "Answer \(callCount)")
            }
        }

        let mockFile = MockFileExecutor()
        let registry = ToolRegistry.defaultRegistry(
            workspace: MockWorkspace(),
            appleScriptExecutor: MockAppleScriptExecutor(),
            calendarExecutor: MockCalendarExecutor(),
            fileExecutor: mockFile,
            allowedFileRoot: sandboxURL
        )

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let brain = IvyBrain(client: TextClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        await brain.send("Hello")
        #expect(brain.messages.last?.text == "Answer 1")

        await brain.send("Tell me more")
        #expect(brain.messages.last?.text == "Answer 2")
        #expect(brain.messages.count == 4)
        #expect(mockFile.recordedCalls.isEmpty)
    }

    @Test("Phase 2A regression: open_app executes without confirmation")
    @MainActor
    func testPhase2AOpenAppRegression() async {
        let mockWS = MockWorkspace()
        mockWS.knownApps["safari"] = URL(fileURLWithPath: "/Applications/Safari.app")

        let registry = ToolRegistry.defaultRegistry(
            workspace: mockWS,
            appleScriptExecutor: MockAppleScriptExecutor(),
            calendarExecutor: MockCalendarExecutor(),
            fileExecutor: MockFileExecutor(),
            allowedFileRoot: sandboxURL
        )

        final class OpenClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let part = Part(
                        functionCall: FunctionCall(name: "open_app", args: ["name": AnyCodable("Safari")], id: "c-app"),
                        thoughtSignature: "sig_app"
                    )
                    return ModelTurnResponse(text: nil, functionCalls: [part.functionCall!], functionCallParts: [part], thoughtSignature: "sig_app")
                } else {
                    return ModelTurnResponse(text: "Safari opened.")
                }
            }
        }

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let brain = IvyBrain(client: OpenClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        await brain.send("Open Safari")

        #expect(mockWS.openedURLs.contains(where: { $0.lastPathComponent == "Safari.app" }))
        #expect(brain.pendingConfirmation == nil)
        #expect(brain.messages.last?.text == "Safari opened.")
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
            allowedFileRoot: sandboxURL
        )

        final class ScriptClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let part = Part(
                        functionCall: FunctionCall(name: "run_applescript", args: ["script": AnyCodable("beep")], id: "c-as"),
                        thoughtSignature: "sig_as"
                    )
                    return ModelTurnResponse(text: nil, functionCalls: [part.functionCall!], functionCallParts: [part], thoughtSignature: "sig_as")
                } else {
                    return ModelTurnResponse(text: "Beep done.")
                }
            }
        }

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let brain = IvyBrain(client: ScriptClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Run beep script")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mockAS.executedScripts.count == 1)
        #expect(brain.messages.last?.text == "Beep done.")
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
            allowedFileRoot: sandboxURL
        )

        final class CalClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let part = Part(
                        functionCall: FunctionCall(name: "calendar_event", args: [
                            "title": AnyCodable("Sprint Review"),
                            "date": AnyCodable("2026-10-01T15:00:00Z")
                        ], id: "c-cal"),
                        thoughtSignature: "sig_cal"
                    )
                    return ModelTurnResponse(text: nil, functionCalls: [part.functionCall!], functionCallParts: [part], thoughtSignature: "sig_cal")
                } else {
                    return ModelTurnResponse(text: "Sprint Review added.")
                }
            }
        }

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let brain = IvyBrain(client: CalClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Add sprint review")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mockCal.recordedCalls.count == 1)
        #expect(brain.messages.last?.text == "Sprint Review added.")
    }

    @Test("Chained multi-tool turns: file_op read auto-executes, then file_op write prompts and executes")
    @MainActor
    func testChainedReadThenWrite() async {
        let mockFile = MockFileExecutor()
        let filePath = sandboxURL.appendingPathComponent("chain.txt").path
        mockFile.files[filePath] = "initial data"

        let registry = ToolRegistry.defaultRegistry(
            workspace: MockWorkspace(),
            appleScriptExecutor: MockAppleScriptExecutor(),
            calendarExecutor: MockCalendarExecutor(),
            fileExecutor: mockFile,
            allowedFileRoot: sandboxURL
        )

        final class ChainedClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let part = Part(
                        functionCall: FunctionCall(name: "file_op", args: [
                            "action": AnyCodable("read"),
                            "path": AnyCodable("/Users/testuser/Sandbox/chain.txt")
                        ], id: "c-ch-read"),
                        thoughtSignature: "sig_ch_read"
                    )
                    return ModelTurnResponse(text: nil, functionCalls: [part.functionCall!], functionCallParts: [part], thoughtSignature: "sig_ch_read")
                } else if step == 2 {
                    let part = Part(
                        functionCall: FunctionCall(name: "file_op", args: [
                            "action": AnyCodable("write"),
                            "path": AnyCodable("/Users/testuser/Sandbox/chain.txt"),
                            "content": AnyCodable("appended data")
                        ], id: "c-ch-write"),
                        thoughtSignature: "sig_ch_write"
                    )
                    return ModelTurnResponse(text: nil, functionCalls: [part.functionCall!], functionCallParts: [part], thoughtSignature: "sig_ch_write")
                } else {
                    return ModelTurnResponse(text: "Chain complete.")
                }
            }
        }

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let brain = IvyBrain(client: ChainedClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Read and update chain.txt")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        // The read auto-executed, and now it paused on the write!
        #expect(mockFile.recordedCalls.count == 1)
        #expect(mockFile.recordedCalls[0].action == .read)
        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.title == "Write File")

        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mockFile.recordedCalls.count == 2)
        #expect(mockFile.recordedCalls[1].action == .write)
        #expect(mockFile.files[filePath] == "appended data")
        #expect(brain.messages.last?.text == "Chain complete.")
    }
}
