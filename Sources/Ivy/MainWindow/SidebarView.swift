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
            HStack(spacing: 10) {
                Image(nsImage: IvyLogoImage.template)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(IvyTheme.moss)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ivy").font(.headline)
                    Text("Your Mac assistant").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
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
                        Text("Your conversations will appear here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(groups) { group in
                        Section(group.section.title) {
                            ForEach(group.entries) { entry in
                                conversationRow(entry)
                                    .tag(entry.id)
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
                                conversationRow(entry)
                                    .tag(entry.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $query, placement: .sidebar, prompt: "Search conversations")

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    WorkspaceMenu(workspaces: workspaces, tasks: tasks)
                    Spacer(minLength: 0)
                }
                HStack {
                    Toggle(isOn: $showArchived) { Label("Archived", systemImage: "archivebox") }
                        .toggleStyle(.checkbox)
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape").frame(width: 28, height: 28) }
                        .buttonStyle(.borderless)
                        .help("Settings (⌘,)")
                        .accessibilityLabel("Settings")
                }
                .font(.callout)
            }
            .padding(12)
        }
        .onAppear { library.refresh() }
        // A turn just saved: its title, preview and position in the list may have changed.
        .onChange(of: brain.messages.count) { library.refresh() }
        .alert("Conversation Could Not Be Updated", isPresented: Binding(
            get: { library.lastError != nil }, set: { if !$0 { library.dismissError() } }
        )) {
            Button("OK", role: .cancel) { library.dismissError() }
        } message: { Text(library.lastError ?? "") }
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

    private func conversationRow(_ entry: ConversationSummary) -> some View {
        HStack(alignment: .top, spacing: 4) {
            row(title: entry.title, detail: entry.preview, date: entry.updatedAt, pinned: entry.isPinned)
            Menu { menu(for: entry) } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(entry.title)")
        }
        .contextMenu { menu(for: entry) }
    }

    private func row(title: String, detail: String, date: Date, pinned: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.secondary) }
                Text(title).font(.body.weight(.medium)).lineLimit(1)
            }
            if !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(pinned ? "Pinned. " : "")\(title)")
        .help(date.formatted(date: .abbreviated, time: .shortened))
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
