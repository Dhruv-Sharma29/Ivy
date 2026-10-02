import SwiftUI
import IvyCore

/// The main window's conversation list: search, pinned and date groups, archived, and the library actions.
struct SidebarView: View {
    @ObservedObject var library: ConversationLibrary
    @ObservedObject var brain: IvyBrain
    @ObservedObject var workspaces: WorkspaceModel
    @ObservedObject var tasks: TaskEngine
    @Binding var destination: WorkspaceDestination

    @State private var query = ""
    @State private var showArchived = false
    @State private var renaming: ConversationSummary?
    @State private var newTitle = ""
    @State private var deleting: ConversationSummary?

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IvyAppIconView().frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ivy").font(.headline)
                    Text("Your Mac assistant").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { library.newConversation(); destination = .chat } label: {
                    Image(systemName: "square.and.pencil").frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help("New conversation (⌘N)")
                .accessibilityLabel("New conversation")
                .accessibilityIdentifier("ivy.newConversation")
            }
            .padding(16)
            List {
                Section {
                    ForEach(WorkspaceDestination.allCases) { item in
                        navigationRow(item.rawValue, symbol: item.symbol, selected: destination == item) { destination = item }
                            .accessibilityIdentifier("ivy.navigation.\(item.id)")
                    }
                    SettingsLink {
                        navigationLabel("Settings", symbol: "gearshape", selected: false)
                    }
                    .buttonStyle(IvyNavigationButtonStyle())
                    .help("Settings (⌘,)")
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                if isSearching {
                    let hits = library.search(query)
                    Section("Results") {
                        if hits.isEmpty {
                            Text("No matches.").foregroundStyle(.secondary)
                        }
                        ForEach(hits) { hit in
                            Button {
                                if library.open(hit.conversationID) { destination = .chat }
                            } label: {
                                row(title: hit.title, detail: hit.snippet, date: hit.updatedAt, pinned: false)
                            }
                            .buttonStyle(.plain)
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
            .scrollContentBackground(.hidden)
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
                }
                .font(.callout)
            }
            .padding(12)
        }
        .modifier(IvySidebarBackground())
        .ivyGlassGroup(spacing: 8)
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
            Button {
                if library.open(entry.id) { destination = .chat }
            } label: {
                row(title: entry.title, detail: entry.preview, date: entry.updatedAt, pinned: entry.isPinned)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Menu { menu(for: entry) } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Actions for \(entry.title)")
        }
        .padding(.horizontal, 8)
        .ivyGlass(cornerRadius: 10, tinted: true, interactive: true,
                  enabled: destination == .chat && entry.id == library.activeConversationID)
        .contextMenu { menu(for: entry) }
    }

    private func navigationRow(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            navigationLabel(title, symbol: symbol, selected: selected)
        }
        .buttonStyle(IvyNavigationButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func navigationLabel(_ title: String, symbol: String, selected: Bool) -> some View {
        let label = HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).frame(width: 22)
            Text(title).font(.body.weight(selected ? .semibold : .regular))
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? IvyTheme.moss : Color.primary)
        .padding(.horizontal, 12).frame(minHeight: 40)
        .contentShape(Rectangle())
        if selected { label.ivyGlass(tinted: true, interactive: true) } else { label }
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
