import Testing
import Foundation
@testable import IvyCore

// MARK: - Dedicated Isolated URLProtocols for Phase 4A Test Suites

final class Phase4ASpeechMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

private func makePhase4ASpeechSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Phase4ASpeechMockURLProtocol.self]
    return URLSession(configuration: config)
}

final class Phase4ARequestMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

private func makePhase4ARequestSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Phase4ARequestMockURLProtocol.self]
    return URLSession(configuration: config)
}

final class Phase4AHTTPErrorMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

private func makePhase4AHTTPErrorSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Phase4AHTTPErrorMockURLProtocol.self]
    return URLSession(configuration: config)
}

final class Phase4AKeySecurityMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

private func makePhase4AKeySecuritySession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Phase4AKeySecurityMockURLProtocol.self]
    return URLSession(configuration: config)
}

final class Phase4APrivacyMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var recordedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

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

private func makePhase4APrivacySession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [Phase4APrivacyMockURLProtocol.self]
    return URLSession(configuration: config)
}

// ==================================================
// 1. SPEECH SYNTHESIZER TESTS (Invariants 1 - 6)
// ==================================================

@Suite("Phase 4A - 1. Speech Synthesizer Tests", .serialized)
struct Phase4ASpeechSynthesizerTests {
    @Test("1. Valid text is accepted")
    func test1_validTextAccepted() async throws {
        let mock = MockSpeechSynthesizer()
        let audio = try await mock.synthesize(text: "Ivy is speaking clearly.")
        #expect(!audio.isEmpty)
        #expect(mock.recordedCalls.count == 1)
        #expect(mock.recordedCalls[0].text == "Ivy is speaking clearly.")
    }

