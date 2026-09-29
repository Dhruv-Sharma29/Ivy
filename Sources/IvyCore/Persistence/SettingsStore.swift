import Foundation
import Combine

/// Non-secret user preferences. Credentials never go here — they live in the Keychain.
public struct IvySettings: Codable, Equatable, Sendable {
    /// Save conversations to disk so they survive a restart.
    public var persistConversationHistory: Bool
    /// On launch, reopen the most recent saved conversation.
    public var restoreLastConversation: Bool
    /// Echo cancellation for Live, so "Hey Ivy" is heard over Ivy's own voice on speakers. Applies at launch.
    public var echoCancellation: Bool
    /// Register the global push-to-talk shortcut at launch.
    public var pushToTalkEnabled: Bool
    /// Show the live transcript line in the voice bar.
    public var showLiveTranscript: Bool
    /// "Hey Ivy" wakes Ivy while idle (like "Hey Siri"). Keeps the mic open with on-device recognition, so opt-in.
    public var wakeWordEnabled: Bool

    public static let defaults = IvySettings(
        persistConversationHistory: true,
        restoreLastConversation: true,
        echoCancellation: true,
        pushToTalkEnabled: true,
        showLiveTranscript: true,
        wakeWordEnabled: false
    )

    public init(
        persistConversationHistory: Bool,
        restoreLastConversation: Bool,
        echoCancellation: Bool,
        pushToTalkEnabled: Bool,
        showLiveTranscript: Bool,
        wakeWordEnabled: Bool = false
    ) {
        self.persistConversationHistory = persistConversationHistory
        self.restoreLastConversation = restoreLastConversation
        self.echoCancellation = echoCancellation
        self.pushToTalkEnabled = pushToTalkEnabled
        self.showLiveTranscript = showLiveTranscript
        self.wakeWordEnabled = wakeWordEnabled
    }

    /// Missing or wrongly-typed fields fall back to their defaults individually, so an older or
    /// partially corrupt blob never throws away the settings that are still valid.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = IvySettings.defaults
        func value(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? fallback
        }
        persistConversationHistory = value(.persistConversationHistory, d.persistConversationHistory)
        restoreLastConversation = value(.restoreLastConversation, d.restoreLastConversation)
        echoCancellation = value(.echoCancellation, d.echoCancellation)
        pushToTalkEnabled = value(.pushToTalkEnabled, d.pushToTalkEnabled)
        showLiveTranscript = value(.showLiveTranscript, d.showLiveTranscript)
        wakeWordEnabled = value(.wakeWordEnabled, d.wakeWordEnabled)
    }
}

public protocol SettingsStore: Sendable {
    /// Never throws: missing or unreadable settings recover to defaults.
    func load() -> IvySettings
    func save(_ settings: IvySettings) throws
}

/// Settings as one JSON blob in UserDefaults.
public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    public static let storageKey = "ivy.settings.v1"
    // UserDefaults is documented thread-safe; it is only read/written through its own API here.
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> IvySettings {
        guard let raw = defaults.object(forKey: Self.storageKey) else { return .defaults }
        guard let data = raw as? Data else {
            print("[SETTINGS] stored settings have an unexpected type; using defaults")
            return .defaults
        }
        do {
            return try JSONDecoder().decode(IvySettings.self, from: data)
        } catch {
            print("[SETTINGS] stored settings are unreadable; using defaults")
            return .defaults
        }
    }

    public func save(_ settings: IvySettings) throws {
        defaults.set(try JSONEncoder().encode(settings), forKey: Self.storageKey)
    }
}

/// Observable settings for the UI; every change is persisted immediately.
@MainActor
public final class SettingsModel: ObservableObject {
    @Published public var settings: IvySettings {
        didSet {
            guard settings != oldValue else { return }
            do {
                try store.save(settings)
            } catch {
                print("[SETTINGS] failed to save settings: \(error.localizedDescription)")
            }
        }
    }

    private let store: SettingsStore

    public init(store: SettingsStore = UserDefaultsSettingsStore()) {
        self.store = store
        self.settings = store.load()
    }
}
