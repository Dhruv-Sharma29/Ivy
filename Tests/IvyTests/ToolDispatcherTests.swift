import Testing
import Foundation
@testable import IvyCore

private struct MockEchoTool: IvyTool, Sendable {
    let name: String = "echo_test"
    let description: String = "Echoes the message"
    var safetyClassification: ToolSafetyClassification { .safe }
    let declaration: FunctionDeclaration = FunctionDeclaration(
        name: "echo_test",
        description: "Echoes the message",
        parameters: ToolParameters(
            type: "OBJECT",
            properties: ["msg": ToolProperty(type: "STRING", description: "Message")],
            required: ["msg"]
        )
    )

    func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard let msg = arguments["msg"]?.stringValue else {
            throw ToolError.missingArgument("msg")
        }
        if msg == "throw_error" {
            throw ToolError.executionFailed("Simulated crash")
        }
        if msg == "return_failure" {
            return ToolResult.failure("Execution failed gracefully")
        }
        return ToolResult.success("Echo: \(msg)")
    }
}

@Suite("ToolDispatcher and ToolRegistry Tests")
struct ToolDispatcherTests {

    @Test("ToolRegistry registers and retrieves tools")
    func testRegistryLookup() {
        let echo = MockEchoTool()
        let registry = ToolRegistry(tools: [echo])

        #expect(registry.tool(named: "echo_test") != nil)
        #expect(registry.tool(named: "non_existent") == nil)
        #expect(registry.allTools.count == 1)
        #expect(registry.toolDeclarations.count == 1)
        #expect(registry.toolDeclarations.first?.functionDeclarations.first?.name == "echo_test")
    }

    @Test("ToolRegistry.defaultRegistry includes open_app")
    func testDefaultRegistry() {
        let registry = ToolRegistry.defaultRegistry(workspace: MockWorkspace())
        #expect(registry.tool(named: "open_app") != nil)
        #expect(registry.toolDeclarations.count == 1)
    }

    @Test("ToolDispatcher successfully dispatches known tool")
    func testSuccessfulDispatch() async {
        let echo = MockEchoTool()
        let registry = ToolRegistry(tools: [echo])
        let dispatcher = ToolDispatcher(registry: registry)

        let call = FunctionCall(name: "echo_test", args: ["msg": "Hello Ivy"], id: "call-1")
        let response = await dispatcher.dispatch(call)

        #expect(response.name == "echo_test")
        #expect(response.id == "call-1")
        #expect(response.response["result"]?.stringValue == "Echo: Hello Ivy")
        #expect(response.response["success"]?.boolValue == true)
    }

    @Test("ToolDispatcher returns error response for unknown tool")
    func testUnknownToolDispatch() async {
        let registry = ToolRegistry(tools: [])
        let dispatcher = ToolDispatcher(registry: registry)

        let call = FunctionCall(name: "unknown_tool", args: [:], id: "call-2")
        let response = await dispatcher.dispatch(call)

        #expect(response.name == "unknown_tool")
        #expect(response.id == "call-2")
        #expect(response.response["error"]?.stringValue?.contains("not recognized") == true)
    }

    @Test("ToolDispatcher captures tool execution failure result")
    func testToolFailureResult() async {
        let echo = MockEchoTool()
        let registry = ToolRegistry(tools: [echo])
        let dispatcher = ToolDispatcher(registry: registry)

        let call = FunctionCall(name: "echo_test", args: ["msg": "return_failure"], id: "call-3")
        let response = await dispatcher.dispatch(call)

        #expect(response.name == "echo_test")
        #expect(response.id == "call-3")
        #expect(response.response["error"]?.stringValue == "Execution failed gracefully")
        #expect(response.response["success"]?.boolValue == false)
    }

