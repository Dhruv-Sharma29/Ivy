import Testing
import Foundation
import Security
@testable import IvyCore

private let geminiSecret = "AQ.TestOnlyGeminiKey_0123456789abcdefghijklmnop"
private let elevenSecret = "sk_0123456789abcdef0123456789abcdef0123456789abcdef"

// MARK: - 5A Keychain

@Suite("Phase 5A - Keychain")
struct Phase5KeychainTests {
    @Test("save/read preserves exact bytes, including non-UTF8 data")
    func exactData() throws {
        let store = InMemoryKeychainStore()
        let bytes = Data([0x00, 0xFF, 0x10, 0x80, 0x7F])
        try store.save(bytes, for: .geminiAPIKey)
        #expect(try store.read(.geminiAPIKey) == bytes)
        #expect(store.exists(.geminiAPIKey))
    }

    @Test("duplicate save, and read/update/delete of a missing item, report structured errors")
    func errors() throws {
        let store = InMemoryKeychainStore()
        #expect(throws: KeychainError.itemNotFound) { try store.read(.geminiAPIKey) }
        #expect(throws: KeychainError.itemNotFound) { try store.update(Data("x".utf8), for: .geminiAPIKey) }
        #expect(throws: KeychainError.itemNotFound) { try store.delete(.geminiAPIKey) }
        try store.save(Data("a".utf8), for: .geminiAPIKey)
        #expect(throws: KeychainError.duplicateItem) { try store.save(Data("b".utf8), for: .geminiAPIKey) }
    }

    @Test("update replaces, delete removes")
    func updateDelete() throws {
        let store = InMemoryKeychainStore()
        try store.save(Data("old".utf8), for: .elevenLabsAPIKey)
        try store.update(Data("new".utf8), for: .elevenLabsAPIKey)
        #expect(try store.read(.elevenLabsAPIKey) == Data("new".utf8))
        try store.delete(.elevenLabsAPIKey)
        #expect(!store.exists(.elevenLabsAPIKey))
    }

    @Test("credentials are isolated from each other")
    func isolation() throws {
        let store = InMemoryKeychainStore()
        try store.save(Data(geminiSecret.utf8), for: .geminiAPIKey)
        #expect(!store.exists(.elevenLabsAPIKey))
        try store.save(Data(elevenSecret.utf8), for: .elevenLabsAPIKey)
        try store.delete(.geminiAPIKey)
        #expect(try store.read(.elevenLabsAPIKey) == Data(elevenSecret.utf8))
    }

    @Test("system queries target one generic-password item per credential under a single service")
    func systemQueryShape() {
        let g = SystemKeychainStore.baseQuery(for: .geminiAPIKey)
        let e = SystemKeychainStore.baseQuery(for: .elevenLabsAPIKey)
        #expect(g[kSecClass as String] as? String == kSecClassGenericPassword as String)
        #expect(g[kSecAttrService as String] as? String == CredentialKey.keychainService)
        #expect(g[kSecAttrAccount as String] as? String != e[kSecAttrAccount as String] as? String)
        #expect(Set(CredentialKey.allCases.map(\.account)).count == CredentialKey.allCases.count)
    }

    @Test("OSStatus maps to app errors, and descriptions carry no secret material")
    func statusMapping() {
        #expect(KeychainError(status: errSecItemNotFound) == .itemNotFound)
        #expect(KeychainError(status: errSecDuplicateItem) == .duplicateItem)
        #expect(KeychainError(status: errSecAuthFailed) == .accessDenied)
        #expect(KeychainError(status: errSecInteractionNotAllowed) == .accessDenied)
        #expect(KeychainError(status: -99_999) == .unexpectedStatus(-99_999))
        for e: KeychainError in [.itemNotFound, .duplicateItem, .accessDenied, .invalidData, .unexpectedStatus(-1)] {
            let text = e.localizedDescription
            #expect(!text.isEmpty && !text.contains(geminiSecret) && !text.contains(elevenSecret))
        }
    }
}

// MARK: - 5B Credentials