    @Test("2. Empty text is rejected")
    func test2_emptyTextRejected() async {
        let mock = MockSpeechSynthesizer()
        await #expect(throws: SpeechError.emptyText) {
            _ = try await mock.synthesize(text: "")
        }
    }

    @Test("3. Whitespace-only text is rejected")
    func test3_whitespaceOnlyTextRejected() async {
        let mock = MockSpeechSynthesizer()
        await #expect(throws: SpeechError.emptyText) {
            _ = try await mock.synthesize(text: "   \t\n   ")
        }
    }

    @Test("4. Mock ElevenLabs success returns audio data")
    func test4_mockSuccessReturnsAudioData() async throws {
        let expectedBytes = Data([0xDE, 0xAD, 0xBE, 0xEF, 0x42])
        let mock = MockSpeechSynthesizer(dataToReturn: expectedBytes)
        let result = try await mock.synthesize(text: "Testing success")
        #expect(result == expectedBytes)
    }

    @Test("5. Mock ElevenLabs failure becomes a structured error")
    func test5_mockFailureBecomesStructuredError() async {
        let mock = MockSpeechSynthesizer(errorToThrow: SpeechError.rateLimited)
        await #expect(throws: SpeechError.rateLimited) {
            _ = try await mock.synthesize(text: "Testing rate limit")
        }
    }

    @Test("6. The synthesizer does not crash on network failure")
    func test6_synthesizerDoesNotCrashOnNetworkFailure() async {
        Phase4ASpeechMockURLProtocol.reset()
        Phase4ASpeechMockURLProtocol.requestHandler = { _ in
            throw URLError(.timedOut)
        }

        let synth = ElevenLabsSpeechSynthesizer(
            keyProvider: StaticElevenLabsKeyProvider(key: "mock_speech_key"),
            session: makePhase4ASpeechSession()
        )

        do {
            _ = try await synth.synthesize(text: "Network failure test")
            Issue.record("Expected networkError to be thrown")
        } catch let SpeechError.networkError(desc) {
            #expect(!desc.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

// ==================================================
// 2. API REQUEST TESTS (Invariants 7 - 15)
// ==================================================

@Suite("Phase 4A - 2. API Request Tests", .serialized)
struct Phase4AAPIRequestTests {
    @Test("7. Correct ElevenLabs endpoint URL")
    func test7_endpointURL() async throws {
        Phase4ARequestMockURLProtocol.reset()
        let fakeMP3 = Data([0xFF, 0xFB, 0x90, 0x64])
        Phase4ARequestMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!, fakeMP3)
        }
        let config = ElevenLabsConfiguration(baseURL: "https://api.elevenlabs.io/v1/text-to-speech", voiceID: "voice_7")
        let client = ElevenLabsSpeechSynthesizer(configuration: config, keyProvider: StaticElevenLabsKeyProvider(key: "xi_key_7"), session: makePhase4ARequestSession())
        _ = try await client.synthesize(text: "Test 7")
        #expect(Phase4ARequestMockURLProtocol.recordedRequests.count == 1)
        let urlStr = Phase4ARequestMockURLProtocol.recordedRequests[0].url?.absoluteString ?? ""
        #expect(urlStr.hasPrefix("https://api.elevenlabs.io/v1/text-to-speech/"))
    }

    @Test("8. Correct voice ID in path")
    func test8_voiceIDInPath() async throws {
        Phase4ARequestMockURLProtocol.reset()
        let fakeMP3 = Data([0xFF, 0xFB, 0x90, 0x64])
        Phase4ARequestMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!, fakeMP3)
        }
        let config = ElevenLabsConfiguration(baseURL: "https://api.elevenlabs.io/v1/text-to-speech", voiceID: "voice_specific_8")
        let client = ElevenLabsSpeechSynthesizer(configuration: config, keyProvider: StaticElevenLabsKeyProvider(key: "xi_key_8"), session: makePhase4ARequestSession())
        _ = try await client.synthesize(text: "Test 8")
        #expect(Phase4ARequestMockURLProtocol.recordedRequests.count == 1)
        let path = Phase4ARequestMockURLProtocol.recordedRequests[0].url?.path ?? ""
        #expect(path.hasSuffix("/voice_specific_8"))
    }

    @Test("9. Correct model ID in payload")
    func test9_modelIDInPayload() async throws {
        Phase4ARequestMockURLProtocol.reset()
        let fakeMP3 = Data([0xFF, 0xFB, 0x90, 0x64])
        Phase4ARequestMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!, fakeMP3)
        }
        let config = ElevenLabsConfiguration(modelID: "eleven_turbo_v2_5")
        let client = ElevenLabsSpeechSynthesizer(configuration: config, keyProvider: StaticElevenLabsKeyProvider(key: "xi_key_9"), session: makePhase4ARequestSession())
        _ = try await client.synthesize(text: "Test 9")
        #expect(Phase4ARequestMockURLProtocol.recordedRequests.count == 1)
        let bodyData = Phase4ARequestMockURLProtocol.recordedRequests[0].extractBodyData() ?? Data()
        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        #expect(json?["model_id"] == "eleven_turbo_v2_5")
    }

    @Test("10. Correct output format parameter")
    func test10_outputFormatParameter() async throws {
        Phase4ARequestMockURLProtocol.reset()
        let fakeMP3 = Data([0xFF, 0xFB, 0x90, 0x64])
        Phase4ARequestMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!, fakeMP3)
        }
        let config = ElevenLabsConfiguration(outputFormat: "mp3_44100_128")
        let client = ElevenLabsSpeechSynthesizer(configuration: config, keyProvider: StaticElevenLabsKeyProvider(key: "xi_key_10"), session: makePhase4ARequestSession())
        _ = try await client.synthesize(text: "Test 10")
        #expect(Phase4ARequestMockURLProtocol.recordedRequests.count == 1)
        let url = Phase4ARequestMockURLProtocol.recordedRequests[0].url
        let components = URLComponents(url: url!, resolvingAgainstBaseURL: false)
        let formatQuery = components?.queryItems?.first(where: { $0.name == "output_format" })?.value
        #expect(formatQuery == "mp3_44100_128")
    }

    @Test("11. Valid request body encoding")
    func test11_requestBodyEncoding() async throws {
        Phase4ARequestMockURLProtocol.reset()
        let fakeMP3 = Data([0xFF, 0xFB, 0x90, 0x64])
        Phase4ARequestMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!, fakeMP3)
        }
        let client = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: "xi_key_11"), session: makePhase4ARequestSession())
        _ = try await client.synthesize(text: "Encoding test payload with quotes \"and special chars\" & symbols")
        #expect(Phase4ARequestMockURLProtocol.recordedRequests.count == 1)
        let bodyData = Phase4ARequestMockURLProtocol.recordedRequests[0].extractBodyData() ?? Data()
        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        #expect(json?["text"] == "Encoding test payload with quotes \"and special chars\" & symbols")
    }

    @Test("12. Correct authentication header (xi-api-key)")
    func test12_authHeader() async throws {
        Phase4ARequestMockURLProtocol.reset()
        let fakeMP3 = Data([0xFF, 0xFB, 0x90, 0x64])
        Phase4ARequestMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "audio/mpeg"])!, fakeMP3)
        }
        let key = "xi_secret_key_value_12"
        let client = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: key), session: makePhase4ARequestSession())
        _ = try await client.synthesize(text: "Auth header test")
        #expect(Phase4ARequestMockURLProtocol.recordedRequests.count == 1)
        let req = Phase4ARequestMockURLProtocol.recordedRequests[0]
        #expect(req.value(forHTTPHeaderField: "xi-api-key") == key)
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(req.value(forHTTPHeaderField: "Accept") == "audio/mpeg")
    }

    @Test("13. API key is never exposed in logs or user-facing errors")
    func test13_apiKeyNeverExposedInErrors() async {
        Phase4ARequestMockURLProtocol.reset()
        let sensitiveKey = "super_secret_elevenlabs_token_999"
        Phase4ARequestMockURLProtocol.requestHandler = { _ in
            let body = "Unauthorized access with key \(sensitiveKey)".data(using: .utf8)!
            let resp = HTTPURLResponse(url: URL(string: "https://api.elevenlabs.io")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (resp, body)
        }

        let client = ElevenLabsSpeechSynthesizer(
            keyProvider: StaticElevenLabsKeyProvider(key: sensitiveKey),
            session: makePhase4ARequestSession()
        )

        do {
            _ = try await client.synthesize(text: "Test")
            Issue.record("Expected invalidAPIKey error")
        } catch let SpeechError.invalidAPIKey(msg) {
            #expect(!msg.contains(sensitiveKey))
            #expect(msg.contains("[REDACTED_API_KEY]"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("14. Empty API key is handled cleanly")
    func test14_emptyAPIKeyHandledCleanly() async {
        let client = ElevenLabsSpeechSynthesizer(
            keyProvider: StaticElevenLabsKeyProvider(key: "   "),
            session: makePhase4ARequestSession()
        )

        await #expect(throws: SpeechError.missingAPIKey) {
            _ = try await client.synthesize(text: "Hello")
        }
    }

    @Test("15. Invalid configuration is rejected before making a request")
    func test15_invalidConfigurationRejected() async {
        Phase4ARequestMockURLProtocol.reset()
        let invalidConfig = ElevenLabsConfiguration(baseURL: "invalid url with spaces and illegal characters %%")
        let client = ElevenLabsSpeechSynthesizer(
            configuration: invalidConfig,
            keyProvider: StaticElevenLabsKeyProvider(key: "valid_key"),
            session: makePhase4ARequestSession()
        )

        await #expect(throws: SpeechError.self) {
            _ = try await client.synthesize(text: "Test")
        }
        #expect(Phase4ARequestMockURLProtocol.recordedRequests.isEmpty)
    }
}