    @Test("ToolDispatcher captures thrown tool errors")
    func testToolThrownError() async {
        let echo = MockEchoTool()
        let registry = ToolRegistry(tools: [echo])
        let dispatcher = ToolDispatcher(registry: registry)

        let call = FunctionCall(name: "echo_test", args: ["msg": "throw_error"], id: "call-4")
        let response = await dispatcher.dispatch(call)

        #expect(response.name == "echo_test")
        #expect(response.id == "call-4")
        #expect(response.response["error"]?.stringValue?.contains("Simulated crash") == true)
        #expect(response.response["success"]?.boolValue == false)
    }

    @Test("ToolDispatcher handles missing argument errors")
    func testToolMissingArgument() async {
        let echo = MockEchoTool()
        let registry = ToolRegistry(tools: [echo])
        let dispatcher = ToolDispatcher(registry: registry)

        let call = FunctionCall(name: "echo_test", args: [:], id: "call-5")
        let response = await dispatcher.dispatch(call)

        #expect(response.name == "echo_test")
        #expect(response.response["error"]?.stringValue?.contains("Missing required argument") == true)
    }

    @Test("ToolDispatcher dispatches multiple calls sequentially")
    func testDispatchAll() async {
        let echo = MockEchoTool()
        let registry = ToolRegistry(tools: [echo])
        let dispatcher = ToolDispatcher(registry: registry)

        let calls = [
            FunctionCall(name: "echo_test", args: ["msg": "First"], id: "1"),
            FunctionCall(name: "echo_test", args: ["msg": "Second"], id: "2")
        ]

        let responses = await dispatcher.dispatchAll(calls)
        #expect(responses.count == 2)
        #expect(responses[0].response["result"]?.stringValue == "Echo: First")
        #expect(responses[1].response["result"]?.stringValue == "Echo: Second")
    }

    @Test("ToolRegistry handles duplicate tool registration by overwriting with latest tool")
    func testDuplicateRegistration() {
        struct MockToolA: IvyTool, Sendable {
            let name = "test_tool"
            let description = "First version"
            let declaration = FunctionDeclaration(name: "test_tool", description: "First version")
            func execute(arguments: [String: AnyCodable]) async throws -> ToolResult { .success("v1") }
        }

        struct MockToolB: IvyTool, Sendable {
            let name = "test_tool"
            let description = "Second version"
            let declaration = FunctionDeclaration(name: "test_tool", description: "Second version")
            func execute(arguments: [String: AnyCodable]) async throws -> ToolResult { .success("v2") }
        }

        let registry = ToolRegistry(tools: [MockToolA(), MockToolB()])
        #expect(registry.allTools.count == 1)
        #expect(registry.tool(named: "test_tool")?.description == "Second version")
        #expect(registry.toolDeclarations.first?.functionDeclarations.count == 1)
    }

    @Test("ToolRegistry registering and registering(contentsOf:) methods")
    func testDynamicRegistrationMethods() {
        let registry0 = ToolRegistry(tools: [])
        #expect(registry0.allTools.isEmpty)
        #expect(registry0.toolDeclarations.isEmpty)

        let echo = MockEchoTool()
        let registry1 = registry0.registering(echo)
        #expect(registry1.allTools.count == 1)
        #expect(registry1.tool(named: "echo_test") != nil)

        let openApp = OpenAppTool(workspace: MockWorkspace())
        let registry2 = registry1.registering(contentsOf: [openApp])
        #expect(registry2.allTools.count == 2)
        #expect(registry2.tool(named: "open_app") != nil)
        #expect(registry2.tool(named: "echo_test") != nil)
    }

    @Test("ToolDispatcher successfully dispatches open_app through default registry")
    func testOpenAppDispatch() async {
        let mockWS = MockWorkspace()
        mockWS.knownApps["safari.app"] = URL(fileURLWithPath: "/Applications/Safari.app")
        let registry = ToolRegistry.defaultRegistry(workspace: mockWS)
        let dispatcher = ToolDispatcher(registry: registry)

        let call = FunctionCall(name: "open_app", args: ["name": "Safari"], id: "call-open-safari")
        let response = await dispatcher.dispatch(call)

        #expect(response.name == "open_app")
        #expect(response.id == "call-open-safari")
        #expect(response.response["success"]?.boolValue == true)
        #expect(response.response["result"]?.stringValue?.contains("Opened Safari successfully.") == true)
        #expect(mockWS.openedURLs.count == 1)
    }

