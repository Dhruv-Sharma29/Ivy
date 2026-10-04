import SwiftUI
import IvyCore

/// One reply in the main window: prose as Markdown, code and diffs as monospaced blocks with Copy.
struct MessageBlocksView: View {
    let text: String
    var onApplyDiff: ((String) -> Void)? = nil
    @State private var proposal: DiffDraftProposal?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MessageBlock.parse(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .text(let prose):
                    Text(Self.markdown(prose))
                        .font(IvyTheme.bodyFont)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let code):
                    CodeBlockView(label: language ?? "code", text: code) {
                        Text(code).font(IvyTheme.codeFont)
                    }
                case .diff(let diff):
                    CodeBlockView(label: "diff", text: diff, onApply: onApplyDiff == nil ? nil : {
                        proposal = DiffDraftProposal(diff: diff)
                    }) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(diff.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                                Text(String(line).isEmpty ? " " : String(line))
                                    .font(IvyTheme.codeFont)
                                    .foregroundStyle(Self.color(DiffLineKind.of(line)))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Self.background(DiffLineKind.of(line)))
                            }
                        }
                    }
                }
            }
        }
        .sheet(item: $proposal) { item in
            DiffDraftSheet(proposal: item, onDraft: { draft in onApplyDiff?(draft); proposal = nil },
                           onCancel: { proposal = nil })
        }
    }

    /// Inline Markdown (bold, italics, `code`, links) with the original line breaks kept. Links are shown,
    /// never opened automatically.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static func color(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added: return .green
        case .removed: return .red
        case .hunk: return .purple
        case .header: return .secondary
        case .context: return .primary
        }
    }

    private static func background(_ kind: DiffLineKind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.10)
        case .removed: return Color.red.opacity(0.10)
        default: return .clear
        }
    }
}

/// A labelled, horizontally scrolling monospaced block with a Copy button.
private struct CodeBlockView<Content: View>: View {
    let label: String
    let text: String
    var onApply: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let onApply {
                    Button("Apply…", action: onApply)
                        .buttonStyle(.borderless).frame(minHeight: 28)
                        .help("Draft a file_op change in the composer")
                }
                MessageCopyButton(text: text, accessibilityTitle: "Copy \(label)")
                .buttonStyle(.borderless)
                .font(.caption.weight(.medium))
                .frame(minHeight: 28)
                .foregroundStyle(IvyTheme.moss)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08))

            ScrollView(.horizontal) {
                content()
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: IvyTheme.codeRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: IvyTheme.codeRadius, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
        )
    }
}

struct DiffDraftSheet: View {
    @ObservedObject var proposal: DiffDraftProposal
    let onDraft: (String) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Draft a file change").font(.title2.weight(.semibold))
            Text("Choose the target. Ivy will read the file and request approval before writing. Nothing is sent yet.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("File path", text: $proposal.path).textFieldStyle(.roundedBorder)
            if let error = proposal.error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Add to Composer") {
                    if let draft = proposal.draft() { onDraft(draft) }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 440).ivyWindowBackground().ivyGlassButtonStyle()
    }
}