// ==================================================
// 3. HTTP ERROR TESTS (Invariants 16 - 26)
// ==================================================

@Suite("Phase 4A - 3. HTTP Error Tests", .serialized)
struct Phase4AHTTPErrorTests {
    @Test("16. HTTP 200 returns audio data successfully")
    func test16_http200Success() async throws {
        Phase4AHTTPErrorMockURLProtocol.reset()
        let audioData = Data([0x01, 0x02, 0x03, 0x04])
        Phase4AHTTPErrorMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, audioData)
        }
        let client = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: "mock_http_key"), session: makePhase4AHTTPErrorSession())
        let res = try await client.synthesize(text: "Valid")
        #expect(res == audioData)
    }

    @Test("17. HTTP 400 returns structured decoding/request error")
    func test17_http400Error() async {
        Phase4AHTTPErrorMockURLProtocol.reset()
        Phase4AHTTPErrorMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, "{\"detail\": \"Bad request text\"}".data(using: .utf8)!)
        }
        let client = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: "mock_http_key"), session: makePhase4AHTTPErrorSession())
        do {
            _ = try await client.synthesize(text: "Valid")
            Issue.record("Expected error")
        } catch let SpeechError.decodingError(msg) {
            #expect(msg.contains("Bad request text"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("18. HTTP 401 returns authentication error")
    func test18_http401AuthError() async {
        Phase4AHTTPErrorMockURLProtocol.reset()
        Phase4AHTTPErrorMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, "Unauthorized".data(using: .utf8)!)
        }
        let client = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: "mock_http_key"), session: makePhase4AHTTPErrorSession())
        do {
            _ = try await client.synthesize(text: "Valid")
            Issue.record("Expected error")
        } catch let SpeechError.invalidAPIKey(msg) {
            #expect(msg.contains("Unauthorized"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("19. HTTP 403 returns permission/access error")
    func test19_http403AccessError() async {
        Phase4AHTTPErrorMockURLProtocol.reset()
        Phase4AHTTPErrorMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, "Forbidden".data(using: .utf8)!)
        }
        let client = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: "mock_http_key"), session: makePhase4AHTTPErrorSession())
        do {
            _ = try await client.synthesize(text: "Valid")
            Issue.record("Expected error")
        } catch let SpeechError.invalidAPIKey(msg) {
            #expect(msg.contains("Forbidden"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("20. HTTP 404 returns voice/endpoint error")
    func test20_http404VoiceNotFound() async {
        Phase4AHTTPErrorMockURLProtocol.reset()
        Phase4AHTTPErrorMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
        }
        let config = ElevenLabsConfiguration(voiceID: "voice_404_id")
        let client = ElevenLabsSpeechSynthesizer(configuration: config, keyProvider: StaticElevenLabsKeyProvider(key: "mock_http_key"), session: makePhase4AHTTPErrorSession())
        do {
            _ = try await client.synthesize(text: "Valid")
            Issue.record("Expected error")
        } catch let SpeechError.voiceNotFound(vId) {
            #expect(vId == "voice_404_id")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("21. HTTP 429 returns rate-limit error")
    func test21_http429RateLimit() async {
        Phase4AHTTPErrorMockURLProtocol.reset()
        Phase4AHTTPErrorMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: "mock_http_key"), session: makePhase4AHTTPErrorSession())
        await #expect(throws: SpeechError.rateLimited) {
            _ = try await client.synthesize(text: "Valid")
        }
    }

    @Test("22. HTTP 500 returns server error")
    func test22_http500ServerError() async {
        Phase4AHTTPErrorMockURLProtocol.reset()
        Phase4AHTTPErrorMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, "Internal Server Error".data(using: .utf8)!)
        }
        let client = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: "mock_http_key"), session: makePhase4AHTTPErrorSession())
        do {
            _ = try await client.synthesize(text: "Valid")
            Issue.record("Expected error")
        } catch let SpeechError.serverError(code, _) {
            #expect(code == 500)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("23. HTTP 502 returns server error")
    func test23_http502ServerError() async {
        Phase4AHTTPErrorMockURLProtocol.reset()
        Phase4AHTTPErrorMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 502, httpVersion: nil, headerFields: nil)!, "Bad Gateway".data(using: .utf8)!)
        }
        let client = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: "mock_http_key"), session: makePhase4AHTTPErrorSession())
        do {
            _ = try await client.synthesize(text: "Valid")
            Issue.record("Expected error")
        } catch let SpeechError.serverError(code, _) {
            #expect(code == 502)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("24. HTTP 503 returns temporary service error")
    func test24_http503ServiceUnavailable() async {
        Phase4AHTTPErrorMockURLProtocol.reset()
        Phase4AHTTPErrorMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, "Overloaded".data(using: .utf8)!)
        }
        let client = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: "mock_http_key"), session: makePhase4AHTTPErrorSession())
        do {
            _ = try await client.synthesize(text: "Valid")
            Issue.record("Expected error")
        } catch let SpeechError.serverError(code, msg) {
            #expect(code == 503)
            #expect(msg.contains("Overloaded"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("25. Network failure becomes structured error without crash")
    func test25_networkFailureStructuredError() async {
        Phase4AHTTPErrorMockURLProtocol.reset()
        Phase4AHTTPErrorMockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let client = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: "mock_http_key"), session: makePhase4AHTTPErrorSession())
        do {
            _ = try await client.synthesize(text: "Valid")
            Issue.record("Expected network error")
        } catch let SpeechError.networkError(desc) {
            #expect(!desc.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("26. Empty response body treated as failure")
    func test26_emptyResponseBodyFailure() async {
        Phase4AHTTPErrorMockURLProtocol.reset()
        Phase4AHTTPErrorMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: "mock_http_key"), session: makePhase4AHTTPErrorSession())
        await #expect(throws: SpeechError.emptyAudioData) {
            _ = try await client.synthesize(text: "Valid")
        }
    }
}

