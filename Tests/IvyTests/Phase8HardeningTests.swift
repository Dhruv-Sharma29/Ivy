import Testing
import Foundation
import os
@testable import IvyCore

// MARK: - 8.2 Quota & rate limits

/// Own URLProtocol stub (separate static handler from other suites, so parallel suites can't interfere).
final class Phase8URLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, body) = Self.handler?(request) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Phase8URLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Scripted Gemini client: throws the queued errors in order, then replies.
final class ScriptedGeminiClient: GeminiClientProtocol, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (errors: [GeminiClientError](), calls: 0))
    init(errors: [GeminiClientError]) { state.withLock { $0.errors = errors } }
    var calls: Int { state.withLock { $0.calls } }

    func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
    func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
        let error = state.withLock { s -> GeminiClientError? in
            s.calls += 1
            return s.errors.isEmpty ? nil : s.errors.removeFirst()
        }
        if let error { throw error }
        return ModelTurnResponse(text: "Fine.")
    }
}

/// Mutable clock for tests.
final class TestClock: @unchecked Sendable {
    private let value = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_790_000_000))
    var now: Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@Suite("Phase 8.2 - Quota & rate limits", .serialized)
struct Phase8QuotaTests {
    private static let dailyBody = Data(#"{"error":{"code":429,"status":"RESOURCE_EXHAUSTED","details":[{"violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]},{"retryDelay":"34s"}]}}"#.utf8)
    private static func minuteBody(_ delay: String) -> Data {
        Data(#"{"error":{"code":429,"details":[{"violations":[{"quotaId":"GenerateRequestsPerMinutePerProjectPerModel"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"\#(delay)"}]}}"#.utf8)
    }
    private static let okBody = Data(#"{"candidates":[{"content":{"parts":[{"text":"All good."}],"role":"model"},"finishReason":"STOP"}]}"#.utf8)

    @Test("429 bodies are parsed for quota kind and server retry delay")
    func parsing() {
        #expect(QuotaStatus.parse(responseBody: Self.dailyBody).isDaily)
        let minute = QuotaStatus.parse(responseBody: Self.minuteBody("3.175093061s"))
        #expect(!minute.isDaily)
        #expect(abs((minute.retryDelay ?? 0) - 3.175) < 0.01)
        #expect(QuotaStatus.parse(responseBody: Data("Rate limited".utf8)).retryDelay == nil)
    }

    @Test("daily reset is the next midnight Pacific; messages never go negative")
    func resetAndMessages() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let reset = QuotaStatus.nextDailyReset(after: now)
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        #expect(reset > now && reset.timeIntervalSince(now) <= 86_400)
        #expect(pacific.component(.hour, from: reset) == 0 && pacific.component(.minute, from: reset) == 0)

        let minute = QuotaStatus(kind: .perMinute, retryAfter: now.addingTimeInterval(41.2))
        #expect(minute.message(now: now).contains("42 s"))
        #expect(minute.isActive(now: now) && !minute.isActive(now: now.addingTimeInterval(60)))
        #expect(!minute.message(now: now.addingTimeInterval(60)).contains("-"))
        #expect(QuotaStatus(kind: .perDay, retryAfter: reset).message(now: now).contains("resets at"))
    }

    @Test("a short server-requested delay is waited out, then the request succeeds")
    func shortDelayHonoured() async throws {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var waits: [TimeInterval] = []
        Phase8URLProtocol.handler = { _ in
            attempts += 1
            return attempts == 1 ? (429, Self.minuteBody("2s")) : (200, Self.okBody)
        }
        let client = URLSessionGeminiClient(session: Phase8URLProtocol.session(), retryPolicy: .testing(maxRetries: 3) { waits.append($0) })
        let reply = try await client.generateContent(history: [ChatMessage(role: .user, text: "hi")], systemPrompt: "s", apiKey: "k")
        #expect(reply == "All good.")
        #expect(attempts == 2)
        #expect(waits == [2])
    }

    @Test("a long server-requested delay is surfaced immediately, not slept through")
    func longDelaySurfaced() async {
        nonisolated(unsafe) var attempts = 0
        Phase8URLProtocol.handler = { _ in attempts += 1; return (429, Self.minuteBody("57s")) }
        let client = URLSessionGeminiClient(session: Phase8URLProtocol.session(), retryPolicy: .testing(maxRetries: 3))
        await #expect(throws: GeminiClientError.rateLimitedRetry(after: 57)) {
            _ = try await client.generateContent(history: [ChatMessage(role: .user, text: "hi")], systemPrompt: "s", apiKey: "k")
        }
        #expect(attempts == 1)
    }

    @Test("after the daily quota is hit the brain stops calling Gemini until the reset, then recovers")
    @MainActor
    func brainStopsSpendingRequests() async {
        let clock = TestClock()
        let client = ScriptedGeminiClient(errors: [.dailyQuotaExhausted])
        let brain = IvyBrain(client: client, apiKey: "k", now: { clock.now })

        await brain.send("one")
        #expect(brain.quotaStatus?.kind == .perDay)
        #expect(client.calls == 1)

        await brain.send("two")                       // still exhausted: no request is made
        #expect(client.calls == 1)
        #expect(brain.messages.last?.isError == true)
        #expect(brain.messages.last?.text.contains("quota") == true)

        clock.advance(86_400)                         // past the reset
        await brain.send("three")
        #expect(client.calls == 2)
        #expect(brain.quotaStatus == nil)
        #expect(brain.messages.last?.text == "Fine.")
    }

    @Test("a per-minute limit shows a countdown and clears after it passes")
    @MainActor
    func brainPerMinute() async {
        let clock = TestClock()
        let client = ScriptedGeminiClient(errors: [.rateLimitedRetry(after: 40)])
        let brain = IvyBrain(client: client, apiKey: "k", now: { clock.now })
        await brain.send("one")
        #expect(brain.quotaStatus == QuotaStatus(kind: .perMinute, retryAfter: clock.now.addingTimeInterval(40)))
        await brain.send("two")
        #expect(client.calls == 1)
        clock.advance(41)
        await brain.send("three")
        #expect(client.calls == 2 && brain.quotaStatus == nil)
    }
}

// MARK: - 8.1 Live reconnect

private struct OfflinePath: NetworkPathChecking {
    func waitUntilOnline(timeout: Duration) async -> Bool { false }
}

@Suite("Phase 8.1 - Live reconnect")
@MainActor
struct Phase8ReconnectTests {
    private func make(
        attempts: Int = 3,
        path: NetworkPathChecking = AlwaysOnlineNetworkPath(),
        dispatcher: ToolDispatcher? = nil
    ) -> (GeminiLiveVoiceCoordinator, MockGeminiLiveSession, MockAudioCapture, MockLiveAudioPlayer) {
        let session = MockGeminiLiveSession()
        let capture = MockAudioCapture()
        let player = MockLiveAudioPlayer(autoDrain: false)
        let c = GeminiLiveVoiceCoordinator(
            session: session, audioCapture: capture, audioPlayer: player, wakeWordDetector: MockWakeWordDetector(),
            toolDispatcher: dispatcher, maxReconnectAttempts: attempts, reconnectBaseDelay: .milliseconds(1),
            reconnectOfflineGrace: .milliseconds(20), networkPath: path
        )
        return (c, session, capture, player)
    }

