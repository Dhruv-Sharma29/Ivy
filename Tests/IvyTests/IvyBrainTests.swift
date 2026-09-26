import Testing
import Foundation
@testable import IvyCore

final class MockGeminiClient: GeminiClientProtocol, @unchecked Sendable {
    var stubbedResponse: String = "Sarcastic Ivy reply"
    var errorToThrow: Error? = nil
    var recordedHistory: [ChatMessage] = []

    func generateContent(
        history: [ChatMessage],
        systemPrompt: String,
        apiKey: String
    ) async throws -> String {
        recordedHistory = history
        if let error = errorToThrow {
            throw error
        }
        return stubbedResponse
    }
}

@Suite("IvyBrain Turn and State Tests")
struct IvyBrainTests {

    @Test("Successful turn appends user and model messages")
    @MainActor
    func testSuccessfulTurn() async {
        let mock = MockGeminiClient()
        mock.stubbedResponse = "Fine, here is your answer."
        let brain = IvyBrain(client: mock, apiKey: "valid_key")

        #expect(brain.messages.isEmpty)
        #expect(brain.isThinking == false)

        await brain.send("Organize my desktop")

        #expect(brain.messages.count == 2)
        #expect(brain.messages[0].role == .user)
        #expect(brain.messages[0].text == "Organize my desktop")
        #expect(brain.messages[1].role == .model)
        #expect(brain.messages[1].text == "Fine, here is your answer.")
        #expect(brain.messages[1].isError == false)
        #expect(brain.isThinking == false)
        #expect(brain.errorMessage == nil)
    }

    @Test("Empty or whitespace message is ignored")
    @MainActor
    func testEmptyMessageIgnored() async {
        let mock = MockGeminiClient()
        let brain = IvyBrain(client: mock, apiKey: "valid_key")

        await brain.send("   ")
        #expect(brain.messages.isEmpty)
    }

    @Test("Missing API key halts turn and produces error message")
    @MainActor
    func testMissingAPIKeyHandling() async {
        let mock = MockGeminiClient()
        let brain = IvyBrain(client: mock, apiKey: "")

        await brain.send("Help me")

        #expect(brain.messages.count == 2)
        #expect(brain.messages[0].role == .user)
        #expect(brain.messages[1].role == .model)
        #expect(brain.messages[1].isError == true)
        #expect(brain.messages[1].text.contains("need a Gemini API key"))
        #expect(brain.errorMessage != nil)
        #expect(mock.recordedHistory.isEmpty)
    }

    @Test("Network failure sets error state and preserves history")
    @MainActor
    func testNetworkFailureHandling() async {
        let mock = MockGeminiClient()
        mock.errorToThrow = GeminiClientError.rateLimited
        let brain = IvyBrain(client: mock, apiKey: "valid_key")

        await brain.send("Calculate 2+2")

        #expect(brain.messages.count == 2)
        #expect(brain.messages[1].isError == true)
        #expect(brain.messages[1].text.contains("Rate limited"))
        #expect(brain.isThinking == false)
        #expect(brain.errorMessage != nil)
    }

    @Test("Clear history resets all state")
    @MainActor
    func testClearHistory() async {
        let mock = MockGeminiClient()
        let brain = IvyBrain(client: mock, apiKey: "valid_key")

        await brain.send("First message")
        #expect(brain.messages.count == 2)

        brain.clearHistory()
        #expect(brain.messages.isEmpty)
        #expect(brain.isThinking == false)
        #expect(brain.errorMessage == nil)
    }

    @Test("Status icon updates based on state")
    @MainActor
    func testStatusIconTransitions() async {
        let mock = MockGeminiClient()
        let brain = IvyBrain(client: mock, apiKey: "valid_key")
        #expect(brain.statusIcon == "sparkle")

        mock.errorToThrow = URLError(.timedOut)
        await brain.send("Will fail")
        #expect(brain.statusIcon == "exclamationmark.bubble")
    }

    // MARK: - Phase 2A Function Calling & Tool Integration Tests

