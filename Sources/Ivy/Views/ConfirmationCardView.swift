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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 14))

                Text(request.title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Spacer()

                Text("CONFIRMATION")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(request.prompt)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !request.detail.isEmpty {
                        Text(request.detail)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                            )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)

            HStack(spacing: 10) {
                Button(role: .cancel) {
                    guard !hasResponded else { return }
                    hasResponded = true
                    onConfirm(false)
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
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
                        .frame(maxWidth: .infinity)
                }
                .ivyGlassButtonStyle(prominent: true)
                .tint(.orange)
                // Deliberate chord, not plain Return: a stray Return while typing must never approve a risky action.
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(hasResponded)
                .accessibilityLabel("Do it")
                .accessibilityHint("Approves and runs this action. Shortcut: Command Return.")
                .accessibilityIdentifier("ivy.approval.confirm")
            }
        }
        .padding(12)
        .ivyGlass(cornerRadius: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}

/// A bounded native sheet keeps actions visible while long requests scroll independently.
struct ConfirmationSheetView: View {
    let request: ConfirmationRequest
    let onConfirm: (Bool) -> Void

    var body: some View {
        ConfirmationCardView(request: request, onConfirm: onConfirm)
            .padding(20)
            .frame(width: 500, height: 400)
            .interactiveDismissDisabled()
            .accessibilityIdentifier("ivy.approval")
    }
}
