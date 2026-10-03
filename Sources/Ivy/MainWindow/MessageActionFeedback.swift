import AppKit
import SwiftUI

/// A short click pulse layered over the native button's own press feedback.
struct MessageActionFeedback: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let motionDisabled = reduceMotion
        return content.keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { view, scale in
            view.scaleEffect(motionDisabled ? 1 : scale)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(0.94, duration: 0.08)
                SpringKeyframe(1, duration: 0.24, spring: .smooth)
            }
        }
    }
}

/// Copy feedback is scoped to this button and resets after each click.
struct MessageCopyButton: View {
    let text: String
    var accessibilityTitle = "Copy message"
    @State private var clickCount = 0
    @State private var notice: String?
    @State private var copySucceeded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            copySucceeded = NSPasteboard.general.setString(text, forType: .string)
            notice = copySucceeded ? "Copied" : "Copy failed"
            clickCount += 1
        } label: {
            Label {
                Text(notice ?? "Copy")
            } icon: {
                Image(systemName: notice == nil ? "doc.on.doc" : (copySucceeded ? "checkmark" : "exclamationmark.triangle"))
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
            }
            .frame(minWidth: 64)
        }
        .modifier(MessageActionFeedback(trigger: clickCount))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: notice)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(notice ?? "")
        .help(notice ?? accessibilityTitle)
        .task(id: clickCount) {
            guard clickCount > 0 else { return }
            do {
                try await Task.sleep(for: .seconds(2))
                notice = nil
            } catch is CancellationError {
                // A new click or removal cancels this reset; the newer feedback owns its timer.
                return
            } catch {
                notice = "Copy feedback unavailable"
            }
        }
    }
}
