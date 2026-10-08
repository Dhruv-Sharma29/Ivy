import SwiftUI
import IvyCore

struct TasksWorkspaceView: View {
    @ObservedObject var tasks: TaskEngine
    @ObservedObject var session: TaskWorkspaceSession
    var selectedTaskID: UUID? = nil
    let blocked: Bool
    var onSelect: ((UUID?) -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Tasks").font(.largeTitle.weight(.semibold))
                    Text("Discuss a goal. Follow the flow.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(action: newTask) { Label("New task", systemImage: "plus") }
                    .ivyGlassButtonStyle().disabled(session.isSubmitting)
                    .accessibilityIdentifier("ivy.tasks.new")
            }
            .padding(24).frame(maxWidth: 900).frame(maxWidth: .infinity)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        if session.thread.isEmpty { starters }
                        ForEach(session.thread) { run in
                            VStack(alignment: .leading, spacing: 14) {
                                HStack {
                                    Spacer(minLength: 32)
                                    VStack(alignment: .trailing, spacing: 6) {
                                        Text("You").font(.caption).foregroundStyle(.secondary)
                                        Text(run.goal).textSelection(.enabled)
                                            .padding(14).background(IvyTheme.leaf.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                                    }
                                }
                                Label("Ivy · " + TaskRunDisplay.status(run.phase), systemImage: "leaf")
                                    .font(.callout.weight(.medium)).foregroundStyle(.secondary)
                                if run.id == tasks.run?.id && run.isActive {
                                    TaskCardView(engine: tasks, expanded: true)
                                } else {
                                    TaskReportView(run: run, showsGoal: false)
                                }
                            }
                            .id(run.id)
                        }
                        Color.clear.frame(height: 1).id("latest-task")
                    }
                    .padding(.horizontal, 24).padding(.bottom, 20)
                    .frame(maxWidth: 900).frame(maxWidth: .infinity)
                }
                .onChange(of: session.selectedTaskID) {
                    if let id = session.thread.last?.id {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .top) }
                    }
                }
                .onChange(of: tasks.run?.phase) {
                    if tasks.run?.isActive == false, tasks.run?.id == session.selectedRun?.id {
                        proxy.scrollTo("latest-task", anchor: .bottom)
                    }
                }
            }
            VStack(spacing: 0) {
                if let error = session.error {
                    HStack(alignment: .top) {
                        Label(error, systemImage: "exclamationmark.triangle").font(.callout)
                        Spacer(minLength: 8)
                        Button("Dismiss", action: session.dismissError)
                    }
                    .padding(.horizontal, 24)
                }
                MessageInputBar(text: $session.draft, isThinking: blocked || session.isSubmitting,
                    placeholder: session.selectedRun == nil ? "Describe a task…" : "Plan a follow-up…",
                    onSend: send)
                Text(blocked ? "You can draft a task now. Finish or stop the active request before sending it." : "Send a goal to draft a plan. Review it before choosing Run this plan.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.bottom, 12)
            }
            .frame(maxWidth: 900).frame(maxWidth: .infinity)
        }
        .ivyGlassGroup()
        .onAppear { if let selectedTaskID { session.select(selectedTaskID) } }
        .onChange(of: selectedTaskID) { if let selectedTaskID { session.select(selectedTaskID) } }
        .onChange(of: session.selectedTaskID) { if let id = session.selectedTaskID { onSelect?(id) } }
        .accessibilityIdentifier("ivy.workspace.tasks")
    }

    private var starters: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 12) {
                Image(systemName: "checklist").font(.system(size: 30)).foregroundStyle(IvyTheme.moss)
                    .frame(width: 64, height: 64).ivyGlass(cornerRadius: IvyTheme.cardRadius)
                Text("What can Ivy take off your list?").font(.title2.weight(.medium)).multilineTextAlignment(.center)
                Text("Start the conversation here. Ivy turns your goal into a flow you can review.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 24)
            Text("Start with an idea").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], spacing: 14) {
                ForEach(AssistantTaskStarter.allCases) { starter in
                    Button { draft(starter.prompt) } label: {
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
                    .buttonStyle(IvyNavigationButtonStyle()).disabled(session.isSubmitting)
                    .accessibilityHint("Draft this goal in Tasks without sending it")
                }
            }
        }
    }

    func newTask() {
        guard !session.isSubmitting else { return }
        session.newTask()
        onSelect?(nil)
    }

    func draft(_ prompt: String) {
        guard !session.isSubmitting else { return }
        session.newTask(prompt: prompt)
        onSelect?(nil)
    }

    func send() { Task { await session.send(blocked: blocked) } }
}

struct TaskReportView: View {
    let run: TaskRun
    var showsGoal = true

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Label(TaskRunDisplay.status(run.phase), systemImage: TaskRunDisplay.symbol(run.phase))
                    .font(.callout.weight(.medium)).foregroundStyle(IvyTheme.moss)
                if showsGoal { Text(run.goal).font(.title2.weight(.semibold)).textSelection(.enabled) }
                Text(run.finishedAt ?? run.createdAt, format: .dateTime.month(.abbreviated).day().year().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            TaskFlowDiagram(steps: run.plan.steps, phase: run.phase)
            if let report = run.report, !report.isEmpty {
                Divider()
                Text("Result").font(.headline)
                MessageBlocksView(text: report)
            }
        }
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
        .ivyGlass(cornerRadius: IvyTheme.cardRadius)
    }

}
