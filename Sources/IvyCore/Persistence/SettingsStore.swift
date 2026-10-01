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
    /// Add what was said in Live voice sessions to the conversation as text. No audio is ever stored.
    public var saveVoiceTranscripts: Bool
    /// Let Ivy name new conversations. Costs one extra Gemini request per conversation.
    public var autoTitleConversations: Bool
    /// How long a pause Ivy waits through before answering in Live. Applies at launch.
    public var voicePatience: VoicePatience
    /// Spoken-style hints for Live (the voice itself is always Kore). Apply at launch.
    public var voiceResponseLength: VoiceResponseLength
    public var voiceSpeakingPace: VoiceSpeakingPace
    /// ElevenLabs read-aloud voice settings.
    public var ttsSpeed: Double
    public var ttsStability: Double
    public var ttsStyle: Double
    /// Stop listening for "Hey Ivy" while the screen is locked.
    public var pauseWakeWordWhenLocked: Bool
    /// Experimental: a lone "Ivy" (no "hey") interrupts while you are audibly speaking.
    public var loneIvyBargeIn: Bool
    /// Master switch for everything Ivy does on its own initiative. Off unless the user turns it on.
    public var proactiveEnabled: Bool
    /// Reminders, follow-ups and "tell me when…" watches.
    public var proactiveReminders: Bool
    /// Heads-up before calendar events (only calendars named in `headsUpCalendars`).
    public var proactiveCalendar: Bool
    public var proactiveBriefing: Bool
    /// No notifications during quiet hours; they are held for one digest afterwards.
    public var quietHoursEnabled: Bool
    /// Minutes after midnight, local time.
    public var quietStartMinutes: Int
    public var quietEndMinutes: Int
    public var briefingMinutes: Int
    public var headsUpMinutes: Int
    public var headsUpCalendars: [String]
    public var launchAtLogin: Bool
    /// Keep the Dock icon even when no Ivy window is open (otherwise Ivy is menu-bar only until a window opens).
    public var alwaysShowInDock: Bool
    /// Vision (Phase 14): send recognised text only, never pixels.
    public var visionTextOnly: Bool
    /// Black out key/token-looking text in images before they are sent.
    public var visionMaskSecrets: Bool
    /// Let saved history keep the text recognised in an image (never the image).
    public var visionKeepTextFromImages: Bool
    /// Screen capture refuses while one of these apps is frontmost.
    public var visionExcludedApps: [String]
    /// Register the "What am I looking at?" hotkey (⌃⌥⌘S) at launch.
    public var screenHelpHotkeyEnabled: Bool
    /// The on-screen companion (Phase 17b): appears while Ivy is listening, speaking, working or needs approval.
    public var companionEnabled: Bool
    /// Keep the companion on screen when nothing is happening.
    public var companionShowWhileIdle: Bool
    public var companionCorner: CompanionCorner
    /// Register the command bar hotkey (⌃⌥⌘K) at launch.
    public var commandBarHotkeyEnabled: Bool
    /// The first-run introduction has been finished or skipped (Phase 17c). Existing users are marked done.
    public var onboardingCompleted: Bool

    public var visionPolicy: VisionPolicy {
        VisionPolicy(textOnly: visionTextOnly, maskSecrets: visionMaskSecrets,
                     keepTextInHistory: visionKeepTextFromImages, excludedApps: visionExcludedApps)
    }

    public var ttsVoiceSettings: ElevenLabsVoiceSettings {
        ElevenLabsVoiceSettings(speed: ttsSpeed, stability: ttsStability, style: ttsStyle)
    }

    public static let defaults = IvySettings(
        persistConversationHistory: true,
        restoreLastConversation: true,
        echoCancellation: true,
        pushToTalkEnabled: true,
        showLiveTranscript: true,
        wakeWordEnabled: false,
        saveVoiceTranscripts: true,
        autoTitleConversations: true
    )

    public init(
        persistConversationHistory: Bool,
        restoreLastConversation: Bool,
        echoCancellation: Bool,
        pushToTalkEnabled: Bool,
        showLiveTranscript: Bool,
        wakeWordEnabled: Bool = false,
        saveVoiceTranscripts: Bool = true,
        autoTitleConversations: Bool = true,
        voicePatience: VoicePatience = .normal,
        voiceResponseLength: VoiceResponseLength = .normal,
        voiceSpeakingPace: VoiceSpeakingPace = .normal,
        ttsSpeed: Double = ElevenLabsVoiceSettings.defaultSpeed,
        ttsStability: Double = ElevenLabsVoiceSettings.defaultStability,
        ttsStyle: Double = ElevenLabsVoiceSettings.defaultStyle,
        pauseWakeWordWhenLocked: Bool = true,
        loneIvyBargeIn: Bool = false,
        proactiveEnabled: Bool = false,
        proactiveReminders: Bool = true,
        proactiveCalendar: Bool = false,
        proactiveBriefing: Bool = false,
        quietHoursEnabled: Bool = true,
        quietStartMinutes: Int = 22 * 60,
        quietEndMinutes: Int = 8 * 60,
        briefingMinutes: Int = 8 * 60 + 30,
        headsUpMinutes: Int = 10,
        headsUpCalendars: [String] = [],
        launchAtLogin: Bool = false,
        alwaysShowInDock: Bool = false,
        visionTextOnly: Bool = false,
        visionMaskSecrets: Bool = true,
        visionKeepTextFromImages: Bool = false,
        visionExcludedApps: [String] = VisionPolicy.defaultExcludedApps,
        screenHelpHotkeyEnabled: Bool = true,
        companionEnabled: Bool = true,
        companionShowWhileIdle: Bool = false,
        companionCorner: CompanionCorner = .bottomRight,
        commandBarHotkeyEnabled: Bool = true,
        onboardingCompleted: Bool = false
    ) {
        self.persistConversationHistory = persistConversationHistory
        self.restoreLastConversation = restoreLastConversation
        self.echoCancellation = echoCancellation
        self.pushToTalkEnabled = pushToTalkEnabled
        self.showLiveTranscript = showLiveTranscript
        self.wakeWordEnabled = wakeWordEnabled
        self.saveVoiceTranscripts = saveVoiceTranscripts
        self.autoTitleConversations = autoTitleConversations
        self.voicePatience = voicePatience
        self.voiceResponseLength = voiceResponseLength
        self.voiceSpeakingPace = voiceSpeakingPace
        self.ttsSpeed = ttsSpeed
        self.ttsStability = ttsStability
        self.ttsStyle = ttsStyle
        self.pauseWakeWordWhenLocked = pauseWakeWordWhenLocked
        self.loneIvyBargeIn = loneIvyBargeIn
        self.proactiveEnabled = proactiveEnabled
        self.proactiveReminders = proactiveReminders
        self.proactiveCalendar = proactiveCalendar
        self.proactiveBriefing = proactiveBriefing
        self.quietHoursEnabled = quietHoursEnabled
        self.quietStartMinutes = quietStartMinutes
        self.quietEndMinutes = quietEndMinutes
        self.briefingMinutes = briefingMinutes
        self.headsUpMinutes = headsUpMinutes
        self.headsUpCalendars = headsUpCalendars
        self.launchAtLogin = launchAtLogin
        self.alwaysShowInDock = alwaysShowInDock
        self.visionTextOnly = visionTextOnly
        self.visionMaskSecrets = visionMaskSecrets
        self.visionKeepTextFromImages = visionKeepTextFromImages
        self.visionExcludedApps = visionExcludedApps
        self.screenHelpHotkeyEnabled = screenHelpHotkeyEnabled
        self.companionEnabled = companionEnabled
        self.companionShowWhileIdle = companionShowWhileIdle
        self.companionCorner = companionCorner
        self.commandBarHotkeyEnabled = commandBarHotkeyEnabled
        self.onboardingCompleted = onboardingCompleted
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
        saveVoiceTranscripts = value(.saveVoiceTranscripts, d.saveVoiceTranscripts)
        autoTitleConversations = value(.autoTitleConversations, d.autoTitleConversations)
        func other<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        voicePatience = other(.voicePatience, d.voicePatience)
        voiceResponseLength = other(.voiceResponseLength, d.voiceResponseLength)
        voiceSpeakingPace = other(.voiceSpeakingPace, d.voiceSpeakingPace)
        ttsSpeed = other(.ttsSpeed, d.ttsSpeed)
        ttsStability = other(.ttsStability, d.ttsStability)
        ttsStyle = other(.ttsStyle, d.ttsStyle)
        pauseWakeWordWhenLocked = value(.pauseWakeWordWhenLocked, d.pauseWakeWordWhenLocked)
        loneIvyBargeIn = value(.loneIvyBargeIn, d.loneIvyBargeIn)
        proactiveEnabled = value(.proactiveEnabled, d.proactiveEnabled)
        proactiveReminders = value(.proactiveReminders, d.proactiveReminders)
        proactiveCalendar = value(.proactiveCalendar, d.proactiveCalendar)
        proactiveBriefing = value(.proactiveBriefing, d.proactiveBriefing)
        quietHoursEnabled = value(.quietHoursEnabled, d.quietHoursEnabled)
        func minutes(_ key: CodingKeys, _ fallback: Int) -> Int {
            let stored: Int = other(key, fallback)
            return (0..<1440).contains(stored) ? stored : fallback
        }
        quietStartMinutes = minutes(.quietStartMinutes, d.quietStartMinutes)
        quietEndMinutes = minutes(.quietEndMinutes, d.quietEndMinutes)
        briefingMinutes = minutes(.briefingMinutes, d.briefingMinutes)
        headsUpMinutes = min(120, max(1, other(.headsUpMinutes, d.headsUpMinutes)))
        headsUpCalendars = other(.headsUpCalendars, d.headsUpCalendars)
        launchAtLogin = value(.launchAtLogin, d.launchAtLogin)
        alwaysShowInDock = value(.alwaysShowInDock, d.alwaysShowInDock)
        visionTextOnly = value(.visionTextOnly, d.visionTextOnly)
        visionMaskSecrets = value(.visionMaskSecrets, d.visionMaskSecrets)
        visionKeepTextFromImages = value(.visionKeepTextFromImages, d.visionKeepTextFromImages)
        visionExcludedApps = other(.visionExcludedApps, d.visionExcludedApps)
        screenHelpHotkeyEnabled = value(.screenHelpHotkeyEnabled, d.screenHelpHotkeyEnabled)
        companionEnabled = value(.companionEnabled, d.companionEnabled)
        companionShowWhileIdle = value(.companionShowWhileIdle, d.companionShowWhileIdle)
        companionCorner = other(.companionCorner, d.companionCorner)
        commandBarHotkeyEnabled = value(.commandBarHotkeyEnabled, d.commandBarHotkeyEnabled)
        onboardingCompleted = value(.onboardingCompleted, d.onboardingCompleted)
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
