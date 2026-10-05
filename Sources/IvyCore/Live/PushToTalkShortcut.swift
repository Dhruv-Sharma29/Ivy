import Combine
import Foundation

/// Explicit alternatives for the global voice shortcut; neither captures the screen.
public enum PushToTalkShortcut: String, Codable, CaseIterable, Sendable {
    case commandShiftSpace, controlOptionCommandSpace

    public var label: String {
        switch self {
        case .commandShiftSpace: "⌘⇧Space"
        case .controlOptionCommandSpace: "⌃⌥⌘Space"
        }
    }

    public var hotkey: HotkeyShortcut {
        switch self {
        case .commandShiftSpace: .defaultPushToTalk
        case .controlOptionCommandSpace: HotkeyShortcut(keyCode: 49, modifiers: [.control, .option, .command])
        }
    }
}

/// Registration feedback is separate from voice state: registration never opens the microphone.
@MainActor
public final class PushToTalkShortcutStatus: ObservableObject {
    @Published public internal(set) var error: String?
    public init() {}
}