    private func isError(_ c: GeminiLiveVoiceCoordinator) -> Bool {
        if case .error = c.state { return true }
        return false
    }

    /// Starts a session and waits until the server acknowledged setup (only established sessions reconnect).
    private func establish(_ c: GeminiLiveVoiceCoordinator) async {
        await c.startSession()
        await waitUntil { c.latency.setupAck != nil }
    }

    @Test("a dropped socket reconnects and returns to LISTENING with the mic still running")
    func reconnects() async {
        let (c, session, capture, _) = make()
        var states: [String] = []
        let sub = c.$state.sink { states.append($0.debugName) }
        defer { sub.cancel() }
        await establish(c)

        session.simulateError(LiveError.connectionFailed("socket reset"))
        #expect(await waitUntil { states.contains("RECONNECTING") && c.state == .listening })
        #expect(session.isConnected)
        #expect(capture.isCapturing)
        #expect(capture.startCaptureCallCount == 1)

        let chunk = Data([0x00, 0x40])
        capture.simulateAudioChunk(chunk)
        #expect(await waitUntil { session.sentAudioChunks.contains(chunk) })
        await c.stopSession()
    }

    @Test("audio queued from the dead connection is dropped, not replayed")
    func dropsStaleAudio() async {
        let (c, session, _, player) = make()
        await establish(c)
        session.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        await waitUntil { c.state == .speaking }

        session.simulateError(LiveError.sessionClosed)
        #expect(await waitUntil { c.state == .listening })
        #expect(player.isStopped)
        await c.stopSession()
    }