@Suite("Phase 5B - Credential provider")
struct Phase5CredentialTests {
    @Test("Keychain value wins over the environment")
    func keychainFirst() throws {
        let kc = InMemoryKeychainStore()
        try kc.save(Data(geminiSecret.utf8), for: .geminiAPIKey)
        let p = KeychainCredentialProvider(keychain: kc, environment: ["GEMINI_API_KEY": "env-value-123456"])
        #expect(p.credential(for: .geminiAPIKey) == geminiSecret)
        #expect(p.source(for: .geminiAPIKey) == .keychain)
    }

    @Test("environment fallback works when the Keychain is empty, and is never copied into it")
    func environmentFallback() {
        let kc = InMemoryKeychainStore()
        let p = KeychainCredentialProvider(keychain: kc, environment: ["ELEVENLABS_API_KEY": "  \(elevenSecret)\n"])
        #expect(p.credential(for: .elevenLabsAPIKey) == elevenSecret)
        #expect(p.source(for: .elevenLabsAPIKey) == .environment)
        #expect(kc.snapshot.isEmpty)
    }

    @Test("missing and blank credentials report missing")
    func missing() {
        let p = KeychainCredentialProvider(keychain: InMemoryKeychainStore(), environment: ["GEMINI_API_KEY": "   "])
        #expect(p.credential(for: .geminiAPIKey) == nil)
        #expect(p.source(for: .geminiAPIKey) == .missing)
        #expect(p.source(for: .elevenLabsAPIKey) == .missing)
    }

    @Test("store trims, updates an existing item, and rejects empty values")
    func store() throws {
        let kc = InMemoryKeychainStore()
        let p = KeychainCredentialProvider(keychain: kc, environment: [:])
        try p.store("  first-value-123  ", for: .geminiAPIKey)
        try p.store(geminiSecret, for: .geminiAPIKey)
        #expect(p.credential(for: .geminiAPIKey) == geminiSecret)
        #expect(throws: KeychainError.invalidData) { try p.store("   ", for: .geminiAPIKey) }
        #expect(p.credential(for: .geminiAPIKey) == geminiSecret)
    }

    @Test("remove is idempotent and falls back to the environment afterwards")
    func remove() throws {
        let kc = InMemoryKeychainStore()
        let p = KeychainCredentialProvider(keychain: kc, environment: ["GEMINI_API_KEY": "env-fallback-value"])
        try p.store(geminiSecret, for: .geminiAPIKey)
        try p.remove(.geminiAPIKey)
        try p.remove(.geminiAPIKey)
        #expect(p.credential(for: .geminiAPIKey) == "env-fallback-value")
    }

    @Test("a Keychain failure degrades to the environment instead of crashing")
    func keychainFailure() throws {
        let kc = InMemoryKeychainStore()
        try kc.save(Data(geminiSecret.utf8), for: .geminiAPIKey)
        kc.failReads(with: .accessDenied)
        let p = KeychainCredentialProvider(keychain: kc, environment: ["GEMINI_API_KEY": "env-fallback-value"])
        #expect(p.credential(for: .geminiAPIKey) == "env-fallback-value")
    }

    @Test("the brain sends the provider's key to Gemini and reflects missing configuration without leaking it")
    @MainActor
    func brainUsesProvider() async {
        let client = RecordingGeminiClient()
        let kc = InMemoryKeychainStore()
        let credentials = KeychainCredentialProvider(keychain: kc, environment: [:])
        let brain = IvyBrain(client: client, credentials: credentials)
        #expect(!brain.isGeminiKeyConfigured)
        await brain.send("hi")
        #expect(client.receivedKeys.isEmpty)
        #expect(brain.messages.last?.isError == true)

        try? credentials.store(geminiSecret, for: .geminiAPIKey)
        brain.refreshCredentialStatus()
        #expect(brain.geminiCredentialSource == .keychain)
        await brain.send("hi again")
        #expect(client.receivedKeys == [geminiSecret])
        #expect(!brain.messages.contains { $0.text.contains(geminiSecret) })
    }

    @Test("ElevenLabs and Live read their keys through the provider")
    @MainActor
    func voiceUsesProvider() {
        let credentials = FixedCredentialProvider([.elevenLabsAPIKey: elevenSecret])
        let manager = VoicePlaybackManager(credentials: credentials)
        #expect((manager.synthesizer as? ElevenLabsSpeechSynthesizer)?.keyProvider.getAPIKey() == elevenSecret)
        #expect(CredentialElevenLabsKeyProvider(credentials: FixedCredentialProvider([:])).getAPIKey() == nil)
    }
}

