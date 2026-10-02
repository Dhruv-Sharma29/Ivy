import SwiftUI
import IvyCore

/// Sidebar footer: which project Ivy's developer tools work in, its commands, and the developer task templates.
struct WorkspaceMenu: View {
    @ObservedObject var workspaces: WorkspaceModel
    @ObservedObject var tasks: TaskEngine
    @State private var editing: Workspace?

    var body: some View {
        Menu {
            Section("Workspace") {
                ForEach(workspaces.workspaces) { workspace in
                    Button {
                        workspaces.activate(workspace.id)
                    } label: {
                        if workspace.id == workspaces.activeID {
                            Label(workspace.name, systemImage: "checkmark")
                        } else {
                            Text(workspace.name)
                        }
                    }
                }
                Button("None") { workspaces.activate(nil) }
                Button("Add Folder…", action: addFolder)
            }
            if let active = workspaces.active {
                Section(active.name) {
                    Button("Commands…") { editing = active }
                    Button("Remove from Ivy") { workspaces.remove(active.id) }
                }
                Section("Tasks") {
                    ForEach(DeveloperTemplates.all, id: \.title) { template in
                        Button(template.title) {
                            Task { await tasks.start(goal: template.goal(for: active)) }
                        }
                        .disabled(tasks.run?.isActive == true)
                    }
                }
            }
        } label: {
            Label(workspaces.active?.name ?? "No workspace", systemImage: "folder")
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(workspaces.context ?? "Pick the project Ivy's git, build and test tools work in")
        .sheet(item: $editing) { workspace in
            WorkspaceCommandsSheet(workspaces: workspaces, workspace: workspace)
        }
        .alert("Workspace", isPresented: Binding(get: { workspaces.lastError != nil }, set: { if !$0 { workspaces.dismissError() } })) {
            Button("OK", role: .cancel) { workspaces.dismissError() }
        } message: {
            Text(workspaces.lastError ?? "")
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspaces.add(folder: url)
    }
}

/// The project commands, edited by the user only. The model can ask to run "test"; it never writes the command.
private struct WorkspaceCommandsSheet: View {
    @ObservedObject var workspaces: WorkspaceModel
    let workspace: Workspace
    @State private var drafts: [String: String] = [:]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commands for \(workspace.name)").font(.headline)
            Text("Ivy asks before running any of these, every time. Detected kinds: \(workspace.kinds.isEmpty ? "none" : workspace.kinds.map(\.rawValue).joined(separator: ", ")).")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ForEach(Workspace.commandNames, id: \.self) { name in
                HStack {
                    Text(name).frame(width: 50, alignment: .leading)
                    TextField("not set", text: Binding(get: { drafts[name] ?? "" }, set: { drafts[name] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") {
                    for name in Workspace.commandNames { workspaces.setCommand(name, to: drafts[name] ?? "", in: workspace.id) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { drafts = workspace.commands }
    }
}

/// Phase 16.10: developer goals that run as Phase 15 tasks (plan → approval → per-step cards).
enum DeveloperTemplates {
    struct Template {
        let title: String
        let makeGoal: (Workspace) -> String
        func goal(for workspace: Workspace) -> String { makeGoal(workspace) }
    }

    static var all: [Template] { [
        Template(title: "Set Up This Project") { w in
            "In the workspace \(w.name) (\(w.root)): check the git status, then build and run the tests with project_run, and summarise what's needed to get it working. Don't install anything."
        },
        Template(title: "Fix Failing Tests") { w in
            "In the workspace \(w.name): run the tests with project_run, analyse the failures with log_analyze, read the relevant files, propose minimal fixes as file_op writes inside the workspace, then run the tests again."
        },
        Template(title: "Review My Changes") { w in
            "In the workspace \(w.name): read git status and the staged and unstaged diffs with git_read, and write a short code review. Make no changes."
        },
    ] }
}
