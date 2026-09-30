import Foundation
import Combine
import AppKit
import os

/// Things the Mac does that voice features must react to.
public enum SystemEvent: Sendable {
    case willSleep, didWake, screenLocked, screenUnlocked
    /// The clock was set or the time zone changed.
    case clockChanged
}

/// Builds Ivy's object graph in a fixed, side-effect-free order and owns clean shutdown.
/// Launch never starts the microphone, Gemini Live, speech, or any tool.
@MainActor
public final class IvyAppEnvironment {
    public let settings: SettingsModel
    public let credentials: CredentialProvider
    public let conversationStore: ConversationStore
    public let brain: IvyBrain
    public let library: ConversationLibrary
    /// Reminders, follow-ups, heads-ups and the briefing. Does nothing until the user turns on Proactive Ivy.
    public let proactive: ProactiveEngine
    /// Asks macOS for notification permission; run when the user turns Proactive Ivy on, never at launch.
    public var requestNotificationAccess: (() -> Void)?
    private let loginItem: LoginItemManaging?
    public let voiceManager: VoicePlaybackManager
    public let liveCoordinator: GeminiLiveVoiceCoordinator
    /// Idle "Hey Ivy" wake-up; only listens when the user has turned it on in settings.
    public let wakeWord: WakeWordController
    /// Why push-to-talk isn't available, if registration failed (shown in the UI; no secrets).
    public private(set) var hotkeyError: String? = nil

    private var settingsSubscription: AnyCancellable?
    private var systemObservers: [(NotificationCenter, NSObjectProtocol)] = []
    /// Read by the speech synthesizer off the main actor for every read-aloud request.
    private let ttsVoice: OSAllocatedUnfairLock<ElevenLabsVoiceSettings>

    public init(
        settingsStore: SettingsStore,
        credentials: CredentialProvider,
        conversationStore: ConversationStore,
        geminiClient: GeminiClientProtocol = URLSessionGeminiClient(),
        voiceManager: VoicePlaybackManager? = nil,
        wakeWordListener: WakeWordListening = SystemWakeWordListener(),
        proactiveStore: ProactiveStore = InMemoryProactiveStore(),
        proactiveDeliverer: ProactiveDelivering = UnavailableProactiveDeliverer(),
        proactiveSignals: ProactiveSignals = NoProactiveSignals(),
        proactiveRelay: ProactiveRelay = ProactiveRelay(),
        loginItem: LoginItemManaging? = nil,
        now: @escaping () -> Date = { Date() },
        makeLiveCoordinator: (CredentialProvider, IvySettings) -> GeminiLiveVoiceCoordinator
    ) {
        // 1. Settings  2. Credentials
        let settings = SettingsModel(store: settingsStore)
        self.settings = settings
        self.credentials = credentials
        self.conversationStore = conversationStore

        // 3. Conversation state
        let brain = IvyBrain(client: geminiClient, toolRegistry: Self.toolRegistry(relay: proactiveRelay),
                             credentials: credentials, conversationStore: conversationStore)
        brain.persistsHistory = settings.settings.persistConversationHistory
        brain.autoTitles = settings.settings.autoTitleConversations
        brain.savesVoiceTranscripts = settings.settings.saveVoiceTranscripts
        if settings.settings.restoreLastConversation {
            brain.restoreLatestConversation()
        }
        brain.collectStorageNotices()
        self.brain = brain
        self.library = ConversationLibrary(store: conversationStore, brain: brain)

        // Proactive Ivy: built idle. It can notify and suggest; it holds no reference to any tool dispatcher.
        let proactive = ProactiveEngine(store: proactiveStore, deliverer: proactiveDeliverer, signals: proactiveSignals,
                                        settings: { [weak settings] in settings?.settings ?? .defaults }, now: now)
        proactiveRelay.engine = proactive
        self.proactive = proactive
        self.loginItem = loginItem
        proactive.composeBriefing = { [weak brain] data in await brain?.composeBriefing(from: data) }
        proactive.onBriefing = { [weak brain] text in brain?.appendProactiveMessage(text) }
        proactive.onStopKind = { [weak settings] kind in
            switch kind {
            case .calendarHeadsUp: settings?.settings.proactiveCalendar = false
            case .briefing: settings?.settings.proactiveBriefing = false
            case .reminder, .followUp, .watch: break // these are backed by a trigger, which is removed instead
            }
        }

        // 4/5. Voice + Live infrastructure, created idle.
        let ttsVoice = OSAllocatedUnfairLock(initialState: settings.settings.ttsVoiceSettings)
        self.ttsVoice = ttsVoice
        let voice = voiceManager ?? VoicePlaybackManager(credentials: credentials, voiceSettings: { ttsVoice.withLock { $0 } })
        self.voiceManager = voice
        proactive.onRead = { [weak voice] text in voice?.togglePlayback(for: ChatMessage(role: .model, text: text)) }
        self.liveCoordinator = makeLiveCoordinator(credentials, settings.settings)
        // Voice sessions become part of the written conversation (text only).
        liveCoordinator.onTranscript = { [weak brain] text, fromUser, interrupted in
            brain?.appendVoiceTranscript(text, fromUser: fromUser, interrupted: interrupted)
        }
        liveCoordinator.onToolResult = { [weak brain] call, response in
            brain?.recordToolNote(call: call, response: response)
        }
        liveCoordinator.loneIvyInterrupts = settings.settings.loneIvyBargeIn
        // Opt-in only: with the setting off (the default) launch never opens the microphone.
        let wakeWord = WakeWordController(listener: wakeWordListener, coordinator: liveCoordinator)
        wakeWord.setEnabled(settings.settings.wakeWordEnabled)
        self.wakeWord = wakeWord

        if settings.settings.pushToTalkEnabled {
            do {
                try liveCoordinator.registerHotkey()
            } catch {
                hotkeyError = error.localizedDescription
                print("[HOTKEY] push-to-talk unavailable: \(error.localizedDescription)")
            }
        }

        var previous = settings.settings
        settingsSubscription = settings.$settings.sink { [weak self, weak brain, weak wakeWord, weak liveCoordinator] new in
            defer { previous = new }
            if new.proactiveEnabled, !previous.proactiveEnabled {
                self?.requestNotificationAccess?()
            }
            if new.launchAtLogin != previous.launchAtLogin {
                do {
                    try self?.loginItem?.setEnabled(new.launchAtLogin)
                } catch {
                    print("[LOGIN] couldn't change the login item: \(error.localizedDescription)")
                }
            }
            ttsVoice.withLock { $0 = new.ttsVoiceSettings }
            liveCoordinator?.loneIvyInterrupts = new.loneIvyBargeIn
            if !new.pauseWakeWordWhenLocked {
                wakeWord?.setSuspended(false, reason: "lock")
            }
            brain?.persistsHistory = new.persistConversationHistory
            brain?.autoTitles = new.autoTitleConversations
            brain?.savesVoiceTranscripts = new.saveVoiceTranscripts
            wakeWord?.setEnabled(new.wakeWordEnabled)
        }
    }