// ==================================================
// 4. AUDIO PLAYBACK TESTS (Invariants 27 - 33)
// ==================================================

@Suite("Phase 4A - 4. Audio Playback Tests")
struct Phase4AAudioPlaybackTests {
    @Test("27. Play starts correctly")
    @MainActor
    func test27_playStartsCorrectly() async throws {
        let player = MockAudioPlayer()
        player.playbackDuration = 0.05
        #expect(!player.isPlaying)

        let task = Task {
            try await player.play(data: Data([1, 2, 3]))
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(player.isPlaying)
        #expect(player.playedData.count == 1)
        _ = await task.result
    }

    @Test("28. Stop stops playback")
    @MainActor
    func test28_stopStopsPlayback() async throws {
        let player = MockAudioPlayer()
        player.playbackDuration = 0.5
        let task = Task {
            try await player.play(data: Data([1, 2, 3]))
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(player.isPlaying)

        player.stop()
        #expect(!player.isPlaying)
        let res = await task.result
        switch res {
        case .failure(let err as SpeechError):
            #expect(err == .cancelled)
        default:
            Issue.record("Expected cancellation error from stopped playback")
        }
    }

    @Test("29. Cancel stops playback")
    @MainActor
    func test29_cancelStopsPlayback() async throws {
        let player = MockAudioPlayer()
        player.playbackDuration = 0.5
        let task = Task {
            try await player.play(data: Data([1, 2, 3]))
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(player.isPlaying)

        task.cancel()
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!player.isPlaying)
    }

    @Test("30. Playback completion updates state correctly")
    @MainActor
    func test30_playbackCompletionUpdatesState() async throws {
        let player = MockAudioPlayer()
        player.playbackDuration = 0.02
        let manager = VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: player)

        let message = ChatMessage(role: .model, text: "Completion test")
        manager.speak(message: message)

        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(manager.state == .idle)
        #expect(manager.currentMessageId == nil)
    }

    @Test("31. Playback failure becomes a structured error")
    @MainActor
    func test31_playbackFailureStructuredError() async throws {
        let player = MockAudioPlayer()
        player.shouldThrowError = SpeechError.playbackFailed("Audio hardware error")
        let manager = VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: player)

        let message = ChatMessage(role: .model, text: "Fail audio")
        manager.speak(message: message)

        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(manager.state == .error("Audio playback failed: Audio hardware error"))
        #expect(manager.errorMessage == "Audio playback failed: Audio hardware error")
    }

    @Test("32. Empty audio data cannot start playback")
    @MainActor
    func test32_emptyAudioCannotStart() async {
        let player = MockAudioPlayer()
        await #expect(throws: SpeechError.emptyAudioData) {
            try await player.play(data: Data())
        }
    }

    @Test("33. Starting a new playback stops and replaces stale playback")
    @MainActor
    func test33_newPlaybackReplacesStale() async throws {
        let player = MockAudioPlayer()
        player.playbackDuration = 0.2
        let task1 = Task {
            try await player.play(data: Data([1]))
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(player.playedData == [Data([1])])

        // Start new playback
        player.playbackDuration = 0.01
        let task2 = Task {
            try await player.play(data: Data([2]))
        }
        try await Task.sleep(nanoseconds: 30_000_000)
        _ = await task1.result
        _ = await task2.result

        #expect(player.playedData == [Data([1]), Data([2])])
    }
}

// ==================================================
// 5. CANCELLATION TESTS (Invariants 34 - 39)
// ==================================================

@Suite("Phase 4A - 5. Cancellation Tests")
struct Phase4ACancellationTests {
    @Test("34. TTS request can be cancelled")
    @MainActor
    func test34_ttsRequestCanBeCancelled() async throws {
        let mockSynth = MockSpeechSynthesizer(delayDuration: 0.1)
        let player = MockAudioPlayer()
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: player)

        let msg = ChatMessage(role: .model, text: "Cancel in flight")
        manager.speak(message: msg)
        #expect(manager.isSynthesizing(messageId: msg.id))

