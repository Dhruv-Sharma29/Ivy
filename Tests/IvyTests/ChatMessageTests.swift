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

        for role in [MessageRole.user, MessageRole.model, MessageRole.system] {
            let data = try JSONEncoder().encode(role)
            let decoded = try JSONDecoder().decode(MessageRole.self, from: data)
            #expect(decoded == role)
        }
    }
}
