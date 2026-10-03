import AppKit
import SwiftUI

/// Native editing preserves selection, undo, pasted paragraphs and input-method composition.
struct ComposerTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSend: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ComposerScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = ComposerTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 32))
        editor.isRichText = false
        editor.drawsBackground = false
        editor.font = .preferredFont(forTextStyle: .body)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width: 0, height: 6)
        editor.textContainer?.lineFragmentPadding = 0
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = false
        editor.allowsUndo = true
        editor.setAccessibilityLabel("Message Ivy")
        editor.setAccessibilityIdentifier("ivy.composer")
        editor.delegate = context.coordinator
        editor.onSend = onSend
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? ComposerTextView else { return }
        editor.onSend = onSend
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            let start = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
        }
        scroll.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, let editor = nsView.documentView as? NSTextView else { return nil }
        // SwiftUI probes several widths. Measure without changing the live document's geometry.
        let font = editor.font ?? .preferredFont(forTextStyle: .body)
        let rect = (editor.string + "\u{200B}" as NSString).boundingRect(
            with: NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
        return CGSize(width: width, height: min(150, max(32, ceil(rect.height) + 12)))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextEditor
        init(_ parent: ComposerTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            parent.text = editor.string
        }
    }
}

/// Update document geometry only after AppKit knows the actual viewport width.
@MainActor
final class ComposerScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView, let container = editor.textContainer,
              let manager = editor.layoutManager, contentSize.width > 0 else { return }
        container.containerSize = NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let glyphHeight = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
        // Center short drafts in the viewport; long drafts retain equal padding and scroll normally.
        let verticalInset = max(6, (contentSize.height - glyphHeight) / 2)
        let inset = NSSize(width: 0, height: verticalInset)
        if editor.textContainerInset != inset { editor.textContainerInset = inset }
        let textHeight = glyphHeight + 2 * verticalInset
        let size = NSSize(width: contentSize.width, height: max(contentSize.height, max(32, textHeight)))
        if editor.frame.size != size { editor.setFrameSize(size) }
    }
}

@MainActor
final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76) && !hasMarkedText() {
            handleReturn(shiftPressed: event.modifierFlags.contains(.shift))
        } else {
            super.keyDown(with: event)
        }
    }

    func handleReturn(shiftPressed: Bool) {
        if shiftPressed {
            insertNewline(nil)
        } else {
            onSend?()
        }
    }
}