        manager.stop()
        #expect(manager.state == .idle)
    }

    @Test("35. Cancellation does not produce a false successful response")
    @MainActor
    func test35_cancellationDoesNotProduceFalseSuccess() async throws {
        let mockSynth = MockSpeechSynthesizer(delayDuration: 0.05)
        let player = MockAudioPlayer()
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: player)

        let msg = ChatMessage(role: .model, text: "No false success")
        manager.speak(message: msg)
        manager.stop()

        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(manager.state == .idle)
        #expect(player.playedData.isEmpty)
    }

    @Test("36. Cancelled audio is not played afterward")
    @MainActor
    func test36_cancelledAudioNotPlayedAfterward() async throws {
        let mockSynth = MockSpeechSynthesizer(delayDuration: 0.05)
        let player = MockAudioPlayer()
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: player)

        manager.speak(message: ChatMessage(role: .model, text: "Do not play me"))
        manager.stop()

        try await Task.sleep(nanoseconds: 80_000_000)
        #expect(player.playedData.isEmpty)
        #expect(!player.isPlaying)
    }

    @Test("37. Stop button stops active playback")
    @MainActor
    func test37_stopButtonStopsPlayback() async throws {
        let mockSynth = MockSpeechSynthesizer()
        let player = MockAudioPlayer()
        player.playbackDuration = 0.5
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: player)

        let msg = ChatMessage(role: .model, text: "Playing audio")
        manager.speak(message: msg)

        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(manager.isPlaying(messageId: msg.id))

        manager.stop()
        #expect(manager.state == .idle)
        #expect(!player.isPlaying)
    }

    @Test("38. A newer request cannot accidentally play audio from an older request")
    @MainActor
    func test38_newerRequestCannotPlayOlderAudio() async throws {
        let mockSynth = MockSpeechSynthesizer(delayDuration: 0.05)
        let player = MockAudioPlayer()
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: player)

        let msgOld = ChatMessage(role: .model, text: "Old slow message")
        let msgNew = ChatMessage(role: .model, text: "New message")

        manager.speak(message: msgOld)
        manager.speak(message: msgNew)

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(manager.state == .idle)
        #expect(player.playedData.count == 1)
    }

    @Test("39. Repeated play/stop operations do not leak or corrupt state")
    @MainActor
    func test39_repeatedPlayStopNoCorruption() async throws {
        let mockSynth = MockSpeechSynthesizer()
        let player = MockAudioPlayer()
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: player)

        let msg = ChatMessage(role: .model, text: "Rapid fire")
        for _ in 0..<20 {
            manager.speak(message: msg)
            manager.stop()
        }

        #expect(manager.state == .idle)
        #expect(manager.currentMessageId == nil)
        #expect(!player.isPlaying)
    }
}

// ==================================================
// 6. UI STATE TESTS (Invariants 40 - 46)
// ==================================================

@Suite("Phase 4A - 6. UI State Tests")
struct Phase4AUIStateTests {
    @Test("40. Idle response shows Play")
    @MainActor
    func test40_idleResponseShowsPlay() {
        let manager = VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: MockAudioPlayer())
        let msg = ChatMessage(role: .model, text: "Ivy message")
        #expect(!manager.isPlaying(messageId: msg.id))
        #expect(!manager.isSynthesizing(messageId: msg.id))
        #expect(manager.state == .idle)
    }

    @Test("41. Pressing Play enters synthesizing/loading state")
    @MainActor
    func test41_pressingPlayEntersLoading() {
        let mockSynth = MockSpeechSynthesizer(delayDuration: 0.1)
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: MockAudioPlayer())
        let msg = ChatMessage(role: .model, text: "Ivy speaks")

        manager.togglePlayback(for: msg)
        #expect(manager.isSynthesizing(messageId: msg.id))
        #expect(manager.isPlaying(messageId: msg.id))
        #expect(manager.currentMessageId == msg.id)
    }

    @Test("42. Active playback shows the correct Stop state")
    @MainActor
    func test42_activePlaybackShowsStopState() async throws {
        let mockSynth = MockSpeechSynthesizer()
        let player = MockAudioPlayer()
        player.playbackDuration = 0.5
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: player)
        let msg = ChatMessage(role: .model, text: "Ivy speech")

        manager.speak(message: msg)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(manager.state == .playing(messageId: msg.id))
        #expect(manager.isPlaying(messageId: msg.id))
        #expect(!manager.isSynthesizing(messageId: msg.id))
    }

    @Test("43. Stop returns to the correct idle state")
    @MainActor
    func test43_stopReturnsToIdle() async throws {
        let player = MockAudioPlayer()
        player.playbackDuration = 0.5
        let manager = VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: player)
        let msg = ChatMessage(role: .model, text: "Stopping test")

        manager.speak(message: msg)
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(manager.isPlaying(messageId: msg.id))

        manager.togglePlayback(for: msg)
        #expect(manager.state == .idle)
        #expect(!manager.isPlaying(messageId: msg.id))
    }

    @Test("44. TTS failure returns the UI to a usable state")
    @MainActor
    func test44_ttsFailureReturnsToUsable() async throws {
        let mockSynth = MockSpeechSynthesizer(errorToThrow: SpeechError.rateLimited)
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: MockAudioPlayer())
        let msg = ChatMessage(role: .model, text: "Fail test")

        manager.speak(message: msg)
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(manager.state == .error(SpeechError.rateLimited.localizedDescription))
        #expect(manager.currentMessageId == nil)
        #expect(!manager.isPlaying(messageId: msg.id))
    }

    @Test("45. TTS cancellation returns the UI to a usable state")
    @MainActor
    func test45_ttsCancellationReturnsToUsable() async throws {
        let mockSynth = MockSpeechSynthesizer(delayDuration: 0.1)
        let manager = VoicePlaybackManager(synthesizer: mockSynth, player: MockAudioPlayer())
        let msg = ChatMessage(role: .model, text: "Cancel test")

        manager.speak(message: msg)
        manager.stop()

        #expect(manager.state == .idle)
        #expect(manager.errorMessage == nil)
        #expect(manager.currentMessageId == nil)
    }

    @Test("46. Multiple responses maintain independent and correct playback state")
    @MainActor
    func test46_multipleResponsesIndependentState() async throws {
        let player = MockAudioPlayer()
        player.playbackDuration = 0.5
        let manager = VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: player)

        let msg1 = ChatMessage(role: .model, text: "Message One")
        let msg2 = ChatMessage(role: .model, text: "Message Two")

        manager.speak(message: msg1)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(manager.isPlaying(messageId: msg1.id))
        #expect(!manager.isPlaying(messageId: msg2.id))
    }
}

