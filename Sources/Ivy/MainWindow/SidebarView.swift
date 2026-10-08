import SwiftUI
import IvyCore

/// Compact app navigation beside a searchable conversation library.
struct SidebarView: View {
    @ObservedObject var library: ConversationLibrary
    @ObservedObject var brain: IvyBrain
    @ObservedObject var workspaces: WorkspaceModel
    @ObservedObject var tasks: TaskEngine
    @Binding var destination: WorkspaceDestination
    @Binding var selectedTaskID: UUID?
    let onNewTask: () -> Void
    var isNewTaskDraft = false

    @State private var query = ""
    @State private var searchVisible = false
    @FocusState private var searchFocused: Bool
    @State private var renaming: ConversationSummary?
    @State private var newTitle = ""
    @State private var deleting: ConversationSummary?
    @State private var archiveExpanded = false

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HStack(spacing: 0) {
            navigationRail
            Divider()
            if destination == .tasks { taskPane } else { conversationPane }
        }
        .modifier(IvySidebarBackground())
        .ivyGlassGroup(spacing: 8)
        .onAppear { library.refresh() }
        // A turn just saved: its title, preview and position in the list may have changed.
        .onChange(of: brain.messages.count) { library.refresh() }
        .onChange(of: destination) { query = ""; searchVisible = false }
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

    private var navigationRail: some View {
        VStack(spacing: 12) {
            ForEach(WorkspaceDestination.railDestinations) { item in
                Button { destination = item } label: {
                    railIcon(item.symbol, selected: destination == item)
                }
                .buttonStyle(IvyNavigationButtonStyle())
                .help(item.rawValue)
                .accessibilityLabel(item.rawValue)
                .accessibilityAddTraits(destination == item ? .isSelected : [])
                .accessibilityIdentifier("ivy.navigation.\(item.id)")
            }
            Spacer(minLength: 20)
            SettingsLink {
                railIcon("gearshape", selected: false)
            }
            .buttonStyle(IvyNavigationButtonStyle())
            .help("Settings (⌘,)")
            .accessibilityLabel("Settings")
        }
        .padding(.vertical, 16)
        .frame(width: 56)
    }