    @Test("a confirmation pending when the socket drops is denied; the tool never runs")
    func deniesPendingConfirmation() async {
        let shell = MockShellExecutor()
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [RunShellTool(executor: shell)]),
                                        safetyGate: InteractiveSafetyGate(confirmationProvider: ConfirmationBridge()))
        let (c, session, _, _) = make(dispatcher: dispatcher)
        await establish(c)
        session.simulateToolCall(FunctionCall(name: "run_shell", args: ["command": "echo drop"], id: "r1"))
        #expect(await waitUntil { c.state == .toolConfirmation })

        session.simulateError(LiveError.connectionFailed("socket reset"))
        #expect(await waitUntil { c.state == .listening })
        #expect(c.pendingConfirmation == nil)
        #expect(shell.recordedCommands.isEmpty)
        await c.stopSession()
    }

    @Test("authentication, quota and policy failures are never retried")
    func permanentErrorsDoNotReconnect() async {
        let (c, session, capture, _) = make()
        var states: [String] = []
        let sub = c.$state.sink { states.append($0.debugName) }
        defer { sub.cancel() }
        await establish(c)
        session.simulateError(LiveError.serverError("Quota exceeded: RESOURCE_EXHAUSTED"))
        #expect(await waitUntil { isError(c) })
        #expect(!states.contains("RECONNECTING"))
        #expect(!capture.isCapturing)
    }

    @Test("when every attempt fails the session ends in a clear error and releases the mic")
    func exhaustsAttempts() async {
        let (c, session, capture, _) = make(attempts: 3)
        var reconnects: [Int] = []
        let sub = c.$state.sink { if case .reconnecting(let n) = $0 { reconnects.append(n) } }
        defer { sub.cancel() }
        await establish(c)
        session.setConnectError(LiveError.connectionFailed("network down"))
        session.simulateError(LiveError.connectionFailed("socket reset"))
        #expect(await waitUntil { isError(c) })
        #expect(reconnects == [1, 2, 3])
        if case .error(let message) = c.state { #expect(message.contains("Lost connection")) }
        #expect(!capture.isCapturing)
    }

    @Test("offline: waits for the network instead of burning attempts, then reports offline")
    func offline() async {
        let (c, session, _, _) = make(attempts: 4, path: OfflinePath())
        var reconnects: [Int] = []
        let sub = c.$state.sink { if case .reconnecting(let n) = $0 { reconnects.append(n) } }
        defer { sub.cancel() }
        await establish(c)
        session.simulateError(LiveError.sessionClosed)
        #expect(await waitUntil { isError(c) })
        #expect(reconnects == [1])
        if case .error(let message) = c.state { #expect(message.contains("offline")) }
    }

    @Test("a first connect that fails is reported immediately (nothing to reconnect to)")
    func initialFailureNotRetried() async {
        let (c, session, _, _) = make()
        session.setConnectError(LiveError.connectionFailed("no route"))
        await c.startSession()
        #expect(isError(c))
    }

    @Test("stopping during a reconnect ends cleanly in IDLE")
    func stopDuringReconnect() async {
        let (c, session, capture, _) = make(attempts: 4, path: AlwaysOnlineNetworkPath())
        await establish(c)
        session.setConnectError(LiveError.connectionFailed("network down"))
        session.simulateError(LiveError.sessionClosed)
        await waitUntil { if case .reconnecting = c.state { return true }; return false }
        await c.stopSession()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(c.state == .idle)
        #expect(!capture.isCapturing)
    }

    @Test("recoverability classification")
    func classification() {
        #expect(LiveError.sessionClosed.isRecoverable)
        #expect(LiveError.timeout("setup").isRecoverable)
        #expect(LiveError.connectionFailed("Socket is not connected").isRecoverable)
        #expect(LiveError.serverError("Failed to send audio chunk: broken pipe").isRecoverable)
        #expect(!LiveError.connectionFailed("closed (close code 1008: API key not valid)").isRecoverable)
        #expect(!LiveError.serverError("Quota exceeded").isRecoverable)
        #expect(!LiveError.missingAPIKey.isRecoverable)
        #expect(!LiveError.microphonePermissionDenied.isRecoverable)
        #expect(GeminiLiveVoiceCoordinator.isRecoverable(URLError(.networkConnectionLost)))
        #expect(!GeminiLiveVoiceCoordinator.isRecoverable(CocoaError(.fileNoSuchFile)))
    }
}

// MARK: - 8.5 Storage & Keychain recovery

/// Keychain whose existing item can't be read or updated (e.g. stale access list) until it is deleted and re-saved.
private final class DamagedKeychain: KeychainStore, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (data: Data?.some(Data("old".utf8)), damaged: true))
    func save(_ data: Data, for key: CredentialKey) throws {
        try state.withLock { s in
            guard s.data == nil else { throw KeychainError.duplicateItem }
            s.data = data
            s.damaged = false
        }
    }
    func read(_ key: CredentialKey) throws -> Data {
        try state.withLock { s in
            guard let data = s.data else { throw KeychainError.itemNotFound }
            if s.damaged { throw KeychainError.accessDenied }
            return data
        }
    }
    func update(_ data: Data, for key: CredentialKey) throws {
        try state.withLock { s in
            if s.damaged { throw KeychainError.accessDenied }
            s.data = data
        }
    }
    func delete(_ key: CredentialKey) throws { state.withLock { $0.data = nil } }
    func exists(_ key: CredentialKey) -> Bool { state.withLock { $0.data != nil } }
}