    @Test("IvyBrain executes functionCall, submits functionResponse, and delivers final model reply")
    @MainActor
    func testFunctionCallingExecutionLoop() async {
        final class ScriptedGeminiClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            var receivedHistories: [[ChatMessage]] = []

            func generateContent(
                history: [ChatMessage],
                systemPrompt: String,
                apiKey: String
            ) async throws -> String {
                return "fallback"
            }

            func generateContent(
                history: [ChatMessage],
                systemPrompt: String,
                tools: [ToolDeclarationWrapper]?,
                apiKey: String
            ) async throws -> ModelTurnResponse {
                receivedHistories.append(history)
                step += 1
                if step == 1 {
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [FunctionCall(name: "open_app", args: ["name": "Safari"], id: "call-safari")]
                    )
                } else {
                    return ModelTurnResponse(
                        text: "Safari is open. What now?",
                        functionCalls: []
                    )
                }
            }
        }

        let scriptedClient = ScriptedGeminiClient()
        let mockWorkspace = MockWorkspace()
        mockWorkspace.knownApps["safari.app"] = URL(fileURLWithPath: "/Applications/Safari.app")
        let toolRegistry = ToolRegistry(tools: [OpenAppTool(workspace: mockWorkspace)])
        let dispatcher = ToolDispatcher(registry: toolRegistry)

        let brain = IvyBrain(
            client: scriptedClient,
            toolDispatcher: dispatcher,
            apiKey: "valid_key"
        )

        await brain.send("Open Safari please")

        #expect(scriptedClient.step == 2)
        #expect(mockWorkspace.openedURLs.count == 1)
        #expect(mockWorkspace.openedURLs.first?.path == "/Applications/Safari.app")

        // Check history in second turn contained the function response
        let secondTurnHistory = scriptedClient.receivedHistories[1]
        let hasFunctionResponse = secondTurnHistory.contains { $0.functionResponse?.name == "open_app" }
        #expect(hasFunctionResponse == true)

        // Check final user message and model response in brain.messages
        #expect(brain.messages.count == 2)
        #expect(brain.messages[0].role == .user)
        #expect(brain.messages[0].text == "Open Safari please")
        #expect(brain.messages[1].role == .model)
        #expect(brain.messages[1].text == "Safari is open. What now?")
        #expect(brain.isThinking == false)
        #expect(brain.errorMessage == nil)
    }

    @Test("IvyBrain passes tool errors to model and receives explanation")
    @MainActor
    func testFunctionCallingErrorPassedToModel() async {
        final class ErrorScriptedGeminiClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            var lastFunctionResponse: FunctionResponse?

            func generateContent(
                history: [ChatMessage],
                systemPrompt: String,
                apiKey: String
            ) async throws -> String {
                return "fallback"
            }

            func generateContent(
                history: [ChatMessage],
                systemPrompt: String,
                tools: [ToolDeclarationWrapper]?,
                apiKey: String
            ) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [FunctionCall(name: "open_app", args: ["name": "NonExistentApp"], id: "call-fail")]
                    )
                } else {
                    lastFunctionResponse = history.compactMap(\.functionResponse).first
                    return ModelTurnResponse(
                        text: "I looked everywhere, but that app doesn't exist.",
                        functionCalls: []
                    )
                }
            }
        }

        let scriptedClient = ErrorScriptedGeminiClient()
        let mockWorkspace = MockWorkspace() // Empty workspace, will fail lookup
        let toolRegistry = ToolRegistry(tools: [OpenAppTool(workspace: mockWorkspace)])
        let dispatcher = ToolDispatcher(registry: toolRegistry)

        let brain = IvyBrain(
            client: scriptedClient,
            toolDispatcher: dispatcher,
            apiKey: "valid_key"
        )

        await brain.send("Open NonExistentApp")

        #expect(scriptedClient.step == 2)
        #expect(scriptedClient.lastFunctionResponse?.response["error"]?.stringValue?.contains("not found") == true)
        #expect(brain.messages.count == 2)
        #expect(brain.messages[1].text == "I looked everywhere, but that app doesn't exist.")
        #expect(brain.errorMessage == nil)
    }

    @Test("IvyBrain halts when tool execution limit is reached")
    @MainActor
    func testToolExecutionLimitEnforced() async {
        final class InfiniteToolGeminiClient: GeminiClientProtocol, @unchecked Sendable {
            var calls = 0

            func generateContent(
                history: [ChatMessage],
                systemPrompt: String,
                apiKey: String
            ) async throws -> String {
                return "fallback"
            }

            func generateContent(
                history: [ChatMessage],
                systemPrompt: String,
                tools: [ToolDeclarationWrapper]?,
                apiKey: String
            ) async throws -> ModelTurnResponse {
                calls += 1
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "open_app", args: ["name": "Safari"], id: "infinite-\(calls)")]
                )
            }
        }

        let client = InfiniteToolGeminiClient()
        let mockWorkspace = MockWorkspace()
        mockWorkspace.knownApps["safari.app"] = URL(fileURLWithPath: "/Applications/Safari.app")
        let toolRegistry = ToolRegistry(tools: [OpenAppTool(workspace: mockWorkspace)])
        let dispatcher = ToolDispatcher(registry: toolRegistry)

        let brain = IvyBrain(
            client: client,
            toolDispatcher: dispatcher,
            apiKey: "valid_key"
        )

        await brain.send("Infinite loop")

        #expect(client.calls == 5)
        #expect(brain.errorMessage == "Tool execution limit reached.")
        #expect(brain.messages.last?.isError == true)
        #expect(brain.isThinking == false)
    }

    @Test("Phase 1 regression: consecutive pure-text conversation turns without tools")
    @MainActor
    func testPureTextMultiTurnRegression() async {
        final class TwoTurnClient: GeminiClientProtocol, @unchecked Sendable {
            var turn = 0
            func generateContent(
                history: [ChatMessage],
                systemPrompt: String,
                apiKey: String
            ) async throws -> String {
                turn += 1
                return "Turn \(turn) answer"
            }
        }

        let client = TwoTurnClient()
        let brain = IvyBrain(client: client, apiKey: "valid_key")

        await brain.send("Message 1")
        #expect(brain.messages.count == 2)
        #expect(brain.messages[1].text == "Turn 1 answer")

        await brain.send("Message 2")
        #expect(brain.messages.count == 4)
        #expect(brain.messages[3].text == "Turn 2 answer")
        #expect(brain.isThinking == false)
        #expect(brain.errorMessage == nil)
    }

    @Test("Multi-turn conversation: tool execution turn followed by pure text follow-up")
    @MainActor
    func testMultiTurnFollowUpAfterToolCall() async {
        final class MixedGeminiClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            var turn2History: [ChatMessage] = []

            func generateContent(
                history: [ChatMessage],
                systemPrompt: String,
                apiKey: String
            ) async throws -> String {
                return "fallback"
            }

            func generateContent(
                history: [ChatMessage],
                systemPrompt: String,
                tools: [ToolDeclarationWrapper]?,
                apiKey: String
            ) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    // Turn 1a: model requests tool
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [FunctionCall(name: "open_app", args: ["name": "Notes"])]
                    )
                } else if step == 2 {
                    // Turn 1b: model concludes after tool execution
                    return ModelTurnResponse(text: "Notes is opened. Get typing.")
                } else {
                    // Turn 2: regular follow-up text turn
                    turn2History = history
                    return ModelTurnResponse(text: "No, I will not type for you.")
                }
            }
        }

        let client = MixedGeminiClient()
        let mockWS = MockWorkspace()
        mockWS.knownApps["notes.app"] = URL(fileURLWithPath: "/System/Applications/Notes.app")
        let toolRegistry = ToolRegistry(tools: [OpenAppTool(workspace: mockWS)])
        let dispatcher = ToolDispatcher(registry: toolRegistry)

        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")

        // First prompt invokes tool
        await brain.send("Open Notes")
        #expect(brain.messages.count == 2)
        #expect(brain.messages[1].text == "Notes is opened. Get typing.")
        #expect(mockWS.openedURLs.count == 1)

        // Second prompt is a follow-up conversation
        await brain.send("Can you type my essay?")
        #expect(brain.messages.count == 4)
        #expect(brain.messages[3].text == "No, I will not type for you.")
        #expect(client.turn2History.count >= 3)
    }

    @Test("IvyBrain handles unexpected generic error during send")
    @MainActor
    func testGenericErrorHandling() async {
        final class ThrowingClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(
                history: [ChatMessage],
                systemPrompt: String,
                apiKey: String
            ) async throws -> String {
                throw NSError(domain: "POSIX", code: 54, userInfo: [NSLocalizedDescriptionKey: "Connection reset by peer"])
            }
        }

        let brain = IvyBrain(client: ThrowingClient(), apiKey: "valid_key")
        await brain.send("Will crash")

        #expect(brain.messages.count == 2)
        #expect(brain.messages[1].isError == true)
        #expect(brain.messages[1].text.contains("Something broke: Connection reset by peer"))
        #expect(brain.errorMessage == "Connection reset by peer")
    }
}
