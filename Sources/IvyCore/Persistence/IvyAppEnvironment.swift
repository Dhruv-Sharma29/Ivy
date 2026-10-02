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
    /// Main-window state and the Dock decision (Phase 17a).
    public let router: AppRouter
    /// Tone, profile, shortcuts and remembered preferences (Phase 13). Prompt data only.
    public let personalization: PersonalizationModel
    /// Screenshots, images and PDFs attached to the message being written (Phase 14). Memory only.
    public let attachments: AttachmentTray
    /// Multi-step tasks (Phase 15): plan → approval → one step at a time through the brain's SafetyGate.
    public let tasks: TaskEngine
    /// Project folders and the active one (Phase 16).
    public let workspaces: WorkspaceModel
    /// The first-run introduction (Phase 17c).
    public let onboarding: OnboardingModel
    /// The last screenshot Ivy was shown, for `point_at` (Phase 17b).
    public let screenGeometry: ScreenGeometryRelay
    private let commandBarHotkey: GlobalHotkeyManaging?
    /// Called on the command-bar hotkey (the app shows the panel).
    public var onCommandBar: (() -> Void)?
    private var workspaceSubscription: AnyCancellable?
    private let screenHelpHotkey: GlobalHotkeyManaging?
    /// Called after the screen-help hotkey attached a capture (the app opens the main window).
    public var onScreenHelp: (() -> Void)?
    private var personalizationSubscription: AnyCancellable?
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
        personalizationStore: PersonalizationStore = InMemoryPersonalizationStore(),
        personalizationRelay: PersonalizationRelay = PersonalizationRelay(),
        screenCapturer: ScreenContextCapturing = SystemScreenContext(),
        visionPipeline: VisionPipeline = VisionPipeline(),
        screenHelpHotkey: GlobalHotkeyManaging? = nil,
        taskPlanner: TaskPlanning? = nil,
        taskStore: TaskStore = InMemoryTaskStore(),
        workspaceStore: WorkspaceStore = InMemoryWorkspaceStore(),
        workspaceScope: WorkspaceScope = WorkspaceScope(),
        gitRunner: CommandRunning = SystemCommandRunner(),
        screenGeometry: ScreenGeometryRelay = ScreenGeometryRelay(),
        annotationPresenter: AnnotationPresenting = NoAnnotationPresenter(),
        commandBarHotkey: GlobalHotkeyManaging? = nil,
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
        let workspaces = WorkspaceModel(store: workspaceStore, scope: workspaceScope, git: gitRunner)
        self.workspaces = workspaces
        self.screenGeometry = screenGeometry
        self.commandBarHotkey = commandBarHotkey
        let brain = IvyBrain(client: geminiClient,
                             toolRegistry: Self.toolRegistry(relay: proactiveRelay, memory: personalizationRelay, workspace: workspaceScope, git: gitRunner,
                                                             geometry: screenGeometry, presenter: annotationPresenter),
                             credentials: credentials, conversationStore: conversationStore)
        let personalization = PersonalizationModel(store: personalizationStore, now: now)
        personalizationRelay.model = personalization
        self.personalization = personalization
        brain.personalization = personalization.profile
        brain.persistsHistory = settings.settings.persistConversationHistory
        brain.autoTitles = settings.settings.autoTitleConversations
        brain.savesVoiceTranscripts = settings.settings.saveVoiceTranscripts
        if settings.settings.restoreLastConversation {
            brain.restoreLatestConversation()
        }
        brain.collectStorageNotices()
        self.brain = brain
        self.library = ConversationLibrary(store: conversationStore, brain: brain)
        let router = AppRouter()
        self.router = router
        // An existing install (a key, or saved conversations) never gets the first-run introduction.
        if !settings.settings.onboardingCompleted,
           !OnboardingModel.shouldShow(settings: settings.settings, credentials: credentials, hasConversations: !conversationStore.list().isEmpty) {
            settings.settings.onboardingCompleted = true
        }
        self.onboarding = OnboardingModel(settings: settings, personalization: personalization, credentials: credentials)
        self.attachments = AttachmentTray(capturer: screenCapturer, pipeline: visionPipeline,
                                          policy: { [weak settings] in settings?.settings.visionPolicy ?? VisionPolicy() },
                                          geometry: screenGeometry)
        self.screenHelpHotkey = screenHelpHotkey
        // Same dispatcher (and so the same SafetyGate and approval cards) as chat.
        let tasks = TaskEngine(
            planner: taskPlanner ?? GeminiTaskPlanner(client: geminiClient, credentials: credentials),
            dispatcher: brain.toolDispatcher,
            denyPendingConfirmation: { [weak brain] in brain?.denyPendingConfirmation() },
            store: taskStore,
            now: now)
        self.tasks = tasks

        // Proactive Ivy: built idle. It can notify and suggest; it holds no reference to any tool dispatcher.
        let proactive = ProactiveEngine(store: proactiveStore, deliverer: proactiveDeliverer, signals: proactiveSignals,
                                        settings: { [weak settings] in settings?.settings ?? .defaults }, now: now)
        proactiveRelay.engine = proactive
        proactiveRelay.setAcceptingTriggers(settings.settings.proactiveEnabled)
        self.proactive = proactive
        self.loginItem = loginItem
        proactive.composeBriefing = { [weak brain] data in await brain?.composeBriefing(from: data) }
        proactive.onBriefing = { [weak brain] text in brain?.appendProactiveMessage(text) }
        proactive.onStopKind = { [weak settings] kind in
            switch kind {
            case .calendarHeadsUp: settings?.settings.proactiveCalendar = false
            case .briefing: settings?.settings.proactiveBriefing = false
            case .reminder, .followUp, .watch: break // these are backed by a trigger, which is removed instead
            case .taskUpdate: break // one notification per task the user started; nothing recurring to stop
            }
        }

        // 4/5. Voice + Live infrastructure, created idle.
        let ttsVoice = OSAllocatedUnfairLock(initialState: settings.settings.ttsVoiceSettings)
        self.ttsVoice = ttsVoice
        let voice = voiceManager ?? VoicePlaybackManager(credentials: credentials, voiceSettings: { ttsVoice.withLock { $0 } })
        self.voiceManager = voice
        tasks.onFinished = { [weak brain, weak proactive] run in
            if let report = run.report { brain?.appendProactiveMessage(report) }
            let summary: String
            switch run.phase {
            case .finished(.succeeded): summary = "done"
            case .finished(.cancelled): summary = "stopped"
            default: summary = "stopped with problems"
            }
            Task { @MainActor in await proactive?.notifyTaskFinished(goal: run.goal, summary: summary) }
        }
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

        if settings.settings.screenHelpHotkeyEnabled, let screenHelpHotkey {
            do {
                try screenHelpHotkey.register(shortcut: .defaultScreenHelp) { [weak self] in
                    Task { @MainActor [weak self] in await self?.handleScreenHelp() }
                } onKeyUp: {}
            } catch {
                print("[HOTKEY] screen help unavailable: \(error.localizedDescription)")
            }
        }

        if settings.settings.commandBarHotkeyEnabled, let commandBarHotkey {
            do {
                try commandBarHotkey.register(shortcut: .defaultCommandBar) { [weak self] in
                    Task { @MainActor [weak self] in self?.onCommandBar?() }
                } onKeyUp: {}
            } catch {
                print("[HOTKEY] command bar unavailable: \\(error.localizedDescription)")
            }
        }

        if settings.settings.pushToTalkEnabled {
            do {
                try liveCoordinator.registerHotkey()
            } catch {
                hotkeyError = error.localizedDescription
                print("[HOTKEY] push-to-talk unavailable: \(error.localizedDescription)")
            }
        }

        personalizationSubscription = personalization.$profile.sink { [weak brain] profile in
            brain?.personalization = profile
        }
        workspaceSubscription = workspaces.$context.sink { [weak brain] context in
            brain?.workspaceContext = context
        }
        if workspaces.active != nil {
            Task { @MainActor [weak workspaces] in await workspaces?.refreshContext() }
        }

        var previous = settings.settings
        settingsSubscription = settings.$settings.sink { [weak self, weak brain, weak wakeWord, weak liveCoordinator, weak proactive] new in
            defer { previous = new }
            proactiveRelay.setAcceptingTriggers(new.proactiveEnabled)
            if new.proactiveEnabled, !previous.proactiveEnabled {
                self?.requestNotificationAccess?()
                // Anything already due is noticed now, not at the next timer check.
                Task { @MainActor [weak proactive] in await proactive?.tick() }
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
    /// Also `remember_preference`, which reaches the personalization model through `memory`, and the developer
    /// tools, which work in the active workspace (`file_op` writes are confined to it while one is active).
    static func toolRegistry(relay: ProactiveRelay, memory: PreferenceMemory = PersonalizationRelay(),
                             workspace: WorkspaceScope = WorkspaceScope(), git: CommandRunning = SystemCommandRunner(),
                             geometry: ScreenGeometryRelay = ScreenGeometryRelay(),
                             presenter: AnnotationPresenting = NoAnnotationPresenter()) -> ToolRegistry {
        ToolRegistry.standardRegistry().registering(contentsOf: [
            PointAtTool(geometry: geometry, presenter: presenter),
            ScheduleFollowUpTool(scheduler: relay),
            RememberPreferenceTool(memory: memory),
            FileOpTool(workspace: workspace),
            GitReadTool(scope: workspace, runner: git),
            GitWriteTool(scope: workspace, runner: git),
            GitRemoteTool(scope: workspace, runner: git),
            CodeSearchTool(scope: workspace, runner: git),
            ProjectRunTool(scope: workspace),
            LogAnalyzeTool(scope: workspace),
            GitHubTool(scope: workspace, runner: git),
        ])
    }

    /// The app target supplies the on-screen overlay that draws `point_at` highlights.
    public static func production(annotationPresenter: AnnotationPresenting = NoAnnotationPresenter()) -> IvyAppEnvironment {
        let relay = ProactiveRelay()
        let memory = PersonalizationRelay()
        let profileStore = FilePersonalizationStore()
        let workspaceScope = WorkspaceScope()
        let geometry = ScreenGeometryRelay()
        let annotations = annotationPresenter
        let deliverer = SystemProactiveDeliverer()
        let environment = IvyAppEnvironment(
            settingsStore: UserDefaultsSettingsStore(),
            credentials: KeychainCredentialProvider(),
            conversationStore: FileConversationStore(),
            proactiveStore: FileProactiveStore(),
            proactiveDeliverer: deliverer,
            proactiveSignals: SystemProactiveSignals(),
            proactiveRelay: relay,
            personalizationStore: profileStore,
            personalizationRelay: memory,
            screenHelpHotkey: SystemGlobalHotkeyManager(),
            taskStore: FileTaskStore(),
            workspaceStore: FileWorkspaceStore(),
            workspaceScope: workspaceScope,
            screenGeometry: geometry,
            annotationPresenter: annotations,
            commandBarHotkey: SystemGlobalHotkeyManager(),
            loginItem: SystemLoginItem()
        ) { credentials, settings in
            GeminiLiveVoiceCoordinator(
                credentials: credentials,
                echoCancellation: settings.echoCancellation,
                // Live gets the same composed prompt as chat (read at launch; profile changes apply next launch).
                systemInstruction: LiveVoiceStyle.instruction(
                    base: SystemPromptBuilder.build(profile: profileStore.load()),
                    length: settings.voiceResponseLength, pace: settings.voiceSpeakingPace),
                hotkeyManager: SystemGlobalHotkeyManager(),
                // Always on: spoken commands ("Hey Ivy, goodbye") are read from the transcript. Whether
                // transcripts are *saved* is the brain's decision (`saveVoiceTranscripts`).
                transcribesAudio: true,
                silenceDurationMs: settings.voicePatience.silenceDurationMs,
                toolRegistry: toolRegistry(relay: relay, memory: memory, workspace: workspaceScope, geometry: geometry, presenter: annotations)
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

    /// Whether the app should show the introduction at launch.
    public var needsOnboarding: Bool { !settings.settings.onboardingCompleted }

    /// "What am I looking at?": captures the front window (never Ivy's, never an excluded app). During a voice
    /// session the frame goes to Live; otherwise it is attached to the composer with the question pre-filled,
    /// and nothing is sent until the user presses Return.
    public func handleScreenHelp() async {
        guard let attachment = await attachments.capture(.frontWindow) else { return }
        if liveCoordinator.state.isLive, let frame = attachment.jpeg.first, await liveCoordinator.sendImage(frame) {
            attachments.markShown(attachment)
            attachments.remove(attachment.id)
            return
        }
        if attachments.suggestedPrompt == nil { attachments.suggestedPrompt = "What am I looking at?" }
        onScreenHelp?()
    }

    /// Quit path: denies any pending approval, saves the conversation, stops playback, and tears down
    /// Live (mic tap, socket, audio queue, hotkey) so nothing stale survives into the next launch.
    public func shutdown() async {
        tasks.cancel()
        brain.prepareForTermination()
        screenHelpHotkey?.unregister()
        commandBarHotkey?.unregister()
        attachments.clear()
        proactive.stop()
        await wakeWord.shutdown()
        voiceManager.stop()
        await liveCoordinator.shutdown()
    }
}
