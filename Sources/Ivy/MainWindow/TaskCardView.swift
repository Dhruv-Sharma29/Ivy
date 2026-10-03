import SwiftUI
import IvyCore

/// The running task: goal, steps with live status, and the only buttons that move it forward. Approving the
/// plan approves the order; each risky step still shows its own confirmation card below.
struct TaskCardView: View {
    @ObservedObject var engine: TaskEngine
    var showsSurface = true
    var expanded = false

    var body: some View {
        if let run = engine.run {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: icon(run.phase)).foregroundStyle(color(run.phase))
                    Text(run.goal).font(expanded ? .headline : .system(size: 12, weight: .semibold)).lineLimit(2)
                    Spacer()
                    Text(phaseText(run.phase)).font(expanded ? .caption : .system(size: 10)).foregroundStyle(.secondary)
                }

                if run.phase == .planning {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Planning…").font(expanded ? .callout : .system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                ForEach(run.plan.steps) { step in
                    HStack(alignment: .top, spacing: expanded ? 12 : 6) {
                        Image(systemName: stepIcon(step.status))
                            .foregroundStyle(stepColor(step.status))
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(step.title).font(expanded ? .body : .system(size: 11))
                                if !expanded {
                                    Text(step.tool).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }
                            if case .failed(let why) = step.status {
                                Text(why).font(expanded ? .callout : .system(size: 10)).foregroundStyle(.red).lineLimit(3)
                            } else if case .skipped(let why) = step.status {
                                Text(why).font(expanded ? .callout : .system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                            } else if step.status == .running, let output = step.output, !output.isEmpty {
                                Text(output.suffix(200)).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
                            }
                        }
                    }
                }

                controls(run)
            }
            .padding(expanded ? 20 : 12)
            .ivyGlass(cornerRadius: IvyTheme.cardRadius, enabled: showsSurface)
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }

    @ViewBuilder
    private func controls(_ run: TaskRun) -> some View {
        HStack {
            switch run.phase {
            case .awaitingApproval:
                Text("Risky steps will still ask you one by one.").font(expanded ? .caption : .system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { engine.cancel() }
                Button("Run this plan") { engine.approvePlan() }
                    .ivyGlassButtonStyle(prominent: true)
                    .tint(IvyTheme.leaf)
            case .paused(.stepFailed):
                Spacer()
                Button("Stop") { engine.resolvePause(.stop) }
                Button("Skip step") { engine.resolvePause(.skip) }
                Button("Retry") { engine.resolvePause(.retry) }.ivyGlassButtonStyle(prominent: true)
            case .paused(.budget(let why)):
                Text("Budget reached: \(why)").font(.system(size: 10)).foregroundStyle(.orange)
                Spacer()
                Button("Stop") { engine.resolvePause(.stop) }
                Button("Continue") { engine.resolvePause(.continue) }.ivyGlassButtonStyle(prominent: true)
            case .planning, .running:
                Spacer()
                Button("Stop", role: .destructive) { engine.cancel() }
                    .keyboardShortcut(".", modifiers: [.command])
                    .help("Stop the task (⌘.): the running step is ended and nothing else runs")
            case .finished:
                Spacer()
                Button("Run again") { Task { await engine.rerun(run) } }
                Button("Dismiss") { engine.dismiss() }
            }
        }
        .controlSize(.small)
        .ivyGlassButtonStyle()
    }

    private func phaseText(_ phase: TaskPhase) -> String {
        switch phase {
        case .planning: return "planning"
        case .awaitingApproval: return "waiting for your OK"
        case .running: return "running"
        case .paused: return "paused"
        case .finished(.succeeded): return "done"
        case .finished(.failed): return "stopped with problems"
        case .finished(.cancelled): return "stopped"
        }
    }

    private func icon(_ phase: TaskPhase) -> String {
        switch phase {
        case .finished(.succeeded): return "checkmark.seal.fill"
        case .finished: return "xmark.octagon"
        case .paused: return "pause.circle"
        default: return "list.bullet.clipboard"
        }
    }

    private func color(_ phase: TaskPhase) -> Color {
        switch phase {
        case .finished(.succeeded): return IvyTheme.leaf
        case .finished, .paused: return .orange
        default: return .secondary
        }
    }

    private func stepIcon(_ status: StepStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "arrow.uturn.right.circle"
        case .cancelled: return "minus.circle"
        }
    }

    private func stepColor(_ status: StepStatus) -> Color {
        switch status {
        case .succeeded: return IvyTheme.leaf
        case .failed: return .red
        case .running: return .accentColor
        default: return .secondary
        }
    }
}
