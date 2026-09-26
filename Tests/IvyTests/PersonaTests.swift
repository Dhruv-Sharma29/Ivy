import Testing
import Foundation
@testable import IvyCore

@Suite("Persona and Domain Model Tests")
struct PersonaTests {
    @Test("Persona system prompt contains Ivy identity and tone instructions")
    func testPersonaPrompt() {
        #expect(IvyPersona.systemPrompt.contains("You are Ivy"))
        #expect(IvyPersona.systemPrompt.contains("sharp, sarcastic macOS assistant"))
        #expect(IvyPersona.systemPrompt.contains("never skip the confirmation itself"))
    }

    @Test("ChatMessage initialization and properties")
    func testChatMessageInit() {
        let msg = ChatMessage(role: .user, text: "Hey Ivy")
        #expect(msg.role == .user)
        #expect(msg.text == "Hey Ivy")
        #expect(msg.isError == false)
    }
}
