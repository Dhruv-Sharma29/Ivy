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

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ rect: CGRect, label: String) {
        hideTask?.cancel()
        panel?.orderOut(nil)

        let center = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) })
                ?? NSScreen.screens.first(where: { $0.frame.intersects(rect) }),
              let geometry = AnnotationGeometry(screen: screen.frame, target: rect) else { return }
        let frame = screen.frame
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: AnnotationView(label: label, geometry: geometry))
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

struct AnnotationView: View {
    let label: String
    let geometry: AnnotationGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            AnnotationArrow(geometry: geometry)
                .stroke(IvyTheme.leaf, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .shadow(color: .black.opacity(0.35), radius: 2)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(IvyTheme.leaf, lineWidth: 3)
                .background(RoundedRectangle(cornerRadius: 8).fill(IvyTheme.leaf.opacity(0.12)))
                .frame(width: geometry.highlight.width, height: geometry.highlight.height)
                .scaleEffect(pulse ? 1.03 : 1)
                .position(x: geometry.highlight.midX, y: geometry.highlight.midY)
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(IvyTheme.moss))
                .frame(width: geometry.labelWidth, height: 28, alignment: .leading)
                .offset(x: geometry.labelOrigin.x, y: geometry.labelOrigin.y)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatCount(3, autoreverses: true)) { pulse = true }
        }
    }
}

struct AnnotationArrow: Shape {
    let geometry: AnnotationGeometry
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: geometry.start)
            path.addLine(to: geometry.end)
            path.move(to: geometry.headA)
            path.addLine(to: geometry.end)
            path.addLine(to: geometry.headB)
        }
    }
}
