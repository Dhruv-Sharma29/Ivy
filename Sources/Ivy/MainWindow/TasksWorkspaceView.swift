import SwiftUI
import IvyCore

struct TasksWorkspaceView: View {
    @ObservedObject var tasks: TaskEngine
    var selectedTaskID: UUID?
    let blocked: Bool
    let onPrompt: (String) -> Void

    private var selectedRun: TaskRun? {
        if let selectedTaskID {
            return tasks.run?.id == selectedTaskID ? tasks.run : tasks.history.first { $0.id == selectedTaskID }
        }
        return tasks.run
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Tasks").font(.largeTitle.weight(.semibold))
                        Text("Plans, progress and results.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button { onPrompt("/agent ") } label: { Label("New task", systemImage: "plus") }
                        .ivyGlassButtonStyle().disabled(blocked)
                }
                if let run = selectedRun {
                    if run.id == tasks.run?.id && run.isActive {
                        TaskCardView(engine: tasks, expanded: true)
                    } else {
                        TaskReportView(run: run)
                        Button { onPrompt("/agent " + run.goal) } label: { Label("Plan again", systemImage: "arrow.clockwise") }
                            .ivyGlassButtonStyle().disabled(blocked)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checklist").font(.system(size: 30)).foregroundStyle(IvyTheme.moss)
                            .frame(width: 64, height: 64).ivyGlass(cornerRadius: IvyTheme.cardRadius)
                        Text("What can Ivy take off your list?").font(.title2.weight(.medium)).multilineTextAlignment(.center)
                        Text("Start with a goal. Ivy helps you plan the steps and review the result.")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("Start with an idea").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                        ForEach(AssistantTaskStarter.allCases) { starter in
                            Button { onPrompt(starter.prompt) } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: starter.symbol).font(.system(size: 20))
                                        .foregroundStyle(IvyTheme.moss).frame(width: 38, height: 38)
                                        .background(IvyTheme.moss.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                        .accessibilityHidden(true)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(starter.rawValue).font(.body.weight(.medium)).foregroundStyle(.primary)
                                        Text(starter.detail).font(.callout).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(18).frame(maxWidth: .infinity, minHeight: 106, alignment: .topLeading)
                                .contentShape(RoundedRectangle(cornerRadius: IvyTheme.cardRadius))
                                .ivyGlass(cornerRadius: IvyTheme.cardRadius, interactive: true)
                            }
                            .buttonStyle(IvyNavigationButtonStyle()).disabled(blocked)
                            .accessibilityHint("Open a draft in Chat")
                        }
                    }
                }
                Text("Starters open a draft in Chat. Review it before sending; Ivy asks before risky actions.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .ivyGlassGroup()
        .accessibilityIdentifier("ivy.workspace.tasks")
    }
}

struct TaskReportView: View {
    let run: TaskRun

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Label(TaskRunDisplay.status(run.phase), systemImage: TaskRunDisplay.symbol(run.phase))
                    .font(.callout.weight(.medium)).foregroundStyle(IvyTheme.moss)
                Text(run.goal).font(.title2.weight(.semibold)).textSelection(.enabled)
                Text(run.finishedAt ?? run.createdAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let report = run.report, !report.isEmpty {
                Divider()
                Text("Result").font(.headline)
                MessageBlocksView(text: report)
            }
            if !run.plan.steps.isEmpty {
                Divider()
                Text("Steps").font(.headline)
                ForEach(run.plan.steps) { step in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: stepSymbol(step.status)).frame(width: 18).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).font(.body)
                            switch step.status {
                            case .failed(let reason), .skipped(let reason):
                                Text(reason).font(.callout).foregroundStyle(.secondary)
                            default: EmptyView()
                            }
                        }
                    }
                }
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .ivyGlass(cornerRadius: IvyTheme.cardRadius)
    }

    private func stepSymbol(_ status: StepStatus) -> String {
        switch status {
        case .pending: "circle"
        case .running: "arrow.triangle.2.circlepath"
        case .succeeded: "checkmark.circle"
        case .failed: "exclamationmark.circle"
        case .skipped: "arrow.uturn.right.circle"
        case .cancelled: "minus.circle"
        }
    }
}
