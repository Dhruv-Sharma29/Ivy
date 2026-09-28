import Testing
import Foundation
@testable import IvyCore

// MARK: - Mock URL Protocol for ElevenLabs

final class ElevenLabsMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.recordedRequests.append(request)

        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    static func reset() {
        requestHandler = nil
        recordedRequests = []
    }
}

// MARK: - Test Helpers

private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [ElevenLabsMockURLProtocol.self]
    return URLSession(configuration: config)
}

// MARK: - ElevenLabs Configuration & Key Provider Tests

@Suite("ElevenLabs Configuration & Key Provider Tests")
struct ElevenLabsConfigurationTests {
    @Test("Default configuration has expected values")
    func testDefaultConfiguration() {
        let config = ElevenLabsConfiguration()
        #expect(config.baseURL == "https://api.elevenlabs.io/v1/text-to-speech")
        #expect(config.voiceID == "EXAVITQu4vr4xnSDxMaL")
        #expect(config.modelID == "eleven_turbo_v2_5")
        #expect(config.outputFormat == "mp3_44100_128")
    }

    @Test("Custom configuration preserves customized properties")
    func testCustomConfiguration() {
        let config = ElevenLabsConfiguration(
            baseURL: "https://custom.tts.endpoint/v1",
            voiceID: "voice-ivy-custom",
            modelID: "eleven_multilingual_v2",
            outputFormat: "pcm_16000"
        )
        #expect(config.baseURL == "https://custom.tts.endpoint/v1")
        #expect(config.voiceID == "voice-ivy-custom")
        #expect(config.modelID == "eleven_multilingual_v2")
        #expect(config.outputFormat == "pcm_16000")
    }

    @Test("StaticElevenLabsKeyProvider returns trimmed key or nil for empty")
    func testStaticKeyProvider() {
        let validProvider = StaticElevenLabsKeyProvider(key: "  test_key_123  ")
        #expect(validProvider.getAPIKey() == "test_key_123")

        let emptyProvider = StaticElevenLabsKeyProvider(key: "   ")
        #expect(emptyProvider.getAPIKey() == nil)
    }

    @Test("EnvironmentElevenLabsKeyProvider conforms to ElevenLabsKeyProvider")
    func testEnvironmentKeyProvider() {
        let provider = EnvironmentElevenLabsKeyProvider()
        // If environment variable is not set during test, it cleanly returns nil
        let key = provider.getAPIKey()
        if let key {
            #expect(!key.isEmpty)
        }
    }

    @Test("ConfigurableElevenLabsKeyProvider prioritizes configured key and supports runtime updates")
    func testConfigurableKeyProvider() {
        let provider = ConfigurableElevenLabsKeyProvider(initialKey: "initial_key_123")
        #expect(provider.getAPIKey() == "initial_key_123")

        provider.setAPIKey("updated_key_456")
        #expect(provider.getAPIKey() == "updated_key_456")

        provider.setAPIKey("   ")
        // When cleared, falls back to env key (if present) or nil
        if let envKey = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines), !envKey.isEmpty {
            #expect(provider.getAPIKey() == envKey)
        } else {
            #expect(provider.getAPIKey() == nil)
        }
    }
}

// MARK: - ElevenLabs REST Client Unit Tests

@Suite("ElevenLabs REST Client Unit Tests", .serialized)
struct ElevenLabsSpeechSynthesizerTests {
    @Test("Rejects empty and whitespace-only text")
    func testRejectsEmptyText() async {
        let client = ElevenLabsSpeechSynthesizer(
            keyProvider: StaticElevenLabsKeyProvider(key: "mock_key"),
            session: makeMockSession()
        )

        await #expect(throws: SpeechError.emptyText) {
            _ = try await client.synthesize(text: "")
        }

