import SwiftUI
import IvyCore

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case home = "Home", chat = "Chat", tasks = "Tasks"
    var id: String { rawValue.lowercased() }

    var symbol: String {
        switch self {
        case .home: "house"
        case .chat: "bubble.left"
        case .tasks: "checklist"
        }
    }

    var detail: String {
        switch self {
        case .home: "Your workspace for everyday Mac tasks."
        case .chat: "A conversation with Ivy."
        case .tasks: "Plan a task and review its real progress."
        }
    }

    var shortcuts: [HomeShortcut] {
        switch self {
        case .home: HomeShortcut.allCases
        case .chat: []
        case .tasks: [.plan]
        }
    }
}

/// Destinations reuse Ivy's composer, attachment tray and task engine. Actions draft, never auto-send.
struct WorkspacePage: View {
    let destination: WorkspaceDestination
    @ObservedObject var tasks: TaskEngine
    let blocked: Bool
    let onPrompt: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Label(destination.rawValue, systemImage: destination.symbol)
                        .font(.largeTitle.weight(.semibold))
                    Text(destination.detail).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if destination == .tasks, tasks.run != nil {
                    SettingsCard(title: "Current task", symbol: "checklist") { TaskCardView(engine: tasks, showsSurface: false) }
                }
                SettingsCard(title: destination == .tasks ? "Start a task" : "Start here", symbol: destination.symbol) {
                    ForEach(destination.shortcuts) { shortcut in
                        Button { onPrompt(shortcut.prompt) } label: {
                            HStack(spacing: 14) {
                                Image(systemName: shortcut.symbol).frame(width: 24).foregroundStyle(IvyTheme.moss)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(shortcut.rawValue).font(.body.weight(.medium))
                                    Text(shortcut.detail).font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                            }
                            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(IvyNavigationButtonStyle())
                        .disabled(blocked)
                    }
                }
                Text("Review your message before sending. Ivy asks before making risky changes.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 800, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("ivy.workspace.\(destination.id)")
    }
}

struct IvyNavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}
