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
}
