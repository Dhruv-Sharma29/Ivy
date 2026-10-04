import SwiftUI
import IvyCore

struct ToolCardView: View {
    let execution: ToolExecution
    @State private var expanded = false

    init(execution: ToolExecution, initiallyExpanded: Bool = false) {
        self.execution = execution
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Arguments").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(execution.arguments).font(IvyTheme.codeFont).textSelection(.enabled)
                if let output = execution.output {
                    Text("Output").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(output).font(IvyTheme.codeFont).textSelection(.enabled)
                } else {
                    Text("Waiting for approval or running…").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(.secondary)
                Text(execution.name).font(.callout.weight(.medium))
                Spacer()
                if execution.status == .running { ProgressView().controlSize(.mini) }
                Label(execution.status.rawValue.capitalized, systemImage: symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(execution.status == .failed ? Color.red : Color.secondary)
            }
            .frame(minHeight: 28)
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
        .accessibilityIdentifier("ivy.tool.\(execution.id)")
    }

    private var symbol: String {
        switch execution.status {
        case .running: "clock"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        }
    }
}

/// Tool cards share the timeline without becoming model messages or persisted raw payloads.
struct ChatFeedView: View {
    let messages: [ChatMessage]
    @ObservedObject var activity: ToolActivity
    @ObservedObject var voice: VoicePlaybackManager
    var onApplyDiff: ((String) -> Void)?

    private enum Item: Identifiable {
        case message(ChatMessage), tool(ToolExecution)
        var id: String {
            switch self { case .message(let value): "message-\(value.id)"; case .tool(let value): "tool-\(value.id)" }
        }
        var date: Date {
            switch self { case .message(let value): value.timestamp; case .tool(let value): value.startedAt }
        }
    }

    private var items: [Item] {
        let messageItems: [Item] = messages.map { .message($0) }
        let toolItems: [Item] = activity.records.map { .tool($0) }
        let combined: [Item] = messageItems + toolItems
        return combined.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.id < rhs.id }
            return lhs.date < rhs.date
        }
    }

    var body: some View {
        ForEach(items) { item in
            switch item {
            case .message(let message):
                MessageRowView(message: message, voiceManager: voice, onApplyDiff: onApplyDiff)
            case .tool(let execution): ToolCardView(execution: execution)
            }
        }
    }
}
