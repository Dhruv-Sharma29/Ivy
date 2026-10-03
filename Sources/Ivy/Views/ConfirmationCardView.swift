import SwiftUI
import IvyCore

public struct ConfirmationCardView: View {
    public let request: ConfirmationRequest
    public let onConfirm: (Bool) -> Void
    @State private var hasResponded: Bool = false

    public init(request: ConfirmationRequest, onConfirm: @escaping (Bool) -> Void) {
        self.request = request
        self.onConfirm = onConfirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IvyAppIconView().frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Approval required")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(request.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Image(systemName: "lock.shield")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(request.prompt)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !request.detail.isEmpty {
                        Text(request.detail)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 180)

            Divider()

            HStack(spacing: 10) {
                Text("Nothing runs until you approve.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button(role: .cancel) {
                    guard !hasResponded else { return }
                    hasResponded = true
                    onConfirm(false)
                } label: {
                    Text("Cancel")
                        .frame(minWidth: 64)
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
                        .frame(minWidth: 64)
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
        .padding(20)
        .tint(IvyTheme.leaf)
    }
}

/// A bounded native sheet keeps actions visible while long requests scroll independently.
struct ConfirmationSheetView: View {
    let request: ConfirmationRequest
    let onConfirm: (Bool) -> Void

    var body: some View {
        ConfirmationCardView(request: request, onConfirm: onConfirm)
            .frame(width: 500, height: 340)
            .interactiveDismissDisabled()
            .accessibilityIdentifier("ivy.approval")
    }
}