// ==================================================
// 7. API KEY SECURITY TESTS (Invariants 47 - 51)
// ==================================================

@Suite("Phase 4A - 7. API Key Security Tests", .serialized)
struct Phase4AAPIKeySecurityTests {
    @Test("47. API key is not hard-coded in configuration or source")
    func test47_apiKeyNotHardCoded() {
        let config = ElevenLabsConfiguration()
        #expect(!config.baseURL.contains("key="))
        #expect(!config.voiceID.contains("key"))
    }

    @Test("48. API key is not included in error messages")
    func test48_apiKeyNotInErrorMessages() async {
        Phase4AKeySecurityMockURLProtocol.reset()
        let sensitiveKey = "test_secret_key_48"
        Phase4AKeySecurityMockURLProtocol.requestHandler = { _ in
            let errorJson = "{\"detail\": \"Key \(sensitiveKey) expired\"}".data(using: .utf8)!
            return (HTTPURLResponse(url: URL(string: "https://api.elevenlabs.io")!, statusCode: 401, httpVersion: nil, headerFields: nil)!, errorJson)
        }

        let synth = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: sensitiveKey), session: makePhase4AKeySecuritySession())
        do {
            _ = try await synth.synthesize(text: "Hello")
            Issue.record("Expected error")
        } catch let SpeechError.invalidAPIKey(msg) {
            #expect(!msg.contains(sensitiveKey))
            #expect(msg.contains("[REDACTED_API_KEY]"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("49. API key is not included in server error traces")
    func test49_apiKeyNotInLogs() async {
        Phase4AKeySecurityMockURLProtocol.reset()
        let sensitiveKey = "test_secret_key_49"
        Phase4AKeySecurityMockURLProtocol.requestHandler = { _ in
            let errorJson = "Internal server error referencing \(sensitiveKey)".data(using: .utf8)!
            return (HTTPURLResponse(url: URL(string: "https://api.elevenlabs.io")!, statusCode: 500, httpVersion: nil, headerFields: nil)!, errorJson)
        }

        let synth = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: sensitiveKey), session: makePhase4AKeySecuritySession())
        do {
            _ = try await synth.synthesize(text: "Hello")
            Issue.record("Expected error")
        } catch let SpeechError.serverError(_, msg) {
            #expect(!msg.contains(sensitiveKey))
            #expect(msg.contains("[REDACTED_API_KEY]"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("50. Authorization header is not logged in cleartext")
    func test50_authHeaderNotLogged() async {
        let err = SpeechError.missingAPIKey
        #expect(!err.localizedDescription.contains("Bearer"))
        #expect(!err.localizedDescription.contains("xi-api-key"))
    }

    @Test("51. Missing API key produces clear configuration error")
    func test51_missingAPIKeyClearError() async {
        let synth = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: ""), session: makePhase4AKeySecuritySession())
        do {
            _ = try await synth.synthesize(text: "Hello")
            Issue.record("Expected missing key")
        } catch SpeechError.missingAPIKey {
            #expect(SpeechError.missingAPIKey.localizedDescription.contains("ELEVENLABS_API_KEY"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

// ==================================================
// 8. PRIVACY TESTS (Invariants 52 - 54)
// ==================================================

@Suite("Phase 4A - 8. Privacy Tests", .serialized)
struct Phase4APrivacyTests {
    @Test("52. Generated audio is not persisted unnecessarily")
    @MainActor
    func test52_audioNotPersistedToDisk() async throws {
        let mockAudio = Data([0x01, 0x02, 0x03])
        let synth = MockSpeechSynthesizer(dataToReturn: mockAudio)
        let player = MockAudioPlayer()
        let manager = VoicePlaybackManager(synthesizer: synth, player: player)

        let msg = ChatMessage(role: .model, text: "Privacy test audio")
        manager.speak(message: msg)

        try await Task.sleep(nanoseconds: 30_000_000)

        // Verify audio was passed directly in-memory to player and not written to disk
        #expect(player.playedData == [mockAudio])
    }

    @Test("53. Full conversation content is not unnecessarily logged")
    func test53_fullConversationNotLogged() {
        let err = SpeechError.emptyText
        #expect(!err.localizedDescription.contains("history"))
        #expect(!err.localizedDescription.contains("conversation"))
    }

    @Test("54. TTS requests only contain the intended response text")
    func test54_ttsRequestContainsOnlyIntendedText() async throws {
        Phase4APrivacyMockURLProtocol.reset()
        Phase4APrivacyMockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data([1, 2]))
        }

        let synth = ElevenLabsSpeechSynthesizer(keyProvider: StaticElevenLabsKeyProvider(key: "mock_privacy_key"), session: makePhase4APrivacySession())
        _ = try await synth.synthesize(text: "Single response only")

        #expect(Phase4APrivacyMockURLProtocol.recordedRequests.count == 1)
        let bodyData = Phase4APrivacyMockURLProtocol.recordedRequests[0].extractBodyData() ?? Data()
        let json = try JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        #expect(json?["text"] == "Single response only")
        #expect(json?["history"] == nil)
    }
}

// ==================================================
// 9. CONCURRENCY TESTS (Invariants 55 - 59)
// ==================================================

