import SwiftUI
import IvyCore

/// The popover's conversation list: search, switch, and organise saved conversations.
struct ConversationsPanel: View {
    @ObservedObject var library: ConversationLibrary
    /// Called after a conversation is opened or created, with the message to scroll to (search hits).
    let onOpen: (UUID?) -> Void

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
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search conversations", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search conversations")
                Button {
                    library.newConversation()
                    onOpen(nil)
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .help("New Conversation")
                .accessibilityLabel("New conversation")
                .keyboardShortcut("n", modifiers: [.command])
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if let error = library.lastError {
                HStack {
                    Text(error).font(.system(size: 11)).foregroundStyle(.orange)
                    Spacer()
                    Button("Dismiss") { library.dismissError() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    if isSearching {
                        let hits = library.search(query)
                        if hits.isEmpty { placeholder("No matches.") }
                        ForEach(hits) { hit in
                            row(title: hit.title, detail: hit.snippet, date: hit.updatedAt, pinned: false, active: false) {
                                if library.open(hit.conversationID) { onOpen(hit.messageID) }
                            }
                        }
                    } else {
                        let shown = library.list(showArchived ? .archived : .active)
                        if shown.isEmpty { placeholder(showArchived ? "Nothing archived." : "No saved conversations yet.") }
                        ForEach(shown) { entry in
                            row(title: entry.title, detail: entry.preview, date: entry.updatedAt, pinned: entry.isPinned,
                                active: entry.id == library.activeConversationID) {
                                if library.open(entry.id) { onOpen(nil) }
                            }
                            .contextMenu { menu(for: entry) }
                        }
                    }
                }
            }

            Divider()
            Toggle("Show archived", isOn: $showArchived)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .onAppear { library.refresh() }
        .alert("Rename Conversation", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                if let renaming { library.rename(renaming.id, to: newTitle) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
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

    @ViewBuilder
    private func menu(for entry: ConversationSummary) -> some View {
        Button("Rename…") {
            newTitle = entry.title
            renaming = entry
        }
        Button(entry.isPinned ? "Unpin" : "Pin") { library.setPinned(entry.id, !entry.isPinned) }
        Button(entry.isArchived ? "Unarchive" : "Archive") { library.setArchived(entry.id, !entry.isArchived) }
        Divider()
        Button("Export as Markdown…") { export(entry, .markdown) }
        Button("Export as JSON…") { export(entry, .json) }
        Divider()
        Button("Delete…", role: .destructive) { deleting = entry }
    }

    private func row(title: String, detail: String, date: Date, pinned: Bool, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if pinned {
                        Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    Text(title).font(.system(size: 12, weight: active ? .semibold : .regular)).lineLimit(1)
                    Spacer()
                    Text(date.formatted(.relative(presentation: .named))).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(pinned ? "Pinned. " : "")\(title)\(active ? ", current conversation" : "")")
        .accessibilityHint("Opens this conversation")
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, 40)
    }

    /// The user picks where the file goes; the export itself is already redacted.
    private func export(_ entry: ConversationSummary, _ format: ConversationExporter.Format) {
        ConversationFileExport.run(library, id: entry.id, title: entry.title, format: format)
    }
}