private struct FailingConversationStore: ConversationStore {
    func save(_ conversation: Conversation) throws { throw CocoaError(.fileWriteOutOfSpace) }
    func load(_ id: UUID) -> Conversation? { nil }
    func update(_ conversation: Conversation) throws { throw CocoaError(.fileWriteOutOfSpace) }
    func delete(_ id: UUID) throws {}
    func list() -> [ConversationSummary] { [] }
}

@Suite("Phase 8.5 - Storage & Keychain recovery")
struct Phase8StorageRecoveryTests {
    @Test("files written before schema versioning still load, and new files record their version")
    func schemaVersioning() throws {
        let dir = makeTemporaryDirectory().appendingPathComponent("Conversations")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileConversationStore(directory: dir)
        let id = UUID()
        let v1 = #"{"id":"\#(id.uuidString)","createdAt":1000,"updatedAt":2000,"messages":[{"id":"\#(UUID().uuidString)","role":"user","text":"hello","timestamp":1500,"isError":false}]}"#
        try Data(v1.utf8).write(to: dir.appendingPathComponent("\(id.uuidString).json"))

        let loaded = try #require(store.load(id))
        #expect(loaded.messages.first?.text == "hello")
        #expect(loaded.schemaVersion == Conversation.currentSchemaVersion)

        try store.save(loaded)
        let raw = String(decoding: try Data(contentsOf: dir.appendingPathComponent("\(id.uuidString).json")), as: UTF8.self)
        #expect(raw.contains("\"schemaVersion\":\(Conversation.currentSchemaVersion)"))
    }

