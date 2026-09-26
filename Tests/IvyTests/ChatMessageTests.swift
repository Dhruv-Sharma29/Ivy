import Testing
import Foundation
@testable import IvyCore

@Suite("ChatMessage Tests")
struct ChatMessageTests {

    @Test("ChatMessage defaults are set correctly")
    func testDefaults() {
        let before = Date().addingTimeInterval(-1)
        let msg = ChatMessage(role: .user, text: "Testing Ivy")
        let after = Date().addingTimeInterval(1)

        #expect(msg.role == .user)
        #expect(msg.text == "Testing Ivy")
        #expect(msg.isError == false)
        #expect(msg.timestamp >= before && msg.timestamp <= after)
    }

    @Test("ChatMessage JSON round-trip serialization preserves all fields")
    func testJSONRoundTrip() throws {
        let original = ChatMessage(
            id: UUID(),
            role: .model,
            text: "Here is your sarcastic answer: 💅",
            timestamp: Date(timeIntervalSince1970: 1700000000),
            isError: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(ChatMessage.self, from: data)

        #expect(decoded.id == original.id)
        #expect(decoded.role == original.role)
        #expect(decoded.text == original.text)
        #expect(decoded.isError == original.isError)
        #expect(abs(decoded.timestamp.timeIntervalSince1970 - original.timestamp.timeIntervalSince1970) < 1.0)
    }

    @Test("ChatMessage equality semantics")
    func testEquality() {
        let id = UUID()
        let now = Date()
        let msg1 = ChatMessage(id: id, role: .user, text: "Hey", timestamp: now, isError: false)
        let msg2 = ChatMessage(id: id, role: .user, text: "Hey", timestamp: now, isError: false)
        let msg3 = ChatMessage(id: UUID(), role: .user, text: "Hey", timestamp: now, isError: false)
        let msg4 = ChatMessage(id: id, role: .model, text: "Hey", timestamp: now, isError: false)
        let msg5 = ChatMessage(id: id, role: .user, text: "Different", timestamp: now, isError: false)
        let msg6 = ChatMessage(id: id, role: .user, text: "Hey", timestamp: now, isError: true)

        #expect(msg1 == msg2)
        #expect(msg1 != msg3)
        #expect(msg1 != msg4)
        #expect(msg1 != msg5)
        #expect(msg1 != msg6)
    }

    @Test("ChatMessage supports complex Unicode, code snippets, and newlines")
    func testUnicodeAndMultilineText() throws {
        let complexText = """
        ```swift
        let sarcasmLevel = "maximum"
        print("Done: 🚀 ✨")
        ```
        Line 2 with \t tabs & special "quotes"
        """
        let msg = ChatMessage(role: .model, text: complexText)
        #expect(msg.text == complexText)

        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)
        #expect(decoded.text == complexText)
    }

    @Test("MessageRole encodes and decodes all expected raw values")
    func testMessageRoleRawValues() throws {
        #expect(MessageRole.user.rawValue == "user")
        #expect(MessageRole.model.rawValue == "model")
        #expect(MessageRole.system.rawValue == "system")
        #expect(MessageRole.function.rawValue == "function")

        for role in [MessageRole.user, MessageRole.model, MessageRole.system, MessageRole.function] {
            let data = try JSONEncoder().encode(role)
            let decoded = try JSONDecoder().decode(MessageRole.self, from: data)
            #expect(decoded == role)
        }
    }

    @Test("ChatMessage preserves functionCall and functionResponse across JSON round-trip")
    func testChatMessageWithToolProperties() throws {
        let call = FunctionCall(name: "open_app", args: ["name": "Notes"], id: "call-99")
        let callMsg = ChatMessage(role: .model, text: "", functionCall: call)

        let encoder = JSONEncoder()
        let callData = try encoder.encode(callMsg)
        let decodedCallMsg = try JSONDecoder().decode(ChatMessage.self, from: callData)

        #expect(decodedCallMsg.functionCall?.name == "open_app")
        #expect(decodedCallMsg.functionCall?.args["name"]?.stringValue == "Notes")
        #expect(decodedCallMsg.functionCall?.id == "call-99")

        let resp = FunctionResponse(name: "open_app", response: ["result": "Done"], id: "call-99")
        let respMsg = ChatMessage(role: .function, text: "Done", functionResponse: resp)

        let respData = try encoder.encode(respMsg)
        let decodedRespMsg = try JSONDecoder().decode(ChatMessage.self, from: respData)

        #expect(decodedRespMsg.functionResponse?.name == "open_app")
        #expect(decodedRespMsg.functionResponse?.response["result"]?.stringValue == "Done")
        #expect(decodedRespMsg.functionResponse?.id == "call-99")
    }

    @Test("ChatMessage preserves functionCallPart and thought_signature across JSON round-trip")
    func testChatMessageWithFunctionCallPartAndThoughtSignature() throws {
        let call = FunctionCall(name: "open_app", args: ["name": "Safari"], id: "call-101", thoughtSignature: "sig-chat-msg-001")
        let part = Part(functionCall: call, thoughtSignature: "sig-chat-msg-001")
        let message = ChatMessage(role: .model, text: "", functionCall: call, functionCallPart: part)

        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(ChatMessage.self, from: data)

        #expect(decoded.functionCall?.name == "open_app")
        #expect(decoded.functionCall?.thoughtSignature == "sig-chat-msg-001")
        #expect(decoded.functionCallPart?.thoughtSignature == "sig-chat-msg-001")
        #expect(decoded.functionCallPart?.functionCall?.name == "open_app")
    }

    @Test("ChatMessage initialized with legacy functionCall automatically sets functionCallPart with thoughtSignature")
    func testChatMessageLegacyInitCarriesThoughtSignature() throws {
        let call = FunctionCall(name: "run_applescript", args: ["script": "beep"], thoughtSignature: "sig-legacy-002")
        let message = ChatMessage(role: .model, text: "", functionCall: call)

        #expect(message.functionCall?.thoughtSignature == "sig-legacy-002")
        #expect(message.functionCallPart?.thoughtSignature == "sig-legacy-002")
        #expect(message.functionCallPart?.functionCall?.name == "run_applescript")
    }
}