    @Test("ToolDispatcher captures open_app not found error in response")
    func testOpenAppNotFoundDispatch() async {
        let mockWS = MockWorkspace()
        let registry = ToolRegistry.defaultRegistry(workspace: mockWS)
        let dispatcher = ToolDispatcher(registry: registry)

        let call = FunctionCall(name: "open_app", args: ["name": "UnknownApp123"], id: "call-unknown")
        let response = await dispatcher.dispatch(call)

        #expect(response.name == "open_app")
        #expect(response.id == "call-unknown")
        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["error"]?.stringValue?.contains("not found") == true)
    }

    @Test("ToolDispatcher captures open_app invalid argument in response")
    func testOpenAppInvalidArgumentDispatch() async {
        let mockWS = MockWorkspace()
        let registry = ToolRegistry.defaultRegistry(workspace: mockWS)
        let dispatcher = ToolDispatcher(registry: registry)

        let call = FunctionCall(name: "open_app", args: ["name": "Safari; echo hacked"], id: "call-injection")
        let response = await dispatcher.dispatch(call)

        #expect(response.name == "open_app")
        #expect(response.id == "call-injection")
        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["error"]?.stringValue?.contains("invalid or unsafe") == true)
    }

    // MARK: - SafetyGate Integration Tests

    private struct MockRiskyTool: IvyTool {
        let name = "risky_tool"
        let description = "A test tool classified as risky"
        let declaration = FunctionDeclaration(name: "risky_tool", description: "Risky")
        var safetyClassification: ToolSafetyClassification { .risky }

        func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
            .success("Executed risky tool")
        }
    }

    @Test("ToolDispatcher rejects risky tool under default PassThroughSafetyGate")
    func testRiskyToolRejectedByDefaultSafetyGate() async {
        let riskyTool = MockRiskyTool()
        let registry = ToolRegistry(tools: [riskyTool])
        let dispatcher = ToolDispatcher(registry: registry)

        let call = FunctionCall(name: "risky_tool", args: [:], id: "risky-1")
        let response = await dispatcher.dispatch(call)

        #expect(response.name == "risky_tool")
        #expect(response.id == "risky-1")
        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["error"]?.stringValue?.contains("Execution rejected by safety policy") == true)
        #expect(response.response["error"]?.stringValue?.contains("requires user confirmation") == true)
    }

    @Test("ToolDispatcher respects custom SafetyGate approval and rejection")
    func testCustomSafetyGate() async {
        final class BlockingSafetyGate: SafetyGateProtocol, Sendable {
            func evaluate(tool: IvyTool, call: FunctionCall) async -> SafetyDecision {
                .reject(reason: "Policy violation: all tools disabled")
            }
        }

        let echo = MockEchoTool()
        let registry = ToolRegistry(tools: [echo])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: BlockingSafetyGate())

        let call = FunctionCall(name: "echo_test", args: ["msg": "Hello"], id: "blocked-1")
        let response = await dispatcher.dispatch(call)

        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["error"]?.stringValue?.contains("Policy violation: all tools disabled") == true)
    }

    @Test("ToolRegistry inspection methods: hasTool, count, and isEmpty")
    func testRegistryInspection() {
        let empty = ToolRegistry(tools: [])
        #expect(empty.isEmpty == true)
        #expect(empty.count == 0)
        #expect(empty.hasTool(named: "open_app") == false)

        let echo = MockEchoTool()
        let registry = ToolRegistry(tools: [echo])
        #expect(registry.isEmpty == false)
        #expect(registry.count == 1)
        #expect(registry.hasTool(named: "echo_test") == true)
        #expect(registry.hasTool(named: "non_existent") == false)
    }
}

