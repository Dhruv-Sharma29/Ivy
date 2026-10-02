import SwiftUI
import Testing
@testable import Ivy

@MainActor
@Suite("Composer interaction regressions")
struct ComposerTests {
    @Test("text or attachments enable send, but an empty draft or a blocked turn never does")
    func availability() {
        for text in ["", " \n ", "Hello"] {
            for attachments in [false, true] {
                for blocked in [false, true] {
                    var sends = 0
                    let composer = MessageInputBar(text: .constant(text), isThinking: blocked,
                                                   hasAttachments: attachments) { sends += 1 }
                    let expected = !blocked && (text == "Hello" || attachments)
                    #expect(composer.canSend == expected)
                    composer.submit()
                    #expect(sends == (expected ? 1 : 0))
                }
            }
        }
    }

    @Test("Shift Return is left to the editor; plain Return sends exactly once")
    func returnKey() {
        var sends = 0
        let composer = MessageInputBar(text: .constant("Hello"), isThinking: false) { sends += 1 }
        #expect(composer.handleReturn(shiftPressed: true) == .ignored)
        #expect(sends == 0)
        #expect(composer.handleReturn(shiftPressed: false) == .handled)
        #expect(sends == 1)
        let blocked = MessageInputBar(text: .constant("Hello"), isThinking: true) { sends += 1 }
        #expect(blocked.handleReturn(shiftPressed: false) == .handled)
        #expect(sends == 1)
    }

    @Test("a live session can always be stopped, including during a pending tool approval")
    func voiceStop() {
        for active in [false, true] {
            for blocked in [false, true] {
                let composer = MessageInputBar(text: .constant(""), isThinking: blocked,
                                               isVoiceActive: active, onToggleVoice: {}) {}
                #expect(composer.canToggleVoice == (active || !blocked))
            }
        }
    }
}