    @Test("a corrupt file is quarantined (not deleted) and reported exactly once")
    func quarantine() throws {
        let root = makeTemporaryDirectory()
        let dir = root.appendingPathComponent("Conversations")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileConversationStore(directory: dir)
        let id = UUID()
        let file = dir.appendingPathComponent("\(id.uuidString).json")
        try Data("{ definitely not json".utf8).write(to: file)

        #expect(store.load(id) == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let quarantined = try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent("Quarantine").path)
        #expect(quarantined.contains { $0.hasSuffix("\(id.uuidString).json") })

        #expect(store.list().isEmpty)                       // no longer fails on every listing
        let notices = store.drainRecoveryNotices()
        #expect(notices.count == 1 && notices[0].contains("set aside"))
        #expect(store.drainRecoveryNotices().isEmpty)
    }

    @Test("a file from a newer Ivy is left in place, skipped, and reported")
    func newerSchema() throws {
        let dir = makeTemporaryDirectory().appendingPathComponent("Conversations")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = FileConversationStore(directory: dir)
        let id = UUID()
        let file = dir.appendingPathComponent("\(id.uuidString).json")
        try Data(#"{"schemaVersion":99,"id":"\#(id.uuidString)","createdAt":1,"updatedAt":2,"messages":[]}"#.utf8).write(to: file)

        #expect(store.load(id) == nil)
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(store.drainRecoveryNotices().first?.contains("newer version") == true)
    }

    @Test("a failed save and a quarantined file are both surfaced to the user")
    @MainActor
    func brainSurfacesStorageProblems() async throws {
        let failing = IvyBrain(client: ScriptedGeminiClient(errors: []), apiKey: "k", conversationStore: FailingConversationStore())
        await failing.send("remember this")
        #expect(failing.storageNotice?.contains("couldn't be saved") == true)
        failing.dismissStorageNotice()
        #expect(failing.storageNotice == nil)

        let root = makeTemporaryDirectory()
        let dir = root.appendingPathComponent("Conversations")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))
        let brain = IvyBrain(client: ScriptedGeminiClient(errors: []), apiKey: "k", conversationStore: FileConversationStore(directory: dir))
        brain.restoreLatestConversation()
        brain.collectStorageNotices()
        #expect(brain.storageNotice?.contains("set aside") == true)
    }

    @Test("an unreadable Keychain item is reported as inaccessible, and saving the key again repairs it")
    @MainActor
    func keychainRecovery() throws {
        let provider = KeychainCredentialProvider(keychain: DamagedKeychain(), environment: [:])
        #expect(provider.source(for: .geminiAPIKey) == .keychainInaccessible)
        #expect(!CredentialSource.keychainInaccessible.isUsable)
        #expect(provider.credential(for: .geminiAPIKey) == nil)

        let brain = IvyBrain(client: ScriptedGeminiClient(errors: []), credentials: provider)
        #expect(!brain.isGeminiKeyConfigured)

        try provider.store("fresh-key-value-123", for: .geminiAPIKey)
        #expect(provider.source(for: .geminiAPIKey) == .keychain)
        #expect(provider.credential(for: .geminiAPIKey) == "fresh-key-value-123")
        brain.refreshCredentialStatus()
        #expect(brain.isGeminiKeyConfigured)
    }

    @Test("an inaccessible Keychain still falls back to the environment")
    func keychainInaccessibleWithEnvironment() {
        let provider = KeychainCredentialProvider(keychain: DamagedKeychain(), environment: ["GEMINI_API_KEY": "env-key-value"])
        #expect(provider.source(for: .geminiAPIKey) == .environment)
        #expect(provider.credential(for: .geminiAPIKey) == "env-key-value")
    }
}

