import SwiftUI
import IvyCore

/// The engine executes sequentially. Arrows show that order; dependency labels remain explicit.
struct TaskFlowDiagram: View {
    let steps: [TaskStep]
    var phase: TaskPhase? = nil
    var expandedDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Execution flow", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.headline).padding(.bottom, 12)
            if steps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    if let phase {
                        Label(TaskRunDisplay.status(phase), systemImage: TaskRunDisplay.symbol(phase)).font(.body.weight(.medium))
                    }
                    Text(phase == .planning ? "Ivy is preparing the steps." : "No executable steps were produced.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(IvyTheme.canvas.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
            }
            ForEach(steps) { step in
                TaskFlowNode(step: step, number: (steps.firstIndex { $0.id == step.id } ?? 0) + 1,
                             expandedDetails: expandedDetails)
                if step.id != steps.last?.id {
                    VStack(spacing: 0) {
                        Rectangle().frame(width: 1, height: 14)
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(.secondary).frame(height: 24).padding(.leading, 26)
                    .accessibilityHidden(true)
                }
            }
            Text("Ivy runs one step at a time. Risky actions still need your approval.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, 12)
        }
        .accessibilityIdentifier("ivy.task.flow")
    }
}

struct TaskFlowNode: View {
    let step: TaskStep
    let number: Int
    var expandedDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(number, format: .number).font(.caption.weight(.semibold))
                    .frame(width: 24, height: 24)
                    .background(IvyTheme.moss.opacity(0.12), in: Circle()).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(SecretRedactor.redact(step.title)).font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    ViewThatFits(in: .horizontal) {
                        HStack { status; Spacer(minLength: 8); tool }
                        VStack(alignment: .leading, spacing: 4) { status; tool }
                    }
                }
            }
            switch step.status {
            case .failed(let reason), .skipped(let reason):
                Text(SecretRedactor.redact(reason)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            default: EmptyView()
            }
            if !step.dependsOn.isEmpty {
                Text("Depends on: " + step.dependsOn.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(isExpanded: .init(get: { expandedDetails || detailsOpen }, set: { detailsOpen = $0 })) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Arguments").font(.caption.weight(.semibold))
                    Text(arguments).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    if let output = step.output, !output.isEmpty {
                        Text("Output").font(.caption.weight(.semibold))
                        Text(SecretRedactor.redact(output)).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            } label: { Text("Details").font(.caption) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(IvyTheme.canvas.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(color.opacity(step.status == .running ? 0.7 : 0.2), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(number): \(SecretRedactor.redact(step.title))")
        .accessibilityIdentifier("ivy.task.step.\(step.id)")
    }

    @State private var detailsOpen = false

    private var tool: some View {
        Text(step.tool).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
    }

    private var status: some View {
        HStack(spacing: 5) {
            if step.status == .running { ProgressView().controlSize(.mini) }
            else { Image(systemName: symbol).accessibilityHidden(true) }
            Text(statusText)
        }
        .font(.caption.weight(.medium)).foregroundStyle(color)
    }

    private var statusText: String {
        switch step.status {
        case .pending: "Pending"
        case .running: "Running"
        case .succeeded: "Succeeded"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .cancelled: "Cancelled"
        }
    }

    private var symbol: String {
        switch step.status {
        case .pending: "circle"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .skipped: "arrow.uturn.right.circle"
        case .cancelled: "minus.circle"
        }
    }

    private var color: Color {
        switch step.status {
        case .running: IvyTheme.leaf
        case .succeeded: .green
        case .failed: .red
        default: .secondary
        }
    }

    private var arguments: String {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let safe = TaskStep.persistedArguments(for: step.tool, arguments: step.arguments)
            return SecretRedactor.redact(String(decoding: try encoder.encode(safe), as: UTF8.self))
        } catch {
            return "Couldn't display arguments: \(error.localizedDescription)"
        }
    }
}
