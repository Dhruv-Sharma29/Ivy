import SwiftUI
import IvyCore

/// A browsable collection of the content Ivy actually persists.
struct LibraryWorkspaceView: View {
    @ObservedObject var library: ConversationLibrary
    @ObservedObject var tasks: TaskEngine
    let blocked: Bool
    let onOpenConversation: () -> Void
    let onOpenTask: (UUID) -> Void
    let onPrompt: (String) -> Void
    @State private var query = ""
    @State private var category: LibraryCategory
    @State private var layout: LibraryLayout
    @State private var sort: LibrarySort = .newest

    init(library: ConversationLibrary, tasks: TaskEngine, blocked: Bool,
         category: LibraryCategory = .all, layout: LibraryLayout = .grid,
         onOpenConversation: @escaping () -> Void, onOpenTask: @escaping (UUID) -> Void,
         onPrompt: @escaping (String) -> Void) {
        self.library = library
        self.tasks = tasks
        self.blocked = blocked
        self.onOpenConversation = onOpenConversation
        self.onOpenTask = onOpenTask
        self.onPrompt = onPrompt
        _category = State(initialValue: category)
        _layout = State(initialValue: layout)
    }

    private var items: [LibraryItem] {
        WorkspaceLibraryCatalog.items(conversations: library.entries, tasks: tasks.history,
                                      category: category, query: query, sort: sort)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { title; Spacer(); tools }
                    VStack(alignment: .leading, spacing: 16) { title; tools }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(LibraryCategory.allCases) { filter in
                            Button { category = filter } label: {
                                Text(filter.rawValue).font(.callout.weight(category == filter ? .semibold : .regular))
                                    .padding(.horizontal, 14).frame(minHeight: 34)
                                    .foregroundStyle(category == filter ? Color.primary : Color.secondary)
                                    .contentShape(Capsule())
                                    .ivyGlass(cornerRadius: 17, interactive: true, enabled: category == filter)
                            }
                            .buttonStyle(IvyNavigationButtonStyle())
                            .accessibilityAddTraits(category == filter ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 4)
                }
                if items.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "Nothing here yet" : "No matches",
                        systemImage: query.isEmpty ? "books.vertical" : "magnifyingglass",
                        description: Text(query.isEmpty ? "Saved conversations and completed task reports appear in your Library." : "Try a different search or category."))
                        .frame(maxWidth: .infinity, minHeight: 240)
                } else if layout == .grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                        ForEach(items) { item in libraryCard(item, compact: false) }
                    }
                } else {
                    LazyVStack(spacing: 10) {
                        ForEach(items) { item in libraryCard(item, compact: true) }
                    }
                }
                Text("\(items.count) \(items.count == 1 ? "item" : "items")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .ivyGlassGroup()
        .onAppear { library.refresh() }
        .accessibilityIdentifier("ivy.workspace.library")
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Library").font(.largeTitle.weight(.semibold))
            Text("Your conversations and task reports.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var tools: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { search; displayTools }
            VStack(alignment: .leading, spacing: 10) { search; displayTools }
        }
    }

    private var search: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search library", text: $query).textFieldStyle(.plain)
                .accessibilityIdentifier("ivy.library.search")
        }
        .padding(.horizontal, 12).frame(minWidth: 150, idealWidth: 220, maxWidth: 280, minHeight: 34)
        .ivyGlass(cornerRadius: 17)
    }

    private var displayTools: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $layout) {
                Image(systemName: "square.grid.2x2").tag(LibraryLayout.grid).accessibilityLabel("Grid view")
                Image(systemName: "list.bullet").tag(LibraryLayout.list).accessibilityLabel("List view")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 68).help("Grid or list view")
            Menu {
                Picker("Sort by", selection: $sort) {
                    ForEach(LibrarySort.allCases) { order in Text(order.rawValue).tag(order) }
                }
            } label: { Image(systemName: "line.3.horizontal.decrease").frame(width: 28, height: 28) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 28, height: 28)
            .ivyGlass(cornerRadius: 14, interactive: true)
            .accessibilityLabel("Sort library").help("Sort library")
            Menu {
                Button("Conversation", systemImage: "bubble.left") {
                    library.newConversation(); onOpenConversation()
                }
                Button("Task", systemImage: "checklist") { onPrompt("/agent ") }.disabled(blocked)
            } label: { Label("New", systemImage: "plus") }
            .ivyGlassButtonStyle()
        }
    }

    private func libraryCard(_ item: LibraryItem, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            Button { open(item) } label: {
                Group {
                    if compact {
                        HStack(spacing: 14) {
                            Image(systemName: item.symbol).font(.system(size: 22)).foregroundStyle(IvyTheme.moss).frame(width: 32)
                            cardText(item)
                            Spacer(minLength: 0)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading).frame(height: 36, alignment: .topLeading)
                            Image(systemName: item.symbol).font(.system(size: 26)).foregroundStyle(IvyTheme.moss)
                                .frame(width: 48, height: 48)
                                .background(IvyTheme.moss.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                                .frame(maxWidth: .infinity, minHeight: 54).accessibilityHidden(true)
                            Text(item.detail).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 158, alignment: .top)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(IvyNavigationButtonStyle())
            .foregroundStyle(.primary)
            .help(item.title)
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.kind).fontWeight(.medium)
                    Text(item.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                }
                .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Menu { actions(item) } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .tint(.secondary).accessibilityLabel("Actions for \(item.title)")
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .ivyGlass(cornerRadius: IvyTheme.cardRadius, interactive: true)
    }

    private func cardText(_ item: LibraryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.body.weight(.medium)).lineLimit(1)
            Text(item.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func open(_ item: LibraryItem) {
        switch item {
        case .conversation(let entry): if library.open(entry.id) { onOpenConversation() }
        case .report(let run): onOpenTask(run.id)
        }
    }

    @ViewBuilder private func actions(_ item: LibraryItem) -> some View {
        switch item {
        case .conversation(let entry):
            Button(entry.isPinned ? "Unpin" : "Pin") { library.setPinned(entry.id, !entry.isPinned) }
            Button(entry.isArchived ? "Unarchive" : "Archive") { library.setArchived(entry.id, !entry.isArchived) }
            Divider()
            Button("Export as Markdown…") { ConversationFileExport.run(library, id: entry.id, title: entry.title, format: .markdown) }
            Button("Export as JSON…") { ConversationFileExport.run(library, id: entry.id, title: entry.title, format: .json) }
        case .report(let run):
            Button("Open task") { onOpenTask(run.id) }
            Button("Plan again") { onPrompt("/agent " + run.goal) }.disabled(blocked)
        }
    }
}