// MARK: - 8.4 Permission recovery, 8.6 Resource invariants, 8.9 Diagnostics

@Suite("Phase 8.4 - Permission recovery")
struct Phase8PermissionTests {
    @Test("every permission deep-links to its own Privacy pane")
    func settingsLinks() {
        let urls = PermissionType.allCases.compactMap(\.settingsURL?.absoluteString)
        #expect(urls.count == PermissionType.allCases.count)
        #expect(Set(urls).count == urls.count)
        // Notifications (added in Phase 11) are managed in their own Settings pane, not under Privacy.
        #expect(urls.filter { !$0.contains("Notifications-Settings") }
            .allSatisfy { $0.hasPrefix("x-apple.systempreferences:com.apple.preference.security?Privacy_") })
        #expect(urls.filter { $0.contains("Notifications-Settings") }.count == 1)
        #expect(PermissionType.microphone.settingsURL?.absoluteString.hasSuffix("Privacy_Microphone") == true)
    }
}

@Suite("Phase 8.6 - Resource invariants")
@MainActor
struct Phase8ResourceTests {
    private func makeCoordinator(reconnect: Int = 0) -> (GeminiLiveVoiceCoordinator, MockGeminiLiveSession, MockAudioCapture, MockLiveAudioPlayer, MockGlobalHotkeyManager) {
        let session = MockGeminiLiveSession()
        let capture = MockAudioCapture()
        let player = MockLiveAudioPlayer(autoDrain: true)
        let hotkey = MockGlobalHotkeyManager()
        let c = GeminiLiveVoiceCoordinator(session: session, audioCapture: capture, audioPlayer: player,
                                           wakeWordDetector: MockWakeWordDetector(), hotkeyManager: hotkey,
                                           maxReconnectAttempts: reconnect, reconnectBaseDelay: .milliseconds(1))
        return (c, session, capture, player, hotkey)
    }

    @Test("30 full sessions leave no task, tap or socket behind")
    func repeatedSessionsLeaveNothingRunning() async {
        let (c, session, capture, _, _) = makeCoordinator()
        for i in 0..<30 {
            await c.startSession()
            session.simulateEvent(.audioChunk(Data([UInt8(i), 0x01])))
            await waitUntil { c.state == .speaking }
            if i % 3 == 0 {
                await c.handleWakePhraseDetected()
            } else {
                session.simulateEvent(.turnComplete)
                await waitUntil { c.state == .listening }
            }
            await c.stopSession()
            #expect(c.activeTaskCount == 0, "cycle \(i) left tasks running")
        }
        #expect(c.state == .idle)
        #expect(!capture.isCapturing)
        #expect(!session.isConnected)
        #expect(capture.startCaptureCallCount == 30)
        #expect(capture.stopCaptureCallCount >= 30)
    }

    @Test("a wake session that times out, and a reconnect that fails, clean up completely")
    func abnormalEndsCleanUp() async {
        let session = MockGeminiLiveSession()
        let capture = MockAudioCapture()
        let c = GeminiLiveVoiceCoordinator(session: session, audioCapture: capture, audioPlayer: MockLiveAudioPlayer(),
                                           wakeWordDetector: MockWakeWordDetector(), wakeSilenceTimeout: .milliseconds(30),
                                           maxReconnectAttempts: 2, reconnectBaseDelay: .milliseconds(1))
        await c.startWakeSession()
        await waitUntil { c.state == .idle }
        #expect(c.activeTaskCount == 0)

        await c.startSession()
        await waitUntil { c.latency.setupAck != nil }
        session.setConnectError(LiveError.connectionFailed("down"))
        session.simulateError(LiveError.sessionClosed)
        await waitUntil { if case .error = c.state { return true }; return false }
        await waitUntil { c.activeTaskCount == 0 }
        #expect(c.activeTaskCount == 0)
        #expect(!capture.isCapturing)
    }

