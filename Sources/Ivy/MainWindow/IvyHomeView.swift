import SwiftUI
import IvyCore

/// The Home dashboard shows real conversations and task state. Every shortcut drafts a prompt.
struct IvyHomeView: View {
    @ObservedObject var library: ConversationLibrary
    @ObservedObject var brain: IvyBrain
    @ObservedObject var tasks: TaskEngine
    let onPrompt: (String) -> Void
    let onOpenConversation: () -> Void
    let onCapture: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                Text("Start something").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 14)], spacing: 14) {
                    ForEach(HomeShortcut.allCases) { shortcut in
                        Button { onPrompt(shortcut.prompt) } label: {
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: shortcut.symbol).font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(IvyTheme.moss).frame(width: 38, height: 38)
                                    .background(IvyTheme.moss.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(shortcut.rawValue).font(.body.weight(.semibold)).lineLimit(1)
                                    Text(shortcut.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                                    .accessibilityHidden(true)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                            .padding(16)
                            .ivyGlass(cornerRadius: IvyTheme.cardRadius, interactive: true)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(IvyNavigationButtonStyle())
                        .disabled(brain.isThinking || brain.pendingConfirmation != nil || tasks.run?.isActive == true)
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        taskPanel.frame(minWidth: 260)
                        recentPanel.frame(minWidth: 260)
                    }
                    VStack(spacing: 18) { taskPanel; recentPanel }
                }
            }
            .padding(28)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity, alignment: .top)
            .ivyGlassGroup()
        }
        .ivyGlassButtonStyle()
        .accessibilityIdentifier("ivy.home")
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                IvyAppIconView().frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ivy").font(.title3.weight(.semibold))
                    Text("Your personal assistant").font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            introduction
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What can I help with?")
                .font(.system(size: 26, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Plan tasks, work with files, and get answers on your Mac.")
                .font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: brain.isGeminiKeyConfigured ? "checkmark.circle.fill" : "key")
                Text(brain.isGeminiKeyConfigured ? "Connected and ready" : "Connect Gemini to get started")
            }
            .font(.callout).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(IvyTheme.moss.opacity(0.08), in: Capsule())
            if !brain.isGeminiKeyConfigured {
                SettingsLink { Text("Connect Gemini") }.ivyGlassButtonStyle(prominent: true)
            }
        }
    }

    private var taskPanel: some View {
        SettingsCard(title: "Current task", symbol: "checklist") {
            if tasks.run != nil {
                TaskCardView(engine: tasks, showsSurface: false)
            } else {
                Text("No active task. Tasks you start will appear here.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button { onPrompt("/agent ") } label: { Label("Plan a task", systemImage: "plus") }
                    .ivyGlassButtonStyle()
                Button(action: onCapture) { Label("Show Ivy your screen", systemImage: "viewfinder") }
                    .ivyGlassButtonStyle()
            }
        }
    }

    private var recentPanel: some View {
        SettingsCard(title: "Recent conversations", symbol: "clock") {
            let recent = Array(library.list(.active).prefix(4))
            if recent.isEmpty {
                Text("Your conversations will appear here.").foregroundStyle(.secondary)
            }
            ForEach(recent) { conversation in
                Button {
                    if library.open(conversation.id) { onOpenConversation() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bubble.left").foregroundStyle(IvyTheme.moss)
                        Text(conversation.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(IvyNavigationButtonStyle())
            }
        }
    }
}

enum HomeShortcut: String, CaseIterable, Identifiable {
    case browse = "Research", summarize = "Summarize"
    case write = "Write", files = "Files", explain = "Explain", plan = "Plan a task"
    var id: Self { self }
    var symbol: String {
        switch self {
        case .browse: "globe"
        case .summarize: "doc.text"
        case .write: "pencil"
        case .files: "folder"
        case .explain: "lightbulb"
        case .plan: "checklist"
        }
    }
    var detail: String {
        switch self {
        case .browse: "Research a question"
        case .summarize: "Make the key points clear"
        case .write: "Emails, docs, ideas"
        case .files: "Find and organize"
        case .explain: "Untangle something tricky"
        case .plan: "Turn an idea into steps"
        }
    }
    var prompt: String {
        switch self {
        case .browse: "Research this question: "
        case .summarize: "Summarize this: "
        case .write: "Help me write: "
        case .files: "Help me find and organize these files: "
        case .explain: "Explain this to me: "
        case .plan: "/agent "
        }
    }
}
