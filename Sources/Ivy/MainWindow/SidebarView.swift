import SwiftUI
import IvyCore

/// The main window's conversation list: search, pinned and date groups, archived, and the library actions.
struct SidebarView: View {
    @ObservedObject var library: ConversationLibrary
    @ObservedObject var brain: IvyBrain
    @ObservedObject var workspaces: WorkspaceModel
    @ObservedObject var tasks: TaskEngine

    @State private var query = ""
    @State private var showArchived = false
    @State private var renaming: ConversationSummary?
    @State private var newTitle = ""
    @State private var deleting: ConversationSummary?

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Selecting a row opens that conversation (a pending approval in the current one is denied).
    private var selection: Binding<UUID?> {
        Binding(
            get: { library.activeConversationID },
            set: { id in
                guard let id, id != library.activeConversationID else { return }
                library.open(id)
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: selection) {
                if isSearching {
                    let hits = library.search(query)
                    Section("Results") {
                        if hits.isEmpty {
                            Text("No matches.").foregroundStyle(.secondary)
                        }
                        ForEach(hits) { hit in
                            row(title: hit.title, detail: hit.snippet, date: hit.updatedAt, pinned: false)
                                .tag(hit.conversationID)
                        }
                    }
                } else {
                    let groups = ConversationGroup.group(library.entries)
                    if groups.isEmpty {
                        Text("No conversations yet. Say something.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(groups) { group in
                        Section(group.section.title) {
                            ForEach(group.entries) { entry in
                                row(title: entry.title, detail: entry.preview, date: entry.updatedAt, pinned: entry.isPinned)
                                    .tag(entry.id)
                                    .contextMenu { menu(for: entry) }
                            }
                        }
                    }
                    if showArchived {
                        Section("Archived") {
                            let archived = library.list(.archived)
                            if archived.isEmpty {
                                Text("Nothing archived.").foregroundStyle(.secondary)
                            }
                            ForEach(archived) { entry in
                                row(title: entry.title, detail: entry.preview, date: entry.updatedAt, pinned: false)
                                    .tag(entry.id)
                                    .contextMenu { menu(for: entry) }
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $query, placement: .sidebar, prompt: "Search conversations")

            Divider()
            HStack {
                Button {
                    library.newConversation()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: [.command])
                .help("New conversation (⌘N)")
                Spacer()
                WorkspaceMenu(workspaces: workspaces, tasks: tasks)
                Toggle("Archived", isOn: $showArchived)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear { library.refresh() }
        // A turn just saved: its title, preview and position in the list may have changed.
        .onChange(of: brain.messages.count) { library.refresh() }
        .alert("Rename Conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let renaming { library.rename(renaming.id, to: newTitle) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        } message: {
            Text("Leave it empty to let Ivy name it.")
        }
        .confirmationDialog(
            "Delete \u{201C}\(deleting?.title ?? "")\u{201D}?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Delete", role: .destructive) {
                if let deleting { library.delete(deleting.id) }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("This permanently removes the conversation. Archive it instead to keep it out of the way.")
        }
    }

    private func row(title: String, detail: String, date: Date, pinned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if pinned {
                    Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            if !detail.isEmpty {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pinned ? "Pinned. " : "")\(title)")
    }

    @ViewBuilder
    private func menu(for entry: ConversationSummary) -> some View {
        Button("Rename…") {
            newTitle = entry.title
            renaming = entry
        }
        Button(entry.isPinned ? "Unpin" : "Pin") { library.setPinned(entry.id, !entry.isPinned) }
        Button(entry.isArchived ? "Unarchive" : "Archive") { library.setArchived(entry.id, !entry.isArchived) }
        Divider()
        Button("Export as Markdown…") {
            ConversationFileExport.run(library, id: entry.id, title: entry.title, format: .markdown)
        }
        Button("Export as JSON…") {
            ConversationFileExport.run(library, id: entry.id, title: entry.title, format: .json)
        }
        Divider()
        Button("Delete…", role: .destructive) { deleting = entry }
    }
}