// MARK: - 5C Settings

@Suite("Phase 5C - Settings", .serialized)
struct Phase5SettingsTests {
    private func freshDefaults() -> (UserDefaults, String) {
        let name = "ivy.tests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test("defaults when nothing is stored")
    func defaults() {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        #expect(UserDefaultsSettingsStore(defaults: d).load() == .defaults)
    }

    @Test("save/load round-trips")
    func roundTrip() throws {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        let store = UserDefaultsSettingsStore(defaults: d)
        var s = IvySettings.defaults
        s.echoCancellation = false
        s.restoreLastConversation = false
        try store.save(s)
        #expect(store.load() == s)
    }

    @Test("corrupt bytes and wrongly-typed values recover to defaults")
    func corrupt() {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        let store = UserDefaultsSettingsStore(defaults: d)
        d.set(Data([0xDE, 0xAD, 0xBE, 0xEF]), forKey: UserDefaultsSettingsStore.storageKey)
        #expect(store.load() == .defaults)
        d.set("not a blob", forKey: UserDefaultsSettingsStore.storageKey)
        #expect(store.load() == .defaults)
    }

    @Test("invalid or missing individual fields fall back per-field")
    func partial() {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        let json = #"{"echoCancellation": false, "pushToTalkEnabled": "yes", "futureSetting": 3}"#
        d.set(Data(json.utf8), forKey: UserDefaultsSettingsStore.storageKey)
        let loaded = UserDefaultsSettingsStore(defaults: d).load()
        #expect(loaded.echoCancellation == false)
        #expect(loaded.pushToTalkEnabled == IvySettings.defaults.pushToTalkEnabled)
        #expect(loaded.persistConversationHistory == IvySettings.defaults.persistConversationHistory)
    }

    @Test("the settings model persists every change")
    @MainActor
    func modelPersists() {
        let store = InMemorySettingsStore()
        let model = SettingsModel(store: store)
        model.settings.showLiveTranscript = false
        #expect(store.saved?.showLiveTranscript == false)
        #expect(SettingsModel(store: store).settings.showLiveTranscript == false)
    }

    @Test("settings storage never contains credentials")
    func noCredentialsInDefaults() throws {
        let (d, name) = freshDefaults(); defer { d.removePersistentDomain(forName: name) }
        let credentials = KeychainCredentialProvider(keychain: InMemoryKeychainStore(), environment: [:])
        try credentials.store(geminiSecret, for: .geminiAPIKey)
        try UserDefaultsSettingsStore(defaults: d).save(.defaults)
        let dump = d.dictionaryRepresentation().description + String(decoding: d.data(forKey: UserDefaultsSettingsStore.storageKey) ?? Data(), as: UTF8.self)
        #expect(!dump.contains(geminiSecret))
        #expect(!dump.lowercased().contains("apikey"))
    }
}

// MARK: - 5D Conversations

@Suite("Phase 5D - Conversation persistence")
struct Phase5ConversationTests {
    private func sample(_ texts: [(MessageRole, String)], start: Date = Date(timeIntervalSince1970: 1_800_000_000.123)) -> Conversation {
        let msgs = texts.enumerated().map { i, t in
            StoredMessage(id: UUID(), role: t.0, text: t.1, timestamp: start.addingTimeInterval(Double(i) * 1.5), isError: false)
        }
        return Conversation(createdAt: start, updatedAt: msgs.last?.timestamp ?? start, messages: msgs)
    }

    @Test("save/load preserves order, roles, text and exact timestamps")
    func roundTrip() throws {
        let store = FileConversationStore(directory: makeTemporaryDirectory())
        let c = sample([(.user, "Open Safari"), (.model, "Opened it. Try not to get lost."), (.user, "Thanks")])
        try store.save(c)
        let loaded = try #require(store.load(c.id))
        #expect(loaded == c)
        #expect(loaded.messages.map(\.role) == [.user, .model, .user])
        #expect(loaded.messages.map(\.timestamp) == c.messages.map(\.timestamp))
    }