    @Test("core objects deallocate after use (no retain cycles)")
    func noRetainCycles() async {
        weak var weakCoordinator: GeminiLiveVoiceCoordinator?
        weak var weakController: WakeWordController?
        weak var weakBrain: IvyBrain?
        do {
            let (c, session, _, _, _) = makeCoordinator(reconnect: 2)
            let controller = WakeWordController(listener: SilentWakeListener(), coordinator: c)
            let brain = IvyBrain(client: ScriptedGeminiClient(errors: []), apiKey: "k", conversationStore: InMemoryConversationStore())
            try? c.registerHotkey()
            controller.setEnabled(true)
            await c.startSession()
            session.simulateEvent(.audioChunk(Data([0x01, 0x02])))
            await waitUntil { c.state == .speaking }
            await brain.send("hello")
            await controller.shutdown()
            await c.shutdown()
            weakCoordinator = c
            weakController = controller
            weakBrain = brain
        }
        await waitUntil { weakCoordinator == nil && weakController == nil && weakBrain == nil }
        #expect(weakCoordinator == nil)
        #expect(weakController == nil)
        #expect(weakBrain == nil)
    }
}

private final class SilentWakeListener: WakeWordListening, @unchecked Sendable {
    func start(onWake: @escaping @Sendable () -> Void) async throws {}
    func stop() async {}
}

@Suite("Phase 8.9 - Diagnostics export")
struct Phase8DiagnosticsTests {
    @Test("the report describes the setup and contains no secrets")
    func reportIsSafe() {
        let gemini = "AQ.DiagnosticsTestKey_0123456789abcdefghijklmnop"
        let eleven = "sk_0123456789abcdef0123456789abcdef0123456789abcdef"
        let credentials = FixedCredentialProvider([.geminiAPIKey: gemini, .elevenLabsAPIKey: eleven])
        let permissions = MockPermissionManager()
        permissions.setStatus(.denied, for: .microphone)
        let log = """
        [LIVE] connect requested
        request url wss://example/?key=\(gemini)
        header xi-api-key: \(eleven)
        [VOICE] IDLE -> CONNECTING
        """
        let report = DiagnosticsReport.build(settings: .defaults, credentials: credentials, permissions: permissions,
                                             logTail: log, crashReportCount: 2)

        #expect(!report.contains(gemini) && !report.contains(eleven))
        #expect(report.contains(IvyVersion.displayVersion))
        #expect(report.contains("Microphone: denied"))
        #expect(report.contains("Gemini API key: environment variable"))
        #expect(report.contains("wakeWordEnabled: false"))
        #expect(report.contains("Crash/hang reports stored locally: 2"))
        #expect(report.contains("[VOICE] IDLE -> CONNECTING"))
        #expect(report.contains(SecretRedactor.placeholder))
    }

    @Test("a missing log and missing keys are reported plainly")
    func emptyState() {
        let report = DiagnosticsReport.build(settings: .defaults, credentials: FixedCredentialProvider([:]),
                                             permissions: MockPermissionManager(), logTail: nil, crashReportCount: 0)
        #expect(report.contains("Gemini API key: not set"))
        #expect(report.contains("no log file"))
    }

    @Test("log tail keeps only the last lines")
    func tail() throws {
        let url = makeTemporaryDirectory().appendingPathComponent("ivy.log")
        try (1...500).map { "line \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        let tail = try #require(DiagnosticsReport.tail(of: url, maxLines: 10))
        #expect(tail.hasPrefix("line 491") && tail.hasSuffix("line 500"))
        #expect(DiagnosticsReport.tail(of: url.appendingPathExtension("missing")) == nil)
    }
}
