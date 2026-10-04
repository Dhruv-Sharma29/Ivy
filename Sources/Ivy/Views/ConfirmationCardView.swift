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
            Text(request.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help([request.title, request.prompt, request.detail].joined(separator: "\n\n"))
                .accessibilityIdentifier("ivy.approval.reason")
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                decisionButtons
            }
        }
        .padding(12)
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
                    .frame(minWidth: compact ? 48 : 64)
            }
            .ivyGlassButtonStyle()
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
                    .frame(minWidth: compact ? 48 : 64)
            }
            .ivyGlassButtonStyle(prominent: true)
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

/// The native sheet shares the companion's reason and two explicit decision controls.
struct ConfirmationSheetView: View {
    let request: ConfirmationRequest
    let onConfirm: (Bool) -> Void

    var body: some View {
        ConfirmationCardView(request: request, onConfirm: onConfirm)
            .frame(width: 280, height: 100)
            .interactiveDismissDisabled()
            .accessibilityIdentifier("ivy.approval")
    }
}
