import SwiftUI
import IvyCore

public struct ConfirmationCardView: View {
    public let request: ConfirmationRequest
    public let onConfirm: (Bool) -> Void

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

                Spacer()

                Text("CONFIRMATION")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }

            Text(request.prompt)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !request.detail.isEmpty {
                ScrollView {
                    Text(request.detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 120)
                .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }

            HStack(spacing: 10) {
                Button(role: .cancel) {
                    onConfirm(false)
                } label: {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])

                Button {
                    onConfirm(true)
                } label: {
                    Text("Do it")
                        .bold()
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)
    }
}
