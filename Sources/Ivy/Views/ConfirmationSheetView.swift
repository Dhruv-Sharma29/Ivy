import SwiftUI
import IvyCore

/// Detailed review belongs in the workspace; the companion keeps its compact decision card.
struct ConfirmationSheetView: View {
    let request: ConfirmationRequest
    let onConfirm: (Bool) -> Void
    @State private var hasResponded = false

    private var hasDetails: Bool { !request.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(IvyTheme.leaf)
                    .frame(width: 40, height: 40)
                    .background(IvyTheme.leaf.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Approval required")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(request.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .help(request.title)
                        .accessibilityIdentifier("ivy.approval.reason")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(request.prompt)
                        .font(.body)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("ivy.approval.prompt")
                    if hasDetails {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Action details")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(request.detail)
                                .font(.system(size: 12, design: .monospaced))
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                                .padding(12)
                                .background(IvyTheme.canvas, in: RoundedRectangle(cornerRadius: 10))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10)
                                        .strokeBorder(Color.primary.opacity(0.12))
                                }
                                .accessibilityIdentifier("ivy.approval.details")
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            .frame(maxHeight: .infinity)

            Divider().padding(.horizontal, 20)
            VStack(alignment: .leading, spacing: 12) {
                Text("Nothing runs until you approve.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    Button("Cancel", role: .cancel) { respond(false) }
                        .buttonStyle(.bordered)
                        .keyboardShortcut(.escape, modifiers: [])
                        .accessibilityIdentifier("ivy.approval.cancel")
                        .accessibilityHint("Refuses this action. Nothing will run.")
                    Button("Do it") { respond(true) }
                        .buttonStyle(.borderedProminent)
                        // Plain Return must never approve while the user is reviewing a request.
                        .keyboardShortcut(.return, modifiers: [.command])
                        .accessibilityIdentifier("ivy.approval.confirm")
                        .accessibilityHint("Approves and runs this action. Shortcut: Command Return.")
                }
                .controlSize(.large)
                .disabled(hasResponded)
            }
            .padding(20)
        }
        .frame(width: 460, height: hasDetails ? 400 : 300)
        .background(IvyTheme.surface)
        .tint(IvyTheme.leaf)
        .interactiveDismissDisabled()
        .accessibilityIdentifier("ivy.approval")
    }

    private func respond(_ approved: Bool) {
        guard !hasResponded else { return }
        hasResponded = true
        onConfirm(approved)
    }
}
