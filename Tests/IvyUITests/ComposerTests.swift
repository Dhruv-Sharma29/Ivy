import SwiftUI
import AppKit
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

    @Test("Shift Return inserts a newline at the selection, supports undo, and never sends")
    func returnKey() throws {
        _ = NSApplication.shared
        var sends = 0
        var draft = "Hello world"
        let editor = ComposerTextEditor(text: Binding(get: { draft }, set: { draft = $0 }), onSend: { sends += 1 })
        let delegate = editor.makeCoordinator()
        let native = ComposerTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 80))
        native.delegate = delegate
        native.allowsUndo = true
        native.string = draft
        native.onSend = { sends += 1 }
        let window = NSWindow(contentRect: native.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = native
        defer { window.close() }
        window.makeFirstResponder(native)
        native.setSelectedRange(NSRange(location: 5, length: 1))
        let shiftReturn = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .shift,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        native.keyDown(with: shiftReturn)
        #expect(native.string == "Hello\nworld")
        #expect(draft == native.string)
        #expect(native.selectedRange() == NSRange(location: 6, length: 0))
        #expect(sends == 0)
        native.undoManager?.undo()
        #expect(native.string == "Hello world")
        native.handleReturn(shiftPressed: false)
        #expect(sends == 1)
        let blocked = MessageInputBar(text: .constant("Hello"), isThinking: true) { sends += 1 }
        native.onSend = blocked.submit
        native.handleReturn(shiftPressed: false)
        #expect(sends == 1)
        native.insertText("\nPasted paragraph", replacementRange: NSRange(location: native.string.utf16.count, length: 0))
        #expect(native.string.hasSuffix("\nPasted paragraph"))
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
