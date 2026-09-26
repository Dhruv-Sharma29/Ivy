import Testing
import Foundation
@testable import IvyCore

private struct MockEchoTool: IvyTool, Sendable {
    let name: String = "echo_test"
    let description: String = "Echoes the message"
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
}