    @Test("update requires an existing conversation; delete is idempotent")
    func updateDelete() throws {
        let store = FileConversationStore(directory: makeTemporaryDirectory())
        var c = sample([(.user, "one")])
        #expect(throws: ConversationStoreError.notFound) { try store.update(c) }
        try store.save(c)
        c.messages.append(StoredMessage(id: UUID(), role: .model, text: "two", timestamp: Date(), isError: false))
        try store.update(c)
        #expect(store.load(c.id)?.messages.count == 2)
        try store.delete(c.id)
        try store.delete(c.id)
        #expect(store.load(c.id) == nil)
    }

    @Test("list is newest first, isolates conversations, and skips corrupt files")
    func listing() throws {
        let dir = makeTemporaryDirectory()
        let store = FileConversationStore(directory: dir)
        let older = sample([(.user, "older")], start: Date(timeIntervalSince1970: 1_000))
        let newer = sample([(.user, "newer")], start: Date(timeIntervalSince1970: 2_000))
        try store.save(older)
        try store.save(newer)
        let corruptID = UUID()
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("\(corruptID.uuidString).json"))
        try Data("junk".utf8).write(to: dir.appendingPathComponent("notes.txt"))

        #expect(store.list().map(\.id) == [newer.id, older.id])
        #expect(store.load(corruptID) == nil)
        #expect(store.load(older.id)?.messages.first?.text == "older")
    }

    @Test("files are private to the user")
    func permissions() throws {
        let dir = makeTemporaryDirectory()
        let store = FileConversationStore(directory: dir)
        let c = sample([(.user, "private")])
        try store.save(c)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("\(c.id.uuidString).json").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("only user/model text is kept: tool turns, tool results and signatures are dropped; secrets redacted")
    func dataBoundaries() throws {
        let call = FunctionCall(name: "run_shell", args: ["command": "cat ~/.env"], id: "c1", thoughtSignature: "opaque-signature")
        let chat = [
            ChatMessage(role: .user, text: "My key is \(geminiSecret), keep it safe"),
            ChatMessage(role: .model, text: "", functionCall: call),
            ChatMessage(role: .function, text: "GEMINI_API_KEY=\(geminiSecret)", functionResponse: FunctionResponse(name: "run_shell", response: ["result": .string(geminiSecret)], id: "c1")),
            ChatMessage(role: .model, text: "Done.", thoughtSignature: "opaque-signature")
        ]
        let c = Conversation(id: UUID(), createdAt: Date(), chatMessages: chat)
        #expect(c.messages.map(\.role) == [.user, .model])
        let store = FileConversationStore(directory: makeTemporaryDirectory())
        try store.save(c)
        let raw = String(decoding: try Data(contentsOf: store.directory.appendingPathComponent("\(c.id.uuidString).json")), as: UTF8.self)
        #expect(!raw.contains(geminiSecret))
        #expect(!raw.contains("opaque-signature"))
        #expect(!raw.contains("run_shell"))
        #expect(raw.contains(SecretRedactor.placeholder))
    }

    @Test("redactor masks known key shapes and leaves ordinary text alone")
    func redactor() {
        #expect(!SecretRedactor.redact("key AIzaSyA1234567890abcdefghijklmnopqrstu").contains("AIzaSy"))
        #expect(!SecretRedactor.redact(elevenSecret).contains("0123456789abcdef"))
        #expect(!SecretRedactor.redact("Authorization: Bearer abcdefghijklmnop123456").contains("abcdefghijklmnop123456"))
        #expect(SecretRedactor.redact("api_key = hunter2hunter2") == "api_key = \(SecretRedactor.placeholder)")
        #expect(SecretRedactor.redact("The sky is blue and sk is short.") == "The sky is blue and sk is short.")
    }
}

// MARK: - 5D/5E Brain persistence and startup

@Suite("Phase 5E - Startup, restore and shutdown")
@MainActor
struct Phase5StartupTests {
    private func environment(
        settings: IvySettings = .defaults,
        conversations: ConversationStore = InMemoryConversationStore(),
        credentials: CredentialProvider = FixedCredentialProvider([.geminiAPIKey: geminiSecret]),
        client: GeminiClientProtocol = RecordingGeminiClient()
    ) -> (IvyAppEnvironment, MockAudioCapture, MockGeminiLiveSession, MockGlobalHotkeyManager) {
        let capture = MockAudioCapture()
        let session = MockGeminiLiveSession()
        let hotkey = MockGlobalHotkeyManager()
        let env = IvyAppEnvironment(
            settingsStore: InMemorySettingsStore(settings),
            credentials: credentials,
            conversationStore: conversations,
            geminiClient: client,
            voiceManager: VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: MockAudioPlayer())
        ) { _, _ in
            GeminiLiveVoiceCoordinator(session: session, audioCapture: capture, audioPlayer: MockLiveAudioPlayer(),
                                       wakeWordDetector: MockWakeWordDetector(), hotkeyManager: hotkey)
        }
        return (env, capture, session, hotkey)
    }