        await #expect(throws: SpeechError.emptyText) {
            _ = try await client.synthesize(text: "   \n\t  ")
        }
    }

    @Test("Rejects synthesis when API key is missing")
    func testRejectsMissingAPIKey() async {
        let client = ElevenLabsSpeechSynthesizer(
            keyProvider: StaticElevenLabsKeyProvider(key: ""),
            session: makeMockSession()
        )

        await #expect(throws: SpeechError.missingAPIKey) {
            _ = try await client.synthesize(text: "Hello world")
        }
    }

    @Test("Constructs correct HTTP request: headers, URL, output_format, and JSON body")
    func testRequestConstruction() async throws {
        ElevenLabsMockURLProtocol.reset()
        let fakeAudio = Data([0x49, 0x44, 0x33, 0x04]) // Fake ID3/MP3 header

        ElevenLabsMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "audio/mpeg"]
            )!
            return (response, fakeAudio)
        }

        let key = "xi_secret_key_abc123"
        let config = ElevenLabsConfiguration(
            voiceID: "voice_target_99",
            modelID: "eleven_turbo_v2_5",
            outputFormat: "mp3_44100_128"
        )
        let client = ElevenLabsSpeechSynthesizer(
            configuration: config,
            keyProvider: StaticElevenLabsKeyProvider(key: key),
            session: makeMockSession()
        )

        let audio = try await client.synthesize(text: "Ivy is speaking.")
        #expect(audio == fakeAudio)

        #expect(ElevenLabsMockURLProtocol.recordedRequests.count == 1)
        let recorded = ElevenLabsMockURLProtocol.recordedRequests[0]
        #expect(recorded.httpMethod == "POST")
        #expect(recorded.value(forHTTPHeaderField: "xi-api-key") == key)
        #expect(recorded.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(recorded.value(forHTTPHeaderField: "Accept") == "audio/mpeg")

        let urlString = recorded.url?.absoluteString ?? ""
        #expect(urlString.contains("/voice_target_99"))
        #expect(urlString.contains("output_format=mp3_44100_128"))

        // Verify body payload
        let bodyData = recorded.extractBodyData() ?? Data()
        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        #expect(json?["text"] == "Ivy is speaking.")
        #expect(json?["model_id"] == "eleven_turbo_v2_5")
    }

    @Test("HTTP 200 with empty body throws emptyAudioData")
    func testEmptyAudioResponse() async {
        ElevenLabsMockURLProtocol.reset()
        ElevenLabsMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let client = ElevenLabsSpeechSynthesizer(
            keyProvider: StaticElevenLabsKeyProvider(key: "key"),
            session: makeMockSession()
        )

        await #expect(throws: SpeechError.emptyAudioData) {
            _ = try await client.synthesize(text: "Testing empty")
        }
    }

    @Test("HTTP 401/403 maps to invalidAPIKey and sanitizes raw key from error messages")
    func testInvalidAPIKeyMappingAndSanitization() async {
        ElevenLabsMockURLProtocol.reset()
        let secretKey = "super_secret_elevenlabs_key_xyz"
        let errorBody = """
        {"detail":{"status":"invalid_api_key","message":"Invalid API key: \(secretKey)"}}
        """.data(using: .utf8)!

        ElevenLabsMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, errorBody)
        }

        let client = ElevenLabsSpeechSynthesizer(
            keyProvider: StaticElevenLabsKeyProvider(key: secretKey),
            session: makeMockSession()
        )

        do {
            _ = try await client.synthesize(text: "Hello")
            Issue.record("Expected invalidAPIKey error")
        } catch let SpeechError.invalidAPIKey(msg) {
            #expect(!msg.contains(secretKey))
            #expect(msg.contains("[REDACTED_API_KEY]"))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("HTTP 404 maps to voiceNotFound")
    func testVoiceNotFoundMapping() async {
        ElevenLabsMockURLProtocol.reset()
        ElevenLabsMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, "Voice not found".data(using: .utf8)!)
        }

        let config = ElevenLabsConfiguration(voiceID: "missing_voice_id")
        let client = ElevenLabsSpeechSynthesizer(
            configuration: config,
            keyProvider: StaticElevenLabsKeyProvider(key: "key"),
            session: makeMockSession()
        )

        do {
            _ = try await client.synthesize(text: "Test")
            Issue.record("Expected voiceNotFound")
        } catch let SpeechError.voiceNotFound(vId) {
            #expect(vId == "missing_voice_id")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("HTTP 429 maps to rateLimited")
    func testRateLimitedMapping() async {
        ElevenLabsMockURLProtocol.reset()
        ElevenLabsMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, "Quota exceeded".data(using: .utf8)!)
        }

        let client = ElevenLabsSpeechSynthesizer(
            keyProvider: StaticElevenLabsKeyProvider(key: "key"),
            session: makeMockSession()
        )

        await #expect(throws: SpeechError.rateLimited) {
            _ = try await client.synthesize(text: "Rate limit test")
        }
    }

    @Test("HTTP 402 maps to serverError with payment required detail")
    func testPaymentRequired402Mapping() async {
        ElevenLabsMockURLProtocol.reset()
        ElevenLabsMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 402,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = """
            {"detail":{"type":"payment_required","code":"paid_plan_required","message":"Free users cannot use library voices via the API. Please upgrade your subscription to use this voice."}}
            """
            return (response, body.data(using: .utf8)!)
        }

        let client = ElevenLabsSpeechSynthesizer(
            keyProvider: StaticElevenLabsKeyProvider(key: "key"),
            session: makeMockSession()
        )

        do {
            _ = try await client.synthesize(text: "Test 402")
            Issue.record("Expected serverError 402")
        } catch let SpeechError.serverError(statusCode, message) {
            #expect(statusCode == 402)
            #expect(message.contains("Free users cannot use library voices"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("HTTP 500 / 502 / 503 maps to serverError")
    func testServerErrorMapping() async {
        ElevenLabsMockURLProtocol.reset()
        ElevenLabsMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, "ElevenLabs Service Unavailable".data(using: .utf8)!)
        }

        let client = ElevenLabsSpeechSynthesizer(
            keyProvider: StaticElevenLabsKeyProvider(key: "key"),
            session: makeMockSession()
        )

        do {
            _ = try await client.synthesize(text: "Test server error")
            Issue.record("Expected serverError")
        } catch let SpeechError.serverError(code, msg) {
            #expect(code == 503)
            #expect(msg.contains("Service Unavailable"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Network failure maps to networkError")
    func testNetworkFailureMapping() async {
        ElevenLabsMockURLProtocol.reset()
        ElevenLabsMockURLProtocol.requestHandler = { _ in
            throw URLError(.cannotConnectToHost)
        }

        let client = ElevenLabsSpeechSynthesizer(
            keyProvider: StaticElevenLabsKeyProvider(key: "key"),
            session: makeMockSession()
        )

        do {
            _ = try await client.synthesize(text: "Network fail")
            Issue.record("Expected networkError")
        } catch let SpeechError.networkError(desc) {
            #expect(!desc.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("URLError.cancelled maps to SpeechError.cancelled")
    func testCancellationMapping() async {
        ElevenLabsMockURLProtocol.reset()
        ElevenLabsMockURLProtocol.requestHandler = { _ in
            throw URLError(.cancelled)
        }

        let client = ElevenLabsSpeechSynthesizer(
            keyProvider: StaticElevenLabsKeyProvider(key: "key"),
            session: makeMockSession()
        )

        await #expect(throws: SpeechError.cancelled) {
            _ = try await client.synthesize(text: "Cancelled test")
        }
    }
}

// MARK: - Audio Player & Voice Playback Manager Tests

@Suite("Audio Player & Voice Playback Manager Tests")
struct VoicePlaybackManagerTests {
    @Test("MockAudioPlayer records played data and finishes")
    @MainActor
    func testMockAudioPlayer() async throws {
        let player = MockAudioPlayer()
        #expect(!player.isPlaying)

        let fakeAudio = Data([1, 2, 3, 4])
        player.playbackDuration = 0.01
        try await player.play(data: fakeAudio)

        #expect(player.playedData == [fakeAudio])
        #expect(!player.isPlaying)
    }

    @Test("MockAudioPlayer rejects empty data")
    @MainActor
    func testMockAudioPlayerRejectsEmptyData() async {
        let player = MockAudioPlayer()
        await #expect(throws: SpeechError.emptyAudioData) {
            try await player.play(data: Data())
        }
    }

    @Test("VoicePlaybackManager initial state is idle")
    @MainActor
    func testInitialState() {
        let manager = VoicePlaybackManager(
            synthesizer: MockSpeechSynthesizer(),
            player: MockAudioPlayer()
        )
        #expect(manager.state == .idle)
        #expect(manager.currentMessageId == nil)
        #expect(manager.errorMessage == nil)
    }

    @Test("VoicePlaybackManager speaks message, transitions synthesizing -> playing -> idle")
    @MainActor
    func testSuccessfulPlaybackFlow() async throws {
        let mockSynth = MockSpeechSynthesizer()
        let mockPlayer = MockAudioPlayer()
        mockPlayer.playbackDuration = 0.02
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: mockPlayer)

        let message = ChatMessage(role: .model, text: "Here is Ivy's witty response.")

        manager.speak(message: message)

        #expect(manager.currentMessageId == message.id)
        #expect(manager.isSynthesizing(messageId: message.id))

        // Poll instead of a fixed 60ms sleep: a loaded main actor under the full parallel suite can overrun it.
        for _ in 0..<200 where manager.state != .idle { try await Task.sleep(nanoseconds: 5_000_000) }

        #expect(manager.state == .idle)
        #expect(manager.currentMessageId == nil)
        #expect(mockSynth.recordedCalls.count == 1)
        #expect(mockSynth.recordedCalls[0].text == "Here is Ivy's witty response.")
        #expect(mockPlayer.playedData.count == 1)
    }

    @Test("VoicePlaybackManager rejects empty message")
    @MainActor
    func testRejectsEmptyMessage() {
        let manager = VoicePlaybackManager(
            synthesizer: MockSpeechSynthesizer(),
            player: MockAudioPlayer()
        )
        let emptyMsg = ChatMessage(role: .model, text: "   ")
        manager.speak(message: emptyMsg)

        #expect(manager.state == .error("Cannot read empty message."))
        #expect(manager.errorMessage == "Cannot read empty message.")
    }

    @Test("VoicePlaybackManager toggle stops active playback")
    @MainActor
    func testToggleStopsPlayback() async throws {
        let mockSynth = MockSpeechSynthesizer(delayDuration: 0.1)
        let mockPlayer = MockAudioPlayer()
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: mockPlayer)

        let msg = ChatMessage(role: .model, text: "Ivy speaking")
        manager.togglePlayback(for: msg)

        #expect(manager.isPlaying(messageId: msg.id))
        #expect(manager.isSynthesizing(messageId: msg.id))

        // Toggle again should stop it
        manager.togglePlayback(for: msg)

        #expect(manager.state == .idle)
        #expect(!manager.isPlaying(messageId: msg.id))
    }

    @Test("Stop prevents stale audio from playing")
    @MainActor
    func testStopPreventsStaleAudio() async throws {
        let mockSynth = MockSpeechSynthesizer(delayDuration: 0.05)
        let mockPlayer = MockAudioPlayer()
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: mockPlayer)

        let msg = ChatMessage(role: .model, text: "Stale test message")
        manager.speak(message: msg)

        #expect(manager.isSynthesizing(messageId: msg.id))

        // User stops before synthesis completes
        manager.stop()
        #expect(manager.state == .idle)

        // Wait past the synthesis duration
        try await Task.sleep(nanoseconds: 80_000_000)

        // Player must never have played any data
        #expect(mockPlayer.playedData.isEmpty)
        #expect(manager.state == .idle)
    }

    @Test("Switching messages cancels prior message and does not play stale audio")
    @MainActor
    func testSwitchingMessagesCancelsPrior() async throws {
        let mockSynth = MockSpeechSynthesizer(delayDuration: 0.05)
        let mockPlayer = MockAudioPlayer()
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: mockPlayer)

        let msg1 = ChatMessage(role: .model, text: "Message One")
        let msg2 = ChatMessage(role: .model, text: "Message Two")

        manager.speak(message: msg1)
        #expect(manager.currentMessageId == msg1.id)

        // Immediately switch to msg2
        manager.speak(message: msg2)
        #expect(manager.currentMessageId == msg2.id)

        // Wait for msg2 to finish
        // Poll for the expected state instead of a fixed sleep (flaky under full-suite main-actor load).
        for _ in 0..<400 where manager.state != .idle { try? await Task.sleep(nanoseconds: 5_000_000) }

        #expect(manager.state == .idle)
        // Player should only have played once (for msg2)
        #expect(mockPlayer.playedData.count == 1)
    }

    @Test("VoicePlaybackManager handles synthesis error gracefully")
    @MainActor
    func testSynthesisErrorHandling() async throws {
        let mockSynth = MockSpeechSynthesizer(errorToThrow: SpeechError.rateLimited)
        let mockPlayer = MockAudioPlayer()
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: mockPlayer)

        let msg = ChatMessage(role: .model, text: "Rate limit me")
        manager.speak(message: msg)

        // Poll for the expected state instead of a fixed sleep (flaky under full-suite main-actor load).
        for _ in 0..<400 where manager.state != .error(SpeechError.rateLimited.localizedDescription) { try? await Task.sleep(nanoseconds: 5_000_000) }

        #expect(manager.state == .error(SpeechError.rateLimited.localizedDescription))
        #expect(manager.errorMessage == SpeechError.rateLimited.localizedDescription)
        #expect(mockPlayer.playedData.isEmpty)
    }

    // Phase 5: the key is no longer observable manager state; it is resolved by the synthesizer's key provider.
    @Test("VoicePlaybackManager routes an explicit key or the credential provider into the synthesizer")
    @MainActor
    func testVoicePlaybackManagerApiKeyUpdate() {
        let manager = VoicePlaybackManager(apiKey: "initial_123")
        #expect((manager.synthesizer as? ElevenLabsSpeechSynthesizer)?.keyProvider.getAPIKey() == "initial_123")

        let viaCredentials = VoicePlaybackManager(credentials: FixedCredentialProvider([.elevenLabsAPIKey: "new_456"]))
        #expect((viaCredentials.synthesizer as? ElevenLabsSpeechSynthesizer)?.keyProvider.getAPIKey() == "new_456")
    }

    @Test("VoicePlaybackManager clearError resets state and error message")
    @MainActor
    func testVoicePlaybackManagerClearError() async throws {
        let mockSynth = MockSpeechSynthesizer(errorToThrow: SpeechError.missingAPIKey)
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: MockAudioPlayer())

        manager.speak(message: ChatMessage(role: .model, text: "Fail now"))
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(manager.errorMessage != nil)
        if case .error = manager.state {
            // expected
        } else {
            Issue.record("Expected error state")
        }

        manager.clearError()
        #expect(manager.errorMessage == nil)
        #expect(manager.state == .idle)
    }

    @Test("VoicePlaybackManager stop resets error state to idle")
    @MainActor
    func testVoicePlaybackManagerStopResetsErrorState() async throws {
        let mockSynth = MockSpeechSynthesizer(errorToThrow: SpeechError.rateLimited)
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: MockAudioPlayer())

        manager.speak(message: ChatMessage(role: .model, text: "Fail now"))
        // Poll for the expected state instead of a fixed sleep (flaky under full-suite main-actor load).
        for _ in 0..<400 where manager.state != .error(SpeechError.rateLimited.localizedDescription) { try? await Task.sleep(nanoseconds: 5_000_000) }

        #expect(manager.state == .error(SpeechError.rateLimited.localizedDescription))

        manager.stop()
        #expect(manager.state == .idle)
    }
}
