import SwiftUI
import IvyCore

enum WorkspaceDestination: String, CaseIterable, Identifiable {
    case home = "Home", chat = "Chat", library = "Library", tasks = "Tasks"
    /// Chat is entered through New chat or a saved conversation, without a duplicate rail button.
    static var railDestinations: [Self] { [.home, .library, .tasks] }
    var id: String { rawValue.lowercased() }

    var symbol: String {
        switch self {
        case .home: "house"
        case .chat: "bubble.left"
        case .library: "books.vertical"
        case .tasks: "checklist"
        }
    }

    var detail: String {
        switch self {
        case .home: "Your workspace for everyday Mac tasks."
        case .chat: "A conversation with Ivy."
        case .library: "Your saved conversations and task reports."
        case .tasks: "Plan a task and review its real progress."
        }
    }

    var shortcuts: [HomeShortcut] {
        switch self {
        case .home: HomeShortcut.allCases
        case .chat, .library: []
        case .tasks: [.plan]
        }
    }
}

struct IvyNavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}