    @Test("clean launch: nothing listens, connects, speaks, or runs")
    func cleanLaunch() async {
        let client = RecordingGeminiClient()
        let (env, capture, session, hotkey) = environment(client: client)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(env.liveCoordinator.state == .idle)
        #expect(capture.startCaptureCallCount == 0)
        #expect(!session.isConnected)
        #expect(env.voiceManager.state == .idle)
        #expect(client.receivedKeys.isEmpty)
        #expect(hotkey.isRegistered)
        #expect(env.brain.messages.isEmpty)
    }

    @Test("push-to-talk respects the persisted setting")
    func hotkeySetting() {
        var s = IvySettings.defaults
        s.pushToTalkEnabled = false
        let (_, _, _, hotkey) = environment(settings: s)
        #expect(!hotkey.isRegistered)
    }

    @Test("removed Pointer preferences are ignored without changing retained settings")
    func removedPointerSettingsCompatibility() throws {
        let old = Data(#"{"floatingPointerEnabled":true,"floatingPointerColor":"red","screenQuestionEnabled":true,"screenQuestionShortcut":"pushToTalk","pushToTalkEnabled":true,"companionEnabled":false,"visionMaskSecrets":false}"#.utf8)
        let decoded = try JSONDecoder().decode(IvySettings.self, from: old)
        #expect(decoded.pushToTalkEnabled && !decoded.companionEnabled && !decoded.visionMaskSecrets)
        let roundTrip = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        #expect(roundTrip?["floatingPointerEnabled"] == nil && roundTrip?["floatingPointerColor"] == nil)
        #expect(roundTrip?["screenQuestionEnabled"] == nil && roundTrip?["screenQuestionShortcut"] == nil)
        #expect(try JSONDecoder().decode(IvySettings.self, from: JSONEncoder().encode(decoded)) == decoded)
    }

    @Test("push-to-talk setting changes register globally without restarting")
    func hotkeySettingChangesImmediately() async throws {
        var preferences = IvySettings.defaults
        preferences.pushToTalkEnabled = false
        let (env, capture, _, hotkey) = environment(settings: preferences)
        #expect(!hotkey.isRegistered)
        env.settings.settings.pushToTalkEnabled = true
        #expect(hotkey.isRegistered && hotkey.registrationCount == 1)
        hotkey.simulateKeyDown()
        for _ in 0..<100 {
            if capture.isCapturing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(capture.isCapturing)
        env.settings.settings.pushToTalkEnabled = false
        #expect(!hotkey.isRegistered)
        for _ in 0..<100 {
            if !capture.isCapturing && env.liveCoordinator.state == .idle { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!capture.isCapturing && env.liveCoordinator.state == .idle)
        env.settings.settings.pushToTalkEnabled = true
        #expect(hotkey.isRegistered && hotkey.registrationCount == 2)
        env.settings.settings.companionEnabled.toggle()
        #expect(hotkey.registrationCount == 2, "Other settings must not replace the registered handler")
        await env.shutdown()
    }

    @Test("a failed push-to-talk registration can be retried with the setting")
    func hotkeySettingRetriesRegistration() async {
        var preferences = IvySettings.defaults
        preferences.pushToTalkEnabled = false
        let (env, _, _, hotkey) = environment(settings: preferences)
        hotkey.setMockErrorOnRegister(.registrationFailed(-9878))
        env.settings.settings.pushToTalkEnabled = true
        #expect(!hotkey.isRegistered && env.hotkeyError != nil)
        env.settings.settings.pushToTalkEnabled = false
        #expect(env.hotkeyError == nil)
        hotkey.setMockErrorOnRegister(nil)
        env.settings.settings.pushToTalkEnabled = true
        #expect(hotkey.isRegistered && env.hotkeyError == nil)
        await env.shutdown()
    }

    @Test("voice shortcut changes persist and take effect without microphone startup")
    func shortcutChoiceChangesImmediately() async throws {
        let (env, capture, _, hotkey) = environment()
        #expect(hotkey.registeredShortcut == .defaultPushToTalk)
        env.settings.settings.pushToTalkShortcut = .controlOptionCommandSpace
        #expect(hotkey.registrationCount == 2)
        #expect(hotkey.registeredShortcut == HotkeyShortcut(keyCode: 49, modifiers: [.control, .option, .command]))
        #expect(capture.startCaptureCallCount == 0)
        let decoded = try JSONDecoder().decode(IvySettings.self, from: JSONEncoder().encode(env.settings.settings))
        #expect(decoded.pushToTalkShortcut == .controlOptionCommandSpace)
        #expect(PushToTalkShortcut.commandShiftSpace.label == "⌘⇧Space")
        #expect(PushToTalkShortcut.controlOptionCommandSpace.label == "⌃⌥⌘Space")
        env.settings.settings.pushToTalkEnabled = false
        env.settings.settings.pushToTalkShortcut = .commandShiftSpace
        #expect(!hotkey.isRegistered && hotkey.registrationCount == 2)
        env.settings.settings.pushToTalkEnabled = true
        #expect(hotkey.registeredShortcut == .defaultPushToTalk)
        await env.shutdown()
    }

    @Test("changing a held voice shortcut closes old input even after immediate re-registration")
    func switchingHeldShortcutClosesInput() async throws {
        let (env, capture, _, hotkey) = environment()
        hotkey.simulateKeyDown()
        for _ in 0..<100 {
            if capture.isCapturing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(capture.isCapturing)
        env.settings.settings.pushToTalkShortcut = .controlOptionCommandSpace
        for _ in 0..<100 {
            if !capture.isCapturing && env.liveCoordinator.state == .idle { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!capture.isCapturing && env.liveCoordinator.state == .idle)
        #expect(hotkey.isRegistered && hotkey.registeredShortcut == PushToTalkShortcut.controlOptionCommandSpace.hotkey)
        hotkey.simulateKeyDown()
        for _ in 0..<100 {
            if capture.isCapturing { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(capture.isCapturing)
        hotkey.simulateKeyUp()
        await env.shutdown()
    }

    @Test("missing, unknown and wrongly typed shortcut choices recover to the default")
    func shortcutChoiceCompatibility() throws {
        for text in ["{}", #"{"pushToTalkShortcut":"retired","pushToTalkEnabled":false}"#,
                     #"{"pushToTalkShortcut":3,"pushToTalkEnabled":false}"#] {
            let decoded = try JSONDecoder().decode(IvySettings.self, from: Data(text.utf8))
            #expect(decoded.pushToTalkShortcut == .commandShiftSpace)
            if text != "{}" { #expect(!decoded.pushToTalkEnabled) }
        }
        #expect(HotkeyError.registrationFailed(-9878).localizedDescription.contains("choose another"))
        #expect(HotkeyError.registrationFailed(-9878).localizedDescription.contains("already registered"))
        #expect(HotkeyError.registrationFailed(-42).localizedDescription.contains("-42"))
    }

    @Test("the latest conversation is restored when enabled, and not otherwise")
    func restore() throws {
        let store = InMemoryConversationStore()
        let old = Conversation(id: UUID(), createdAt: Date(timeIntervalSince1970: 1), chatMessages: [ChatMessage(role: .user, text: "old", timestamp: Date(timeIntervalSince1970: 1))])
        let latest = Conversation(id: UUID(), createdAt: Date(timeIntervalSince1970: 5), chatMessages: [
            ChatMessage(role: .user, text: "hello", timestamp: Date(timeIntervalSince1970: 5)),
            ChatMessage(role: .model, text: "What now?", timestamp: Date(timeIntervalSince1970: 6))
        ])
        try store.save(old)
        try store.save(latest)

        let (env, _, _, _) = environment(conversations: store)
        #expect(env.brain.messages.map(\.text) == ["hello", "What now?"])
        #expect(env.brain.conversationID == latest.id)

        var s = IvySettings.defaults
        s.restoreLastConversation = false
        let (fresh, _, _, _) = environment(settings: s, conversations: store)
        #expect(fresh.brain.messages.isEmpty)
    }

    @Test("a missing credential is flagged and nothing auto-starts")
    func missingCredential() {
        let (env, capture, _, _) = environment(credentials: FixedCredentialProvider([:]))
        #expect(!env.brain.isGeminiKeyConfigured)
        #expect(capture.startCaptureCallCount == 0)
    }

    @Test("corrupt persisted state still yields a usable launch")
    func corruptState() throws {
        let dir = makeTemporaryDirectory()
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))
        let name = "ivy.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data([0x00, 0x01]), forKey: UserDefaultsSettingsStore.storageKey)

        let env = IvyAppEnvironment(
            settingsStore: UserDefaultsSettingsStore(defaults: defaults),
            credentials: FixedCredentialProvider([:]),
            conversationStore: FileConversationStore(directory: dir),
            voiceManager: VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: MockAudioPlayer())
        ) { _, _ in
            GeminiLiveVoiceCoordinator(session: MockGeminiLiveSession(), audioCapture: MockAudioCapture(), audioPlayer: MockLiveAudioPlayer(), wakeWordDetector: MockWakeWordDetector())
        }
        #expect(env.settings.settings == .defaults)
        #expect(env.brain.messages.isEmpty)
        #expect(env.liveCoordinator.state == .idle)
    }

    @Test("each turn is autosaved; clearing deletes the saved copy and starts a new boundary")
    func autosaveAndClear() async {
        let store = InMemoryConversationStore()
        let (env, _, _, _) = environment(conversations: store)
        await env.brain.send("Remember this")
        #expect(store.all.count == 1)
        #expect(store.all.first?.messages.map(\.role) == [.user, .model])
        let firstID = env.brain.conversationID

        env.brain.clearHistory()
        #expect(store.all.isEmpty)
        #expect(env.brain.conversationID != firstID)
    }

    @Test("history is not written when persistence is turned off")
    func persistenceOff() async {
        let store = InMemoryConversationStore()
        let (env, _, _, _) = environment(conversations: store)
        env.settings.settings.persistConversationHistory = false
        await env.brain.send("Off the record")
        #expect(store.all.isEmpty)
    }

    @Test("shutdown tears down Live, the mic and the hotkey; nothing stale survives")
    func shutdownCleanup() async {
        let (env, capture, session, hotkey) = environment()
        await env.liveCoordinator.startSession()
        #expect(capture.isCapturing)
        await env.shutdown()
        #expect(env.liveCoordinator.state == .idle)
        #expect(!capture.isCapturing)
        #expect(!session.isConnected)
        #expect(!hotkey.isRegistered)
        #expect(!env.liveCoordinator.isPushToTalkActive)
    }

    @Test("a risky tool pending at quit is denied, never executed, and the turn is saved")
    func pendingToolAtQuit() async throws {
        let shell = MockShellExecutor()
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [RunShellTool(executor: shell)]),
                                        safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))
        let store = InMemoryConversationStore()
        let client = RecordingGeminiClient(toolCall: FunctionCall(name: "run_shell", args: ["command": "echo quit"], id: "q1"), reply: "Cancelled.")
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: geminiSecret, conversationStore: store)
        bridge.handler = brain

        let send = Task { await brain.send("run it") }
        for _ in 0..<2000 where brain.pendingConfirmation == nil { try await Task.sleep(nanoseconds: 5_000_000) }
        // Fail (don't hang) if the card never appears: an unanswered card would suspend `send` forever.
        try #require(brain.pendingConfirmation != nil)
        brain.prepareForTermination()
        await send.value

        #expect(shell.recordedCommands.isEmpty)
        #expect(brain.pendingConfirmation == nil)
        #expect(store.all.first?.messages.first?.text == "run it")
    }
}

// MARK: - 5F Security audit

@Suite("Phase 5F - Security audit")
struct Phase5SecurityAuditTests {
    private static let sourcesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    private func sourceFiles() -> [(String, String)] {
        let e = FileManager.default.enumerator(at: Self.sourcesRoot, includingPropertiesForKeys: nil)
        return (e?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" }
            .compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url.lastPathComponent, $0) } }
    }

    @Test("no hard-coded credentials in Sources")
    func noHardcodedSecrets() {
        let files = sourceFiles()
        #expect(!files.isEmpty)
        for (name, text) in files {
            for pattern in [#"AIza[0-9A-Za-z_\-]{30,}"#, #"AQ\.[0-9A-Za-z_\-]{30,}"#, #"\bsk_[0-9a-f]{30,}"#] {
                #expect(text.range(of: pattern, options: .regularExpression) == nil, "possible secret in \(name)")
            }
        }
    }

    @Test("log statements never interpolate keys, transcripts, payloads or tool results")
    func noSensitiveLogging() {
        // A sensitive value interpolated directly (its size or kind, e.g. `\(jsonString.utf8.count)`, is fine).
        let names = "apiKey|currentKey|trimmedKey|encodedKey|key|jsonString|transcript|text|preview|payload|payloadData|response|result|stdout|stderr|script|command|callKey|args|content"
        let forbidden = #"print\(.*\\\((\#(names))(\.prefix\([0-9]+\)|\.description)?\)"#
        // The audit must actually bite: known-bad lines match, a size-only line does not.
        for bad in [#"print("k=\(apiKey)")"#, #"print("p: \(preview.prefix(100))")"#, #"print("c \(callKey)")"#] {
            #expect(bad.range(of: forbidden, options: .regularExpression) != nil, "audit misses: \(bad)")
        }
        #expect(#"print("bytes=\(jsonString.utf8.count)")"#.range(of: forbidden, options: .regularExpression) == nil)
        for (name, text) in sourceFiles() {
            for line in text.split(separator: "\n") where line.contains("print(") {
                #expect(line.range(of: forbidden, options: .regularExpression) == nil, "sensitive log in \(name): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
    }

    @Test("Live model and Tavi voice stay locked")
    @MainActor
    func liveLocked() {
        #expect(GeminiLiveClient(apiKey: "test").model == "models/gemini-3.8-live")
        #expect(GeminiLiveVoiceCoordinator.liveVoiceName == "en-us-tavi")
    }
}

// MARK: - Stale session protection (teardown vs. rapid restart)

/// Microphone whose `stopCapture` suspends until released, to hold a teardown mid-flight.
private final class GatedStopCapture: AudioCaptureProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var holdNextStop = false
    private(set) var capturing = false
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?

    func holdStops() { lock.withLock { holdNextStop = true } }
    var isHeld: Bool { lock.withLock { gate != nil } }
    func release() {
        let g = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { gate = nil }; return gate }
        g?.resume()
    }

    func requestPermission() async -> Bool { true }
    func startCapture() async throws -> AsyncThrowingStream<Data, Error> {
        let (stream, cont) = AsyncThrowingStream<Data, Error>.makeStream()
        lock.withLock { capturing = true; continuation = cont }
        return stream
    }
    func stopCapture() async {
        // Holds exactly one stop; later stops (e.g. the restart's own stop) pass straight through.
        let hold = lock.withLock { () -> Bool in defer { holdNextStop = false }; return holdNextStop }
        if hold { await withCheckedContinuation { c in lock.withLock { gate = c } } }
        let cont = lock.withLock { () -> AsyncThrowingStream<Data, Error>.Continuation? in
            capturing = false; defer { continuation = nil }; return continuation
        }
        cont?.finish()
    }
}

@Suite("Phase 5F - Stale session protection")
@MainActor
struct Phase5StaleSessionTests {
    @Test("a session started while the previous teardown is in flight is never torn down by it")
    func restartDuringTeardown() async throws {
        let session = MockGeminiLiveSession()
        let capture = GatedStopCapture()
        let c = GeminiLiveVoiceCoordinator(session: session, audioCapture: capture, audioPlayer: MockLiveAudioPlayer(), wakeWordDetector: MockWakeWordDetector())
        await c.startSession()
        #expect(c.state == .listening)

        capture.holdStops()
        let stop = Task { await c.stopSession() }
        for _ in 0..<400 where !capture.isHeld { try await Task.sleep(nanoseconds: 5_000_000) }
        try #require(capture.isHeld)

        let start = Task { await c.startSession() }
        // Give the restart task a bounded chance to reach its teardown wait under parallel test load.
        for _ in 0..<100 {
            if c.state != .listening { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(capture.isHeld)
        #expect(c.state != .listening) // the new session waits for the old teardown

        capture.release()
        await stop.value
        await start.value
        #expect(c.state == .listening)
        #expect(capture.capturing)
        #expect(session.isConnected)
        await c.stopSession()
    }
}
