import Foundation
import Combine

/// Builds Ivy's object graph in a fixed, side-effect-free order and owns clean shutdown.
/// Launch never starts the microphone, Gemini Live, speech, or any tool.
@MainActor
public final class IvyAppEnvironment {
    public let settings: SettingsModel
    public let credentials: CredentialProvider
    public let conversationStore: ConversationStore
    public let brain: IvyBrain
    public let voiceManager: VoicePlaybackManager
    public let liveCoordinator: GeminiLiveVoiceCoordinator
    /// Why push-to-talk isn't available, if registration failed (shown in the UI; no secrets).
    public private(set) var hotkeyError: String? = nil

    private var settingsSubscription: AnyCancellable?

    public init(
        settingsStore: SettingsStore,
        credentials: CredentialProvider,
        conversationStore: ConversationStore,
        geminiClient: GeminiClientProtocol = URLSessionGeminiClient(),
        voiceManager: VoicePlaybackManager? = nil,
        makeLiveCoordinator: (CredentialProvider, IvySettings) -> GeminiLiveVoiceCoordinator
    ) {
        // 1. Settings  2. Credentials
        let settings = SettingsModel(store: settingsStore)
        self.settings = settings
        self.credentials = credentials
        self.conversationStore = conversationStore

        // 3. Conversation state
        let brain = IvyBrain(client: geminiClient, credentials: credentials, conversationStore: conversationStore)
        brain.persistsHistory = settings.settings.persistConversationHistory
        if settings.settings.restoreLastConversation {
            brain.restoreLatestConversation()
        }
        self.brain = brain

        // 4/5. Voice + Live infrastructure, created idle.
        self.voiceManager = voiceManager ?? VoicePlaybackManager(credentials: credentials)
        self.liveCoordinator = makeLiveCoordinator(credentials, settings.settings)

        if settings.settings.pushToTalkEnabled {
            do {
                try liveCoordinator.registerHotkey()
            } catch {
                hotkeyError = error.localizedDescription
                print("[HOTKEY] push-to-talk unavailable: \(error.localizedDescription)")
            }
        }

        settingsSubscription = settings.$settings.sink { [weak brain] new in
            brain?.persistsHistory = new.persistConversationHistory
        }
    }

    /// The production graph: Keychain credentials (environment fallback), UserDefaults settings, on-disk history.
    public static func production() -> IvyAppEnvironment {
        IvyAppEnvironment(
            settingsStore: UserDefaultsSettingsStore(),
            credentials: KeychainCredentialProvider(),
            conversationStore: FileConversationStore()
        ) { credentials, settings in
            GeminiLiveVoiceCoordinator(
                credentials: credentials,
                echoCancellation: settings.echoCancellation,
                hotkeyManager: SystemGlobalHotkeyManager()
            )
        }
    }

    /// Quit path: denies any pending approval, saves the conversation, stops playback, and tears down
    /// Live (mic tap, socket, audio queue, hotkey) so nothing stale survives into the next launch.
    public func shutdown() async {
        brain.prepareForTermination()
        voiceManager.stop()
        await liveCoordinator.shutdown()
    }
}
