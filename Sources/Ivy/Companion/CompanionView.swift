import SwiftUI
import IvyCore

/// Updated in place, so real state changes preserve the companion's view and animation lifetime.
@MainActor
final class CompanionPresentation: ObservableObject {
    @Published var mood: CompanionMood = .hidden
    @Published var caption = ""
    @Published var isMoving = false
    @Published var approval: CompanionApproval?
}

/// A small pixel-art character with explicit status. Appearance never changes the approval flow.
struct CompanionView: View {
    @ObservedObject var presentation: CompanionPresentation
    @ObservedObject var meter: AudioLevelMeter
    let onOpen: () -> Void
    let onEndVoice: () -> Void
    let onStopTask: () -> Void
    let onHide: () -> Void
    /// Embedders can request a still preview; the system's Reduce Motion always remains authoritative.
    var motionDisabled = false
    var onDrop: () -> Void = {}
    var onContentLayout: (CGRect) -> Void = { _ in }
    var onConfirm: (CompanionApproval, Bool) -> Void = { _, _ in }

    static let panelSize = CGSize(width: 280, height: 224)
    static func panelSize(hasApproval: Bool) -> CGSize {
        hasApproval ? CGSize(width: 280, height: 240) : panelSize
    }
    private var mood: CompanionMood { presentation.mood }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if !presentation.caption.isEmpty, mood == .speaking {
                bubble(presentation.caption, lines: 3)
            }
            if case .error(let message) = mood { bubble(message, lines: 2) }
            Button(action: onOpen) {
                VStack(spacing: 5) {
                    CompanionSpriteView(mood: mood, meter: meter, motionDisabled: motionDisabled, isMoving: presentation.isMoving)
                    if presentation.approval == nil {
                        VStack(spacing: 4) {
                            Label(status, systemImage: symbol)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(statusColor)
                            if case .working(let progress) = mood {
                                ProgressView(value: max(0, min(1, progress)))
                                    .progressViewStyle(.linear).frame(width: 82)
                                    .tint(IvyTheme.leaf).accessibilityHidden(true)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .ivyGlass(cornerRadius: 100, interactive: true)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(CompanionButtonStyle())
            .contextMenu {
                Button("Open Ivy", action: onOpen)
                Button("End Voice Session", action: onEndVoice)
                Button("Stop Task", action: onStopTask)
                Divider()
                Button("Hide for Now", action: onHide)
            }
            .help("Drag Ivy to move. Click to open. Right-click for actions.")
            .accessibilityLabel(mood.accessibilityDescription)
            .accessibilityHint("Click to open Ivy. Drag to move.")
            .accessibilityIdentifier("ivy.companion")
            // Only the character and status pill drag. Approval controls retain normal pointer routing.
            .overlay {
                CompanionDragHandle(onOpen: onOpen, onEndVoice: onEndVoice, onStopTask: onStopTask, onHide: onHide,
                                    onMoving: { presentation.isMoving = $0 }, onDrop: onDrop)
                    .accessibilityHidden(true)
            }
            if let approval = presentation.approval {
                ConfirmationCardView(request: approval.request, compact: true) { approved in
                    onConfirm(approval, approved)
                }
                .frame(width: 240, height: 96)
                .ivyGlass(cornerRadius: IvyTheme.cardRadius)
                .id(approval.id)
                .accessibilityIdentifier("ivy.companion.approval")
            }
        }
        // Track the visible stack before padding and the fixed transparent panel frame.
        .overlay {
            CompanionDragHandle(onOpen: {}, onEndVoice: {}, onStopTask: {}, onHide: {},
                                onMoving: { _ in }, onDrop: {}, onLayout: onContentLayout, isInteractive: false)
                .accessibilityHidden(true)
        }
        .padding(8)
        .frame(width: Self.panelSize(hasApproval: presentation.approval != nil).width,
               height: Self.panelSize(hasApproval: presentation.approval != nil).height, alignment: .bottomTrailing)
        .ivyGlassGroup(spacing: 8)
    }

    private func bubble(_ text: String, lines: Int) -> some View {
        Text(text).font(.system(size: 12)).lineLimit(lines)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .ivyGlass(cornerRadius: 12)
            .frame(maxWidth: 260, alignment: .trailing)
    }

    private var status: String {
        switch mood {
        case .hidden, .idle: "Ivy · Ready"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        case .working(let progress): "Working · \(Int(max(0, min(1, progress)) * 100))%"
        case .needsApproval: "Needs approval"
        case .error: "Needs attention"
        }
    }

    private var symbol: String {
        switch mood {
        case .hidden, .idle: "leaf"
        case .listening: "mic"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2"
        case .working: "checklist"
        case .needsApproval: "hand.raised"
        case .error: "exclamationmark.circle"
        }
    }

    private var statusColor: Color {
        switch mood {
        case .needsApproval: IvyTheme.riskAmber
        case .error: IvyTheme.dangerRed
        default: .primary
        }
    }
}

private struct CompanionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