    /// The production graph: Keychain credentials (environment fallback), UserDefaults settings, on-disk history.
    /// The full tool catalogue plus `schedule_followup`, which reaches the proactive engine through `relay`.
    static func toolRegistry(relay: ProactiveRelay) -> ToolRegistry {
        ToolRegistry.standardRegistry().registering(ScheduleFollowUpTool(scheduler: relay))
    }

    public static func production() -> IvyAppEnvironment {
        let relay = ProactiveRelay()
        let deliverer = SystemProactiveDeliverer()
        let environment = IvyAppEnvironment(
            settingsStore: UserDefaultsSettingsStore(),
            credentials: KeychainCredentialProvider(),
            conversationStore: FileConversationStore(),
            proactiveStore: FileProactiveStore(),
            proactiveDeliverer: deliverer,
            proactiveSignals: SystemProactiveSignals(),
            proactiveRelay: relay,
            loginItem: SystemLoginItem()
        ) { credentials, settings in
            GeminiLiveVoiceCoordinator(
                credentials: credentials,
                echoCancellation: settings.echoCancellation,
                systemInstruction: LiveVoiceStyle.instruction(
                    base: IvyPersona.systemPrompt, length: settings.voiceResponseLength, pace: settings.voiceSpeakingPace),
                hotkeyManager: SystemGlobalHotkeyManager(),
                // Always on: spoken commands ("Hey Ivy, goodbye") are read from the transcript. Whether
                // transcripts are *saved* is the brain's decision (`saveVoiceTranscripts`).
                transcribesAudio: true,
                silenceDurationMs: settings.voicePatience.silenceDurationMs,
                toolRegistry: toolRegistry(relay: relay)
            )
        }
        deliverer.onAction = { [weak environment] action, trigger, kind, body in
            environment?.proactive.handle(action, triggerID: trigger, kind: kind, body: body)
        }
        deliverer.activate()
        environment.requestNotificationAccess = { Task { await deliverer.requestAuthorization() } }
        return environment
    }

    /// Sleep ends a Live session cleanly (a pending approval is denied, never executed) and releases the
    /// microphone; waking resumes "Hey Ivy" if it is enabled but never restarts a Live session by itself.
    /// A locked screen pauses "Hey Ivy" unless the user turned that off.
    public func handle(_ event: SystemEvent) async {
        switch event {
        case .willSleep:
            voiceManager.stop()
            wakeWord.setSuspended(true, reason: "sleep")
            await liveCoordinator.stopSession()
        case .didWake:
            wakeWord.setSuspended(false, reason: "sleep")
            // Anything that came due while asleep is noticed now rather than at the next timer check.
            await proactive.tick()
        case .clockChanged:
            await proactive.tick()
        case .screenLocked:
            if settings.settings.pauseWakeWordWhenLocked {
                wakeWord.setSuspended(true, reason: "lock")
            }
        case .screenUnlocked:
            wakeWord.setSuspended(false, reason: "lock")
        }
    }

    /// Subscribes to the Mac's sleep, wake and screen-lock notifications (production only; tests call `handle`).
    public func observeSystemEvents() {
        guard systemObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        let sources: [(NotificationCenter, Notification.Name, SystemEvent)] = [
            (workspace, NSWorkspace.willSleepNotification, .willSleep),
            (workspace, NSWorkspace.didWakeNotification, .didWake),
            (distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked),
            (distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked),
            (.default, .NSSystemClockDidChange, .clockChanged),
            (.default, .NSSystemTimeZoneDidChange, .clockChanged),
        ]
        proactive.start()
        for (center, name, event) in sources {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.handle(event) }
            }
            systemObservers.append((center, token))
        }
    }

    /// Quit path: denies any pending approval, saves the conversation, stops playback, and tears down
    /// Live (mic tap, socket, audio queue, hotkey) so nothing stale survives into the next launch.
    public func shutdown() async {
        brain.prepareForTermination()
        proactive.stop()
        await wakeWord.shutdown()
        voiceManager.stop()
        await liveCoordinator.shutdown()
    }
}
