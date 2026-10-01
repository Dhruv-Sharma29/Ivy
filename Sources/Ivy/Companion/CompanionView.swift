import SwiftUI
import IvyCore

/// The companion: Ivy's leaf with a face that changes with what it's doing, a ring that follows the voice or a
/// task's progress, and a caption bubble while it speaks. Reduce Motion → static face and ring.
/// What the companion panel shows; updated in place so the view (and its animations) isn't rebuilt.
@MainActor
final class CompanionPresentation: ObservableObject {
    @Published var mood: CompanionMood = .hidden
    @Published var caption = ""
}

struct CompanionView: View {
    @ObservedObject var presentation: CompanionPresentation
    @ObservedObject var meter: AudioLevelMeter
    let onOpen: () -> Void
    let onEndVoice: () -> Void
    let onStopTask: () -> Void
    let onHide: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false
    @State private var spin = false

    static let orbSize: CGFloat = 56

    private var mood: CompanionMood { presentation.mood }
    private var caption: String { presentation.caption }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !caption.isEmpty, mood == .speaking {
                Text(caption)
                    .font(.system(size: 12, design: .rounded))
                    .lineLimit(3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
                    .frame(maxWidth: 260, alignment: .trailing)
                    .transition(.opacity)
            }
            if case .error(let message) = mood {
                Text(message)
                    .font(.system(size: 11, design: .rounded))
                    .lineLimit(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.regularMaterial))
                    .frame(maxWidth: 260, alignment: .trailing)
            }
            orb
        }
        .padding(6)
        .frame(width: 280, height: 150, alignment: .bottomTrailing)
    }

    private var orb: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            ring
            LeafFace(mood: mood)
                .frame(width: Self.orbSize * 0.62, height: Self.orbSize * 0.62)
        }
        .frame(width: Self.orbSize, height: Self.orbSize)
        .scaleEffect(reduceMotion ? 1 : 1 + CGFloat(level) * 0.12)
        .animation(reduceMotion ? nil : .linear(duration: 0.08), value: level)
        .contentShape(Circle())
        .onTapGesture(perform: onOpen)
        .contextMenu {
            Button("Open Ivy", action: onOpen)
            Button("End Voice Session", action: onEndVoice)
            Button("Stop Task", action: onStopTask)
            Divider()
            Button("Hide for Now", action: onHide)
        }
        .help(mood.accessibilityDescription)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mood.accessibilityDescription)
        .accessibilityHint("Click to open Ivy")
        .accessibilityAddTraits(.isButton)
        .onAppear(perform: startAnimations)
        .onChange(of: mood) { startAnimations() }
    }

    private var level: Float {
        switch mood {
        case .listening: return meter.inputLevel
        case .speaking: return meter.outputLevel
        default: return 0
        }
    }

    @ViewBuilder
    private var ring: some View {
        switch mood {
        case .working(let progress):
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 4)
            Circle().trim(from: 0, to: max(0.03, progress))
                .stroke(IvyTheme.leaf, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
        case .needsApproval:
            Circle().stroke(IvyTheme.riskAmber, lineWidth: 4)
                .opacity(reduceMotion ? 1 : (pulse ? 1 : 0.35))
        case .error:
            Circle().stroke(IvyTheme.dangerRed, lineWidth: 4)
        case .thinking:
            Circle().trim(from: 0, to: 0.7)
                .stroke(IvyTheme.leaf.opacity(0.7), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(reduceMotion ? 0 : (spin ? 360 : 0)))
        case .listening, .speaking:
            Circle().stroke(IvyTheme.leaf, lineWidth: 3)
        case .idle, .hidden:
            Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 2)
        }
    }

    private func startAnimations() {
        guard !reduceMotion else { return }
        pulse = false
        spin = false
        if mood == .needsApproval {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
        }
        if mood == .thinking {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

/// The leaf from `IvyLogo` with eyes and a mouth that change per mood (vector shapes, not text).
struct LeafFace: View {
    let mood: CompanionMood

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            // IvyLogo draws y-up; SwiftUI is y-down.
            let flip = CGAffineTransform(translationX: 0, y: size.height).scaledBy(x: 1, y: -1)
            let leaf = Path(IvyLogo.leafPath(in: rect)).applying(flip)
            context.fill(leaf, with: .color(IvyTheme.leaf))

            let eyeY = size.height * 0.52
            let eyeDX = size.width * 0.13
            let eyeR = size.width * 0.05
            let ink = GraphicsContext.Shading.color(.white)
            func eye(_ x: CGFloat, closed: Bool) {
                if closed {
                    var p = Path()
                    p.move(to: CGPoint(x: x - eyeR * 1.3, y: eyeY))
                    p.addQuadCurve(to: CGPoint(x: x + eyeR * 1.3, y: eyeY), control: CGPoint(x: x, y: eyeY - eyeR * 1.6))
                    context.stroke(p, with: ink, lineWidth: 1.6)
                } else {
                    context.fill(Path(ellipseIn: CGRect(x: x - eyeR, y: eyeY - eyeR, width: eyeR * 2, height: eyeR * 2)), with: ink)
                }
            }
            let cx = size.width / 2
            switch mood {
            case .speaking:
                eye(cx - eyeDX, closed: true)
                eye(cx + eyeDX, closed: true)
            case .thinking:
                // Side-eye: both pupils pushed to one side.
                eye(cx - eyeDX + eyeR, closed: false)
                eye(cx + eyeDX + eyeR, closed: false)
            case .needsApproval:
                for x in [cx - eyeDX, cx + eyeDX] {
                    context.stroke(Path(ellipseIn: CGRect(x: x - eyeR * 1.4, y: eyeY - eyeR * 1.4, width: eyeR * 2.8, height: eyeR * 2.8)), with: ink, lineWidth: 1.4)
                }
            default:
                eye(cx - eyeDX, closed: false)
                eye(cx + eyeDX, closed: false)
            }

            var mouth = Path()
            let mouthY = size.height * 0.64
            let w = size.width * 0.12
            switch mood {
            case .error:
                mouth.move(to: CGPoint(x: cx - w, y: mouthY + 2))
                mouth.addQuadCurve(to: CGPoint(x: cx + w, y: mouthY + 2), control: CGPoint(x: cx, y: mouthY - 4))
            case .speaking:
                mouth = Path(ellipseIn: CGRect(x: cx - w * 0.6, y: mouthY - 2, width: w * 1.2, height: w))
            case .needsApproval:
                mouth = Path(ellipseIn: CGRect(x: cx - w * 0.35, y: mouthY - 1, width: w * 0.7, height: w * 0.7))
            default:
                mouth.move(to: CGPoint(x: cx - w, y: mouthY))
                mouth.addQuadCurve(to: CGPoint(x: cx + w, y: mouthY), control: CGPoint(x: cx, y: mouthY + 5))
            }
            context.stroke(mouth, with: ink, lineWidth: 1.6)
        }
        .accessibilityHidden(true)
    }
}
