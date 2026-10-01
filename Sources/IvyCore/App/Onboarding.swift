import Foundation
import Combine

/// First-run introduction (Phase 17c). Every step can be skipped; nothing is turned on without the user's
/// choice; permissions are explained before macOS asks. Re-runnable from Settings.
@MainActor
public final class OnboardingModel: ObservableObject {
    public enum Step: Int, CaseIterable, Sendable {
        case nameTag, personality, keys, voice, superpowers, done

        public var title: String {
            switch self {
            case .nameTag: return "HELLO, my name is Ivy."
            case .personality: return "How much attitude?"
            case .keys: return "Give me something to think with"
            case .voice: return "Talk to me"
            case .superpowers: return "Optional superpowers"
            case .done: return "That's it."
            }
        }
    }

    @Published public private(set) var step: Step = .nameTag
    @Published public var name = ""
    @Published public var sass = PersonalizationProfile.defaultSass
    @Published public private(set) var message: String?
    @Published public private(set) var microphone: PermissionState

    private let settings: SettingsModel
    private let personalization: PersonalizationModel
    private let credentials: CredentialProvider
    private let permissions: PermissionManaging

    public init(settings: SettingsModel, personalization: PersonalizationModel, credentials: CredentialProvider,
                permissions: PermissionManaging = SystemPermissionManager()) {
        self.settings = settings
        self.personalization = personalization
        self.credentials = credentials
        self.permissions = permissions
        microphone = permissions.status(for: .microphone)
        name = personalization.profile.aboutMe[PersonalizationProfile.AboutField.name.rawValue] ?? ""
        sass = personalization.profile.sass
    }

    /// Existing installs (a key is set, or there are conversations) never see the introduction.
    public static func shouldShow(settings: IvySettings, credentials: CredentialProvider, hasConversations: Bool) -> Bool {
        !settings.onboardingCompleted && !credentials.source(for: .geminiAPIKey).isUsable && !hasConversations
    }

    public var progress: Double { Double(step.rawValue) / Double(Step.allCases.count - 1) }

    public func back() {
        message = nil
        if let previous = Step(rawValue: step.rawValue - 1) { step = previous }
    }

    /// Moves on without applying this step.
    public func skip() {
        message = nil
        advance()
    }

    /// Applies this step's choices, then moves on. Stays put (with a message) if something can't be saved.
    public func next() {
        message = nil
        switch step {
        case .nameTag:
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try personalization.update { $0.aboutMe[PersonalizationProfile.AboutField.name.rawValue] = trimmed.isEmpty ? nil : trimmed }
            } catch {
                message = error.localizedDescription
                return
            }
        case .personality:
            personalization.setSass(sass)
        case .keys:
            guard credentials.source(for: .geminiAPIKey).isUsable else {
                message = "Without a Gemini key I can't answer anything. Paste one, or skip and add it later in Settings."
                return
            }
        case .voice, .superpowers:
            break
        case .done:
            finish()
            return
        }
        advance()
    }

    /// Saves a pasted key straight to the Keychain; the text is never kept here.
    public func saveKey(_ value: String, for key: CredentialKey) -> Bool {
        do {
            try credentials.store(value, for: key)
            message = nil
            objectWillChange.send()
            return true
        } catch {
            message = "Couldn't save the key: \(error.localizedDescription)"
            return false
        }
    }

    public func source(for key: CredentialKey) -> CredentialSource {
        credentials.source(for: key)
    }

    /// Asked only after the voice step has explained what the microphone is for.
    public func requestMicrophone() async {
        microphone = await permissions.requestPermission(for: .microphone)
    }

    /// Each optional feature is off unless the user switches it on here.
    public func setWakeWord(_ on: Bool) {
        objectWillChange.send()
        settings.settings.wakeWordEnabled = on
    }

    public func setProactive(_ on: Bool) {
        objectWillChange.send()
        settings.settings.proactiveEnabled = on
    }

    public func setScreenHelp(_ on: Bool) {
        objectWillChange.send()
        settings.settings.screenHelpHotkeyEnabled = on
    }
    public var wakeWordEnabled: Bool { settings.settings.wakeWordEnabled }
    public var proactiveEnabled: Bool { settings.settings.proactiveEnabled }
    public var screenHelpEnabled: Bool { settings.settings.screenHelpHotkeyEnabled }

    /// Marks the introduction done (also when closed early).
    public func finish() {
        if !settings.settings.onboardingCompleted { settings.settings.onboardingCompleted = true }
    }

    /// From Settings: start over (nothing already chosen is undone).
    public func restart() {
        step = .nameTag
        message = nil
    }

    private func advance() {
        if let following = Step(rawValue: step.rawValue + 1) { step = following }
        if step == .done { finish() }
    }

    /// One line per sass level so the user hears the difference before choosing.
    public static func sampleLine(sass: Int) -> String {
        switch min(max(sass, 0), 3) {
        case 0: return "Happy to help! Here's what I found."
        case 1: return "Sure — here you go. That one was easy."
        case 2: return "Fine. Done. Try asking something harder next time."
        default: return "Done, obviously. I'd say \"you're welcome\", but you weren't going to say thanks."
        }
    }
}