    private func railIcon(_ symbol: String, selected: Bool) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 18, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .frame(width: 40, height: 40)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .ivyGlass(cornerRadius: 14, interactive: true, enabled: selected)
    }

    private var taskPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Tasks").font(.system(size: 17, weight: .semibold))
                    Spacer(minLength: 4)
                    Button {
                        searchVisible.toggle()
                        if !searchVisible { query = "" }
                        searchFocused = searchVisible
                    } label: {
                        Image(systemName: searchVisible ? "xmark" : "magnifyingglass").frame(width: 28, height: 28)
                    }
                    .buttonStyle(IvyNavigationButtonStyle()).foregroundStyle(.secondary)
                    .accessibilityLabel(searchVisible ? "Close task search" : "Search tasks")
                    .help(searchVisible ? "Close task search" : "Search tasks")
                }
                Button(action: onNewTask) {
                    Label("New task", systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(IvyNavigationButtonStyle())
                .accessibilityIdentifier("ivy.tasks.new.sidebar")
                if searchVisible {
                    TextField("Search tasks", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
                }
            }
            .padding(14)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if let run = tasks.run, run.isActive, TaskRunDisplay.matches(run, query: query) {
                        Text("Current").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 8)
                        taskRow(run)
                    }
                    let recent = tasks.history.filter { TaskRunDisplay.matches($0, query: query) }
                    Text("Recent tasks").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.top, 8)
                    if recent.isEmpty {
                        Text(query.isEmpty ? "No past tasks yet." : "No matching tasks.")
                            .font(.callout).foregroundStyle(.secondary).padding(8)
                    }
                    ForEach(recent) { run in taskRow(run) }
                }
                .padding(8)
            }
            Divider()
            WorkspaceMenu(workspaces: workspaces, tasks: tasks).padding(12)
        }
        .frame(maxWidth: .infinity)
    }

    private func taskRow(_ run: TaskRun) -> some View {
        let selected = selectedTaskID == run.id || (!isNewTaskDraft && selectedTaskID == nil && tasks.run?.id == run.id)
        return Button { selectedTaskID = run.id } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: TaskRunDisplay.symbol(run.phase)).frame(width: 16).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(run.goal).font(.body).lineLimit(2).foregroundStyle(.primary)
                    Text(TaskRunDisplay.status(run.phase)).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .ivyGlass(cornerRadius: 10, interactive: true, enabled: selected)
        }
        .buttonStyle(IvyNavigationButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(run.goal)
    }

    private var conversationPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    IvyAppIconView().frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ivy").font(.system(size: 17, weight: .semibold))
                        Text("Personal assistant").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button {
                        searchVisible.toggle()
                        if !searchVisible { query = "" }
                        searchFocused = searchVisible
                    } label: {
                        Image(systemName: searchVisible ? "xmark" : "magnifyingglass")
                            .font(.system(size: 14))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(IvyNavigationButtonStyle())
                    .foregroundStyle(.secondary)
                    .help(searchVisible ? "Close search" : "Search conversations")
                    .accessibilityLabel(searchVisible ? "Close search" : "Search conversations")
                    .accessibilityIdentifier("ivy.conversationSearch")
                }
                Button { library.newConversation(); destination = .chat } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.and.pencil").font(.system(size: 16))
                        Text("New chat").font(.body.weight(.medium))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(IvyNavigationButtonStyle())
                .help("New chat (⌘N)")
                .accessibilityIdentifier("ivy.newConversation")
                if searchVisible {
                    TextField("Search conversations", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .focused($searchFocused)
                        .accessibilityIdentifier("ivy.conversationSearchField")
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 16)
            conversationList
            Divider()
            ArchivedFolder(isExpanded: $archiveExpanded) {
                let archived = library.list(.archived).filter {
                    !isSearching || $0.title.localizedStandardContains(query) || $0.preview.localizedStandardContains(query)
                }
                if archived.isEmpty {
                    Text(isSearching ? "No archived matches." : "No archived conversations.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(archived) { entry in conversationRow(entry) }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
            .padding(12)
            Divider()
            WorkspaceMenu(workspaces: workspaces, tasks: tasks)
                .padding(12)
        }
        .frame(maxWidth: .infinity)
    }

    private var conversationList: some View {
        List {
            if isSearching {
                let archivedIDs = Set(library.list(.archived).map(\.id))
                let hits = library.search(query).filter { !archivedIDs.contains($0.conversationID) }
                Section("Results") {
                    if hits.isEmpty {
                        Text("No matches.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(hits) { hit in
                        Button {
                            if library.open(hit.conversationID) { destination = .chat }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.title).lineLimit(1)
                                Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(IvyNavigationButtonStyle())
                    }
                }
            } else {
                let active = library.list(.active)
                let pinned = active.filter(\.isPinned)
                let recent = active.filter { !$0.isPinned }
                if active.isEmpty {
                    Text("Your conversations will appear here.")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                if !pinned.isEmpty {
                    Section("Pinned") {
                        ForEach(pinned) { entry in conversationRow(entry) }
                    }
                }
                if !recent.isEmpty {
                    Section("Recents") {
                        ForEach(recent) { entry in conversationRow(entry) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6))
    }

    private func conversationRow(_ entry: ConversationSummary) -> some View {
        HStack(spacing: 2) {
            Button {
                if library.open(entry.id) { destination = .chat }
            } label: {
                Text(entry.title)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(IvyNavigationButtonStyle())
            .accessibilityLabel("\(entry.isPinned ? "Pinned. " : "")\(entry.title)")
            .accessibilityAddTraits(destination == .chat && entry.id == library.activeConversationID ? .isSelected : [])
            .help("\(entry.title)\n\(entry.updatedAt.formatted(date: .abbreviated, time: .shortened))\n\(entry.preview)")
            Menu { menu(for: entry) } label: {
                Image(systemName: "ellipsis").frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.secondary)
            .fixedSize()
            .accessibilityLabel("Actions for \(entry.title)")
        }
        .padding(.horizontal, 8)
        .ivyGlass(cornerRadius: 10, interactive: true,
                  enabled: destination == .chat && entry.id == library.activeConversationID)
        .contextMenu { menu(for: entry) }
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

/// The folder header stays visible; its conversations appear only after an explicit click.
struct ArchivedFolder<Content: View>: View {
    @Binding var isExpanded: Bool
    let content: Content

    init(isExpanded: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self._isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Label("Archived", systemImage: "archivebox")
                    Spacer(minLength: 0)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Archived")
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint("Show or hide archived conversations")
            .accessibilityIdentifier("ivy.archive.toggle")
            if isExpanded { content }
        }
    }
}