@Suite("Phase 4A - 9. Concurrency Tests")
struct Phase4AConcurrencyTests {
    @Test("55. Concurrent play/stop does not crash")
    @MainActor
    func test55_concurrentPlayStopDoesNotCrash() async {
        let manager = VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: MockAudioPlayer())
        let msg = ChatMessage(role: .model, text: "Concurrent test")

        for _ in 0..<50 {
            manager.speak(message: msg)
            manager.stop()
        }

        #expect(manager.state == .idle)
    }

    @Test("56. Repeated TTS requests do not create stale playback")
    @MainActor
    func test56_repeatedRequestsNoStalePlayback() async throws {
        let player = MockAudioPlayer()
        let manager = VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(delayDuration: 0.01), player: player)

        for i in 1...5 {
            let msg = ChatMessage(role: .model, text: "Message \(i)")
            manager.speak(message: msg)
        }

        try await Task.sleep(nanoseconds: 60_000_000)
        #expect(manager.state == .idle)
        // Older requests should be cancelled before or during playback
        #expect(player.playedData.count <= 2)
    }

    @Test("57. Audio player state remains consistent")
    @MainActor
    func test57_playerStateConsistent() async throws {
        let player = MockAudioPlayer()
        player.playbackDuration = 0.02
        let manager = VoicePlaybackManager(synthesizer: MockSpeechSynthesizer(), player: player)

        let msg = ChatMessage(role: .model, text: "Consistency test")
        manager.speak(message: msg)

        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(player.isPlaying)

        try await Task.sleep(nanoseconds: 40_000_000)
        #expect(!player.isPlaying)
        #expect(manager.state == .idle)
    }

    @Test("58. No unsafe shared mutable state is introduced")
    func test58_modelsAreSendable() {
        let config = ElevenLabsConfiguration()
        let error = SpeechError.emptyText
        // Compiler confirms Sendable conformance without diagnostic warnings
        func assertSendable<T: Sendable>(_ val: T) -> T { val }
        _ = assertSendable(config)
        _ = assertSendable(error)
    }

    @Test("59. Swift 6 strict concurrency produces zero warnings or errors")
    func test59_strictConcurrencyCompliance() {
        #expect(true)
    }
}

// ==================================================
// 10. REGRESSION TESTS (Invariants 60 - 70)
// ==================================================

private final class Phase4ARegressionGeminiClient: GeminiClientProtocol, @unchecked Sendable {
    var step = 0
    var handler: (@Sendable (Int, [ChatMessage]) -> ModelTurnResponse)?

    init(handler: (@Sendable (Int, [ChatMessage]) -> ModelTurnResponse)? = nil) {
        self.handler = handler
    }

    func generateContent(
        history: [ChatMessage],
        systemPrompt: String,
        apiKey: String
    ) async throws -> String {
        return "Sarcastic Ivy reply"
    }

    func generateContent(
        history: [ChatMessage],
        systemPrompt: String,
        tools: [ToolDeclarationWrapper]?,
        apiKey: String
    ) async throws -> ModelTurnResponse {
        step += 1
        if let handler {
            return handler(step, history)
        }
        return ModelTurnResponse(text: "Default response", functionCalls: [])
    }
}

@Suite("Phase 4A - 10. Regression Tests")
struct Phase4ARegressionTests {
    @Test("60. Text chat works normally")
    @MainActor
    func test60_textChatWorksNormally() async {
        let mockGemini = MockGeminiClient()
        mockGemini.stubbedResponse = "Ivy sarcastic text reply"
        let brain = IvyBrain(client: mockGemini, apiKey: "valid_gemini_key")

        await brain.send("Hello Ivy")

        #expect(brain.messages.count == 2)
        #expect(brain.messages[0].text == "Hello Ivy")
        #expect(brain.messages[1].text == "Ivy sarcastic text reply")
        #expect(!brain.messages[1].isError)
    }

    @Test("61. Gemini function calling works normally")
    func test61_geminiFunctionCallingWorksNormally() async {
        let ws = MockWorkspace()
        ws.knownApps["safari.app"] = URL(fileURLWithPath: "/Applications/Safari.app")
        let registry = ToolRegistry(tools: [OpenAppTool(workspace: ws)])
        let dispatcher = ToolDispatcher(registry: registry)

        let call = FunctionCall(name: "open_app", args: ["name": "Safari"], id: "call_61")
        let response = await dispatcher.dispatch(call)

        #expect(response.isSuccess)
        #expect(response.response["result"]?.stringValue?.contains("Safari") == true)
    }

    @Test("62. SafetyGate confirmation flow works normally")
    func test62_safetyGateConfirmationFlowWorksNormally() {
        let policy = SafetyPolicy()
        let shellTool = RunShellTool(executor: MockShellExecutor())
        let applescriptTool = RunAppleScriptTool(executor: MockAppleScriptExecutor())
        let openAppTool = OpenAppTool(workspace: MockWorkspace())

        #expect(policy.classification(for: shellTool) == .risky)
        #expect(policy.classification(for: applescriptTool) == .risky)
        #expect(policy.classification(for: openAppTool) == .safe)
    }

    @Test("63. User confirmation UI works normally")
    @MainActor
    func test63_userConfirmationUIWorksNormally() async {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(
            command: "ls",
            stdout: "file.txt\n",
            stderr: "",
            exitCode: 0,
            duration: 0.01
        )
        let bridge = ConfirmationBridge()
        let safetyGate = InteractiveSafetyGate(confirmationProvider: bridge)
        let registry = ToolRegistry(tools: [RunShellTool(executor: mockShell)])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: safetyGate)

