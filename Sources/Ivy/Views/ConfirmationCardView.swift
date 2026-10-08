import SwiftUI
import IvyCore

public struct ConfirmationCardView: View {
    public let request: ConfirmationRequest
    public let onConfirm: (Bool) -> Void
    private let compact: Bool
    @State private var hasResponded: Bool = false

    public init(request: ConfirmationRequest, compact: Bool = false, onConfirm: @escaping (Bool) -> Void) {
        self.request = request
        self.compact = compact
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(compact ? request.companionReason : request.title)
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help([request.companionReason, request.title, request.prompt, request.detail].joined(separator: "\n\n"))
                .accessibilityIdentifier("ivy.approval.reason")
            HStack(spacing: 8) {
                if !compact { Spacer(minLength: 0) }
                decisionButtons
            }
        }
        .padding(compact ? 10 : 12)
        .tint(IvyTheme.leaf)
    }

    private var decisionButtons: some View {
        Group {
            Button(role: .cancel) {
                guard !hasResponded else { return }
                hasResponded = true
                onConfirm(false)
            } label: {
                Text("Cancel")
                    .frame(minWidth: compact ? 48 : 64, maxWidth: compact ? .infinity : nil,
                           minHeight: compact ? 28 : nil)
            }
            .companionApprovalButtonStyle(compact: compact, prominent: false)
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(hasResponded)
            .accessibilityHint("Refuses this action. Nothing will run.")
            .accessibilityIdentifier("ivy.approval.cancel")

            Button {
                guard !hasResponded else { return }
                hasResponded = true
                onConfirm(true)
            } label: {
                Text("Do it")
                    .bold()
                    .frame(minWidth: compact ? 48 : 64, maxWidth: compact ? .infinity : nil,
                           minHeight: compact ? 28 : nil)
            }
            .companionApprovalButtonStyle(compact: compact, prominent: true)
            .tint(IvyTheme.leaf)
            // Deliberate chord, not plain Return: a stray Return while typing must never approve a risky action.
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(hasResponded)
            .accessibilityLabel("Do it")
            .accessibilityHint("Approves and runs this action. Shortcut: Command Return.")
            .accessibilityIdentifier("ivy.approval.confirm")
        }
    }
}

/// Companion decisions stay legible even when this floating panel isn't the active window.
private extension View {
    @ViewBuilder func companionApprovalButtonStyle(compact: Bool, prominent: Bool) -> some View {
        if compact { self.buttonStyle(CompanionDecisionStyle(prominent: prominent)) }
        else { self.ivyGlassButtonStyle(prominent: prominent) }
    }
}

private struct CompanionDecisionStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        CompanionDecisionLabel(configuration: configuration, prominent: prominent)
    }
}

private struct CompanionDecisionLabel: View {
    let configuration: ButtonStyleConfiguration
    let prominent: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(prominent ? IvyTheme.canvas : Color.primary)
            .background(prominent ? IvyTheme.leaf : Color.primary.opacity(hovering && isEnabled ? 0.12 : 0.06),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0.10))
            }
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
    }
}
