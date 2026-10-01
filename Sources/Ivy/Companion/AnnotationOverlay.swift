import AppKit
import SwiftUI
import IvyCore

/// Draws `point_at` highlights: a click-through panel over the target area, gone after a few seconds or on the
/// next highlight. Display only — it never takes mouse or keyboard input.
struct AnnotationOverlay: AnnotationPresenting {
    func show(_ rect: CGRect, label: String) async {
        await MainActor.run { AnnotationOverlayController.shared.show(rect, label: label) }
    }
}

@MainActor
final class AnnotationOverlayController {
    static let shared = AnnotationOverlayController()
    static let duration: Duration = .seconds(6)
    private static let labelHeight: CGFloat = 30
    private static let padding: CGFloat = 8

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ rect: CGRect, label: String) {
        hideTask?.cancel()
        panel?.orderOut(nil)

        // Room around the highlight for the stroke, and above it for the label.
        let frame = CGRect(x: rect.minX - Self.padding, y: rect.minY - Self.padding,
                           width: max(rect.width, 160) + Self.padding * 2, height: rect.height + Self.padding * 2 + Self.labelHeight)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: AnnotationView(
            label: label, highlight: CGSize(width: rect.width, height: rect.height), padding: Self.padding, labelHeight: Self.labelHeight))
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .announcementRequested,
                             userInfo: [.announcement: "Ivy is pointing at \(label)", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        self.panel = panel

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.panel?.orderOut(nil)
            self?.panel = nil
        }
    }
}

private struct AnnotationView: View {
    let label: String
    let highlight: CGSize
    let padding: CGFloat
    let labelHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(IvyTheme.moss))
                .frame(height: labelHeight, alignment: .bottomLeading)
                .padding(.leading, padding)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(IvyTheme.leaf, lineWidth: 3)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(IvyTheme.leaf.opacity(0.12)))
                .frame(width: highlight.width, height: highlight.height)
                .scaleEffect(pulse ? 1.03 : 1)
                .padding(padding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatCount(3, autoreverses: true)) { pulse = true }
        }
    }
}