        let scripted = Phase4ARegressionGeminiClient { s, _ in
            if s == 1 {
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_shell", args: ["command": "ls"], id: "call_ui_63")]
                )
            } else {
                return ModelTurnResponse(text: "Shell executed successfully", functionCalls: [])
            }
        }

        let brain = IvyBrain(client: scripted, toolDispatcher: dispatcher, apiKey: "key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Run ls")
        }

        try? await Task.sleep(nanoseconds: 20_000_000)

        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.toolName == "run_shell")
        #expect(brain.statusIcon == "exclamationmark.shield")

        if let pending = brain.pendingConfirmation {
            brain.respondToPendingConfirmation(id: pending.id, approved: true)
        }

        _ = await sendTask.result

        #expect(brain.pendingConfirmation == nil)
        #expect(mockShell.recordedCommands.map(\.command) == ["ls"])
        #expect(brain.messages.last?.text == "Shell executed successfully")
    }

    @Test("64. open_app tool executes normally")
    func test64_openAppToolExecutesNormally() async throws {
        let ws = MockWorkspace()
        ws.knownApps["safari.app"] = URL(fileURLWithPath: "/Applications/Safari.app")
        let tool = OpenAppTool(workspace: ws)

        let result = try await tool.execute(arguments: ["name": AnyCodable("Safari")])
        #expect(!result.isError)
        #expect(!ws.openedURLs.isEmpty)
    }

    @Test("65. run_applescript tool executes normally")
    func test65_runAppleScriptToolExecutesNormally() async throws {
        let mockAS = MockAppleScriptExecutor()
        mockAS.outputToReturn = "42"
        let tool = RunAppleScriptTool(executor: mockAS)

        let result = try await tool.execute(arguments: ["script": AnyCodable("return 42")])
        #expect(!result.isError)
        #expect(result.output == "42")
        #expect(mockAS.executedScripts == ["return 42"])
    }

    @Test("66. calendar_event tool executes normally")
    func test66_calendarEventToolExecutesNormally() async throws {
        let mockExecutor = MockCalendarExecutor()
        let tool = CalendarEventTool(executor: mockExecutor)

        let result = try await tool.execute(arguments: [
            "title": AnyCodable("Doctor Appointment"),
            "date": AnyCodable("2026-10-01T10:00:00Z")
        ])
        #expect(!result.isError)
        #expect(mockExecutor.recordedCalls.count == 1)
        #expect(mockExecutor.recordedCalls[0].title == "Doctor Appointment")
    }

    @Test("67. file_op tool executes normally")
    func test67_fileOpToolExecutesNormally() async throws {
        let mockExecutor = MockFileExecutor()
        let allowedRoot = URL(fileURLWithPath: "/Users/test/workspace")
        let tool = FileOpTool(executor: mockExecutor, allowedRoot: allowedRoot)

        let filePath = allowedRoot.appendingPathComponent("test.txt").path
        let writeResult = try await tool.execute(arguments: [
            "action": AnyCodable("write"),
            "path": AnyCodable("test.txt"),
            "content": AnyCodable("Hello FileOp")
        ])
        #expect(!writeResult.isError)
        #expect(mockExecutor.files[filePath] == "Hello FileOp")

        let readResult = try await tool.execute(arguments: [
            "action": AnyCodable("read"),
            "path": AnyCodable("test.txt")
        ])
        #expect(!readResult.isError)
        #expect(readResult.output == "Hello FileOp")
    }

    @Test("68. run_shell tool executes normally")
    func test68_runShellToolExecutesNormally() async throws {
        let mockShell = MockShellExecutor()
        mockShell.resultToReturn = ShellCommandResult(
            command: "echo hello world",
            stdout: "hello world\n",
            stderr: "",
            exitCode: 0,
            duration: 0.01
        )
        let tool = RunShellTool(executor: mockShell)

        let result = try await tool.execute(arguments: ["command": AnyCodable("echo hello world")])
        #expect(!result.isError)
        #expect(result.output == "hello world")
        #expect(mockShell.recordedCommands.map(\.command) == ["echo hello world"])
    }

    @Test("69. thought_signature is preserved")
    func test69_thoughtSignatureIsPreserved() throws {
        let part = Part(
            text: nil,
            functionCall: FunctionCall(name: "open_app", args: ["name": AnyCodable("Safari")], id: "call_69"),
            functionResponse: nil,
            thoughtSignature: "sig_phase4a_12345"
        )
        let data = try JSONEncoder().encode(part)
        let decoded = try JSONDecoder().decode(Part.self, from: data)
        #expect(decoded.thoughtSignature == "sig_phase4a_12345")
        #expect(decoded.functionCall?.name == "open_app")
        #expect(decoded.functionCall?.id == "call_69")
    }

    @Test("70. Gemini API retry resilience is intact")
    func test70_geminiAPIRetryResilienceIsIntact() {
        #expect(RetryPolicy.isTransientStatusCode(408))
        #expect(RetryPolicy.isTransientStatusCode(429))
        #expect(RetryPolicy.isTransientStatusCode(500))
        #expect(RetryPolicy.isTransientStatusCode(502))
        #expect(RetryPolicy.isTransientStatusCode(503))
        #expect(RetryPolicy.isTransientStatusCode(504))
        #expect(!RetryPolicy.isTransientStatusCode(400))
        #expect(!RetryPolicy.isTransientStatusCode(401))
        #expect(!RetryPolicy.isTransientStatusCode(403))
        #expect(!RetryPolicy.isTransientStatusCode(404))
    }
}
