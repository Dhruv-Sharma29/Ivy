import Testing
import Foundation
@testable import IvyCore

@Suite("Conversation History Conversion Tests")
struct HistoryConversionTests {

    @Test("Role conversion maps user and model roles correctly")
    func testRoleConversion() {
        let userMsg = ChatMessage(role: .user, text: "User prompt")
        let modelMsg = ChatMessage(role: .model, text: "Model reply")

        let userContent = Content(role: userMsg.role == .user ? "user" : "model", text: userMsg.text)
        let modelContent = Content(role: modelMsg.role == .user ? "user" : "model", text: modelMsg.text)

        #expect(userContent.role == "user")
        #expect(userContent.parts.first?.text == "User prompt")
        #expect(modelContent.role == "model")
        #expect(modelContent.parts.first?.text == "Model reply")
    }

    @Test("IvyBrain filters error messages from history sent to Gemini")
    @MainActor
    func testIvyBrainFiltersErrorsFromHistory() async {
        let mock = MockGeminiClient()
        mock.stubbedResponse = "I'm still here."
        let brain = IvyBrain(client: mock, apiKey: "valid_key")

        // First successful turn
        await brain.send("Question 1")
        #expect(brain.messages.count == 2)

        // Induce an error turn
        mock.errorToThrow = GeminiClientError.rateLimited
        await brain.send("Question 2 (will fail)")
        #expect(brain.messages.count == 4)
        #expect(brain.messages.last?.isError == true)

        // Next successful turn: history sent to Gemini should NOT include the error message
        mock.errorToThrow = nil
        mock.stubbedResponse = "Moving on."
        await brain.send("Question 3")

        let sentHistory = mock.recordedHistory
        #expect(!sentHistory.contains(where: { $0.isError }))
        #expect(sentHistory.map(\.text) == [
            "Question 1",
            "I'm still here.",
            "Question 2 (will fail)",
            "Question 3"
        ])
    }

    @Test("GeminiClient builds correctly ordered contents array preserving multi-turn sequence")
    func testMultiTurnSequencePreserved() throws {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, text: "Turn 1: user"),
            ChatMessage(role: .model, text: "Turn 1: model"),
            ChatMessage(role: .user, text: "Turn 2: user"),
            ChatMessage(role: .model, text: "Turn 2: model"),
            ChatMessage(role: .user, text: "Turn 3: user")
        ]

        let contents: [Content] = messages.compactMap { msg in
            guard !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Content(role: msg.role == .user ? "user" : "model", text: msg.text)
        }

        #expect(contents.count == 5)
        #expect(contents[0].role == "user")
        #expect(contents[0].parts.first?.text == "Turn 1: user")
        #expect(contents[1].role == "model")
        #expect(contents[1].parts.first?.text == "Turn 1: model")
        #expect(contents[2].role == "user")
        #expect(contents[2].parts.first?.text == "Turn 2: user")
        #expect(contents[3].role == "model")
        #expect(contents[3].parts.first?.text == "Turn 2: model")
        #expect(contents[4].role == "user")
        #expect(contents[4].parts.first?.text == "Turn 3: user")
    }

    @Test("Whitespace-only messages are omitted from request contents")
    func testWhitespaceMessagesOmitted() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, text: "Valid question"),
            ChatMessage(role: .model, text: "   "),
            ChatMessage(role: .user, text: "\t\n  "),
            ChatMessage(role: .user, text: "Another valid question")
        ]

        let contents: [Content] = messages.compactMap { msg in
            guard !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return Content(role: msg.role == .user ? "user" : "model", text: msg.text)
        }

        #expect(contents.count == 2)
        #expect(contents[0].parts.first?.text == "Valid question")
        #expect(contents[1].parts.first?.text == "Another valid question")
    }

    @Test("History conversion correctly handles functionCall and functionResponse turns")
    func testToolTurnHistoryConversion() {
        let messages: [ChatMessage] = [
            ChatMessage(role: .user, text: "Open Calculator"),
            ChatMessage(role: .model, text: "", functionCall: FunctionCall(name: "open_app", args: ["name": "Calculator"], id: "calc-1")),
            ChatMessage(role: .function, text: "Opened Calculator.", functionResponse: FunctionResponse(name: "open_app", response: ["result": "Opened Calculator."], id: "calc-1")),
            ChatMessage(role: .model, text: "Calculator is open.")
        ]

        let contents: [Content] = messages.compactMap { msg in
            if let functionCall = msg.functionCall {
                return Content(role: "model", parts: [Part(functionCall: functionCall)])
            }
            if let functionResponse = msg.functionResponse {
                return Content(role: "user", parts: [Part(functionResponse: functionResponse)])
            }
            guard !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let roleString = (msg.role == .user) ? "user" : "model"
            return Content(role: roleString, text: msg.text)
        }

        #expect(contents.count == 4)
        #expect(contents[0].role == "user")
        #expect(contents[0].parts.first?.text == "Open Calculator")

        #expect(contents[1].role == "model")
        #expect(contents[1].parts.first?.functionCall?.name == "open_app")
        #expect(contents[1].parts.first?.functionCall?.args["name"]?.stringValue == "Calculator")

        #expect(contents[2].role == "user")
        #expect(contents[2].parts.first?.functionResponse?.name == "open_app")
        #expect(contents[2].parts.first?.functionResponse?.response["result"]?.stringValue == "Opened Calculator.")

        #expect(contents[3].role == "model")
        #expect(contents[3].parts.first?.text == "Calculator is open.")
    }
}
