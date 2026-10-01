import Testing
import Foundation
import os
@testable import IvyCore

@MainActor
private func makeOnboarding(keychain: InMemoryKeychainStore = InMemoryKeychainStore(),
                            permissions: MockPermissionManager = MockPermissionManager())
    -> (OnboardingModel, SettingsModel, PersonalizationModel, KeychainCredentialProvider) {
    let settings = SettingsModel(store: InMemorySettingsStore())
    let personalization = PersonalizationModel(store: InMemoryPersonalizationStore())
    let credentials = KeychainCredentialProvider(keychain: keychain, environment: [:])
    return (OnboardingModel(settings: settings, personalization: personalization, credentials: credentials, permissions: permissions),
            settings, personalization, credentials)
}

private final class FailOnceClient: GeminiClientProtocol, @unchecked Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: [String]())
    var texts: [String] { calls.withLock { $0 } }
    func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
    func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
        let count = calls.withLock { c -> Int in
            c.append(history.last?.text ?? "")
            return c.count
        }
        if count == 1 { throw GeminiClientError.serverError(statusCode: 503, message: "busy") }
        return ModelTurnResponse(text: "Second time lucky.")
    }
}

@MainActor
@Suite("Phase 17c - Onboarding")
struct Phase17cOnboardingTests {
    @Test("only a fresh install sees it: no key, no conversations, not done before")
    func whoSeesIt() {
        let fresh = IvySettings.defaults
        #expect(OnboardingModel.shouldShow(settings: fresh, credentials: FixedCredentialProvider([:]), hasConversations: false))
        #expect(!OnboardingModel.shouldShow(settings: fresh, credentials: FixedCredentialProvider([.geminiAPIKey: "k"]), hasConversations: false))
        #expect(!OnboardingModel.shouldShow(settings: fresh, credentials: FixedCredentialProvider([:]), hasConversations: true))
        var done = fresh
        done.onboardingCompleted = true
        #expect(!OnboardingModel.shouldShow(settings: done, credentials: FixedCredentialProvider([:]), hasConversations: false))
    }

    @Test("the name goes to the profile; sensitive text is refused and the step stays put")
    func nameTag() {
        let (model, _, personalization, _) = makeOnboarding()
        model.name = "my password is hunter22"
        model.next()
        #expect(model.step == .nameTag && model.message != nil)
        model.name = "Sam"
        model.next()
        #expect(model.step == .personality)
        #expect(personalization.profile.aboutMe["name"] == "Sam")
    }

    @Test("personality is applied; each sass level has its own sample line")
    func personality() {
        let (model, _, personalization, _) = makeOnboarding()
        model.skip()
        model.sass = 0
        model.next()
        #expect(personalization.profile.sass == 0 && model.step == .keys)
        #expect(Set((0...3).map(OnboardingModel.sampleLine)).count == 4)
    }

    @Test("keys: Continue needs a usable Gemini key; a pasted key goes to the Keychain; Skip moves on without one")
    func keys() throws {
        let keychain = InMemoryKeychainStore()
        let (model, _, _, credentials) = makeOnboarding(keychain: keychain)
        model.skip(); model.skip()
        #expect(model.step == .keys)
        model.next()
        #expect(model.step == .keys && model.message != nil)
        #expect(model.saveKey("  AIza-not-a-real-key  ", for: .geminiAPIKey))
        #expect(credentials.credential(for: .geminiAPIKey) == "AIza-not-a-real-key")
        model.next()
        #expect(model.step == .voice)

        let (other, _, _, _) = makeOnboarding()
        other.skip(); other.skip(); other.skip()
        #expect(other.step == .voice)
    }

    @Test("the microphone is asked for only when the user presses the button on the voice step")
    func microphone() async {
        let permissions = MockPermissionManager()
        let (model, _, _, _) = makeOnboarding(permissions: permissions)
        #expect(permissions.requestedTypes.isEmpty)
        await model.requestMicrophone()
        #expect(permissions.requestedTypes == [.microphone])
        #expect(model.microphone == .authorized)
    }

    @Test("walking through with Skip changes no setting except 'done'; superpowers turn on only when switched on")
    func nothingWithoutConsent() {
        let (model, settings, personalization, _) = makeOnboarding()
        let before = settings.settings
        while model.step != .done { model.skip() }
        var expected = before
        expected.onboardingCompleted = true
        #expect(settings.settings == expected)
        #expect(personalization.profile.isDefault)
        #expect(!model.wakeWordEnabled && !model.proactiveEnabled)

        model.restart()
        model.setWakeWord(true)
        #expect(settings.settings.wakeWordEnabled)
    }

    @Test("closing early still counts as done, so it doesn't come back at every launch")
    func finishEarly() {
        let (model, settings, _, _) = makeOnboarding()
        model.finish()
        #expect(settings.settings.onboardingCompleted)
    }

    @Test("the app marks existing installs done at launch and shows the introduction to new ones")
    func environment() {
        func env(_ credentials: CredentialProvider) -> IvyAppEnvironment {
            IvyAppEnvironment(settingsStore: InMemorySettingsStore(), credentials: credentials,
                              conversationStore: InMemoryConversationStore(), geminiClient: RecordingGeminiClient(),
                              wakeWordListener: Phase17cSilentListener()) { _, _ in
                GeminiLiveVoiceCoordinator(session: MockGeminiLiveSession(), audioCapture: MockAudioCapture(), audioPlayer: MockLiveAudioPlayer(),
                                           wakeWordDetector: MockWakeWordDetector())
            }
        }
        #expect(!env(FixedCredentialProvider([.geminiAPIKey: "k"])).needsOnboarding)
        #expect(env(FixedCredentialProvider([:])).needsOnboarding)
    }
}

@MainActor
@Suite("Phase 17c - Try again")
struct Phase17cRetryTests {
    @Test("a failed reply can be retried: the error goes, the same question is asked once more")
    func retry() async throws {
        let client = FailOnceClient()
        let brain = IvyBrain(client: client, apiKey: "k")
        await brain.send("Why is the build red?")
        #expect(brain.messages.last?.isError == true)
        #expect(brain.retryableMessage?.text == "Why is the build red?")

        await brain.retryLastFailed()
        #expect(client.texts == ["Why is the build red?", "Why is the build red?"])
        #expect(brain.messages.map(\.text) == ["Why is the build red?", "Second time lucky."])
        #expect(brain.retryableMessage == nil)
    }

    @Test("nothing to retry after a good reply")
    func nothingToRetry() async {
        let brain = IvyBrain(client: RecordingGeminiClient(), apiKey: "k")
        await brain.send("hi")
        #expect(brain.retryableMessage == nil)
    }
}

private final class Phase17cSilentListener: WakeWordListening, @unchecked Sendable {
    func start(onWake: @escaping @Sendable () -> Void) async throws {}
    func stop() async {}
}
