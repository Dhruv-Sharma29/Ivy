import Testing
import Foundation
@testable import IvyCore

final class ResilienceMockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = ResilienceMockURLProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
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
}

@Suite("Gemini API Resilience & Retry Tests", .serialized)
struct GeminiResilienceTests {

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResilienceMockURLProtocol.self]
        return URLSession(configuration: config)
    }

    private let sampleSuccessJSON = """
    {
      "candidates": [
        {
          "content": {
            "parts": [
              { "text": "All systems operational." }
            ],
            "role": "model"
          },
          "finishReason": "STOP"
        }
      ]
    }
    """

    // MARK: - Successful Attempts

    @Test("Immediate success on attempt 1 makes zero retries and calls sleeper 0 times")
    func testImmediateSuccessDoesNotRetry() async throws {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, self.sampleSuccessJSON.data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy.testing(maxRetries: 3) { _ in
            sleeperCalls += 1
        }
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        let result = try await client.generateContent(
            history: [ChatMessage(role: .user, text: "Status check")],
            systemPrompt: "You are Ivy",
            apiKey: "test_key"
        )

        #expect(result == "All systems operational.")
        #expect(attempts == 1)
        #expect(sleeperCalls == 0)
    }

    // MARK: - Transient 503 and 429 Recovery

    @Test("Transient HTTP 503 recovers on attempt 2 after 1 retry")
    func testTransient503RecoversOnSecondAttempt() async throws {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperDelays: [TimeInterval] = []

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? HTTPURLResponse()
                return (response, "High demand".data(using: .utf8) ?? Data())
            }

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, self.sampleSuccessJSON.data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxDelay: 8.0,
            jitterRange: 0.0..<0.0,
            sleeper: { delay in
                sleeperDelays.append(delay)
            }
        )
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        let result = try await client.generateContent(
            history: [ChatMessage(role: .user, text: "Retry me")],
            systemPrompt: "You are Ivy",
            apiKey: "test_key"
        )

        #expect(result == "All systems operational.")
        #expect(attempts == 2)
        #expect(sleeperDelays.count == 1)
        #expect(sleeperDelays.first == 1.0)
    }

    @Test("Transient HTTP 429 recovers on attempt 2 after 1 retry")
    func testTransient429RecoversOnSecondAttempt() async throws {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperDelays: [TimeInterval] = []

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? HTTPURLResponse()
                return (response, "Rate limited".data(using: .utf8) ?? Data())
            }

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, self.sampleSuccessJSON.data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxDelay: 8.0,
            jitterRange: 0.0..<0.0,
            sleeper: { delay in
                sleeperDelays.append(delay)
            }
        )
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        let result = try await client.generateContent(
            history: [ChatMessage(role: .user, text: "Try again")],
            systemPrompt: "You are Ivy",
            apiKey: "test_key"
        )

        #expect(result == "All systems operational.")
        #expect(attempts == 2)
        #expect(sleeperDelays.count == 1)
        #expect(sleeperDelays.first == 1.0)
    }

    @Test("Multiple transient failures (429 then 503) recover on attempt 3")
    func testMultipleTransientErrorsRecoverBeforeExhaustion() async throws {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var recordedDelays: [TimeInterval] = []

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? HTTPURLResponse()
                return (response, Data())
            } else if attempts == 2 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? HTTPURLResponse()
                return (response, Data())
            }

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, self.sampleSuccessJSON.data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxDelay: 8.0,
            jitterRange: 0.0..<0.0,
            sleeper: { delay in
                recordedDelays.append(delay)
            }
        )
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        let result = try await client.generateContent(
            history: [ChatMessage(role: .user, text: "Multi retry")],
            systemPrompt: "You are Ivy",
            apiKey: "test_key"
        )

        #expect(result == "All systems operational.")
        #expect(attempts == 3)
        #expect(recordedDelays.count == 2)
        #expect(recordedDelays[0] == 1.0) // retry 1 after attempt 0
        #expect(recordedDelays[1] == 2.0) // retry 2 after attempt 1
    }

    // MARK: - Transient Status Codes Coverage

    @Test("All designated transient HTTP status codes (408, 500, 502, 504) are retried and recover")
    func testDesignatedTransientStatusCodes() async throws {
        let transientCodes = [408, 500, 502, 504]

        for code in transientCodes {
            nonisolated(unsafe) var attempts = 0
            ResilienceMockURLProtocol.requestHandler = { request in
                attempts += 1
                if attempts == 1 {
                    let response = HTTPURLResponse(
                        url: request.url ?? URL(string: "https://example.com")!,
                        statusCode: code,
                        httpVersion: nil,
                        headerFields: nil
                    ) ?? HTTPURLResponse()
                    return (response, "Transient failure".data(using: .utf8) ?? Data())
                }

                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                ) ?? HTTPURLResponse()
                return (response, self.sampleSuccessJSON.data(using: .utf8) ?? Data())
            }

            let policy = RetryPolicy.testing(maxRetries: 3)
            let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

            let result = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Testing code \(code)")],
                systemPrompt: "You are Ivy",
                apiKey: "test_key"
            )

            #expect(result == "All systems operational.")
            #expect(attempts == 2)
        }
    }

    // MARK: - Transient Network Error Recovery

    @Test("Transient network error (timedOut) retries and recovers on attempt 2")
    func testTransientNetworkErrorTimedOutRecovers() async throws {
        nonisolated(unsafe) var attempts = 0
        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                throw URLError(.timedOut)
            }

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, self.sampleSuccessJSON.data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy.testing(maxRetries: 3)
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        let result = try await client.generateContent(
            history: [ChatMessage(role: .user, text: "Network timeout test")],
            systemPrompt: "You are Ivy",
            apiKey: "test_key"
        )

        #expect(result == "All systems operational.")
        #expect(attempts == 2)
    }

    @Test("Transient network errors (networkConnectionLost, notConnectedToInternet) retry and recover")
    func testTransientNetworkErrorsConnectionLostRecovers() async throws {
        let transientErrors = [URLError(.networkConnectionLost), URLError(.notConnectedToInternet)]

        for transientErr in transientErrors {
            nonisolated(unsafe) var attempts = 0
            ResilienceMockURLProtocol.requestHandler = { request in
                attempts += 1
                if attempts == 1 {
                    throw transientErr
                }

                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                ) ?? HTTPURLResponse()
                return (response, self.sampleSuccessJSON.data(using: .utf8) ?? Data())
            }

            let policy = RetryPolicy.testing(maxRetries: 3)
            let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

            let result = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Transient net test")],
                systemPrompt: "You are Ivy",
                apiKey: "test_key"
            )

            #expect(result == "All systems operational.")
            #expect(attempts == 2)
        }
    }

    // MARK: - Permanent Errors (Zero Retries)

    @Test("HTTP 400 Bad Request fails immediately without retry")
    func testPermanent400FailsImmediately() async {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        let errorJSON = """
        {
          "error": {
            "code": 400,
            "message": "Bad Request",
            "status": "INVALID_ARGUMENT"
          }
        }
        """

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, errorJSON.data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy.testing(maxRetries: 3) { _ in
            sleeperCalls += 1
        }
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        await #expect(throws: GeminiClientError.invalidAPIKey("Bad Request")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Bad request")],
                systemPrompt: "prompt",
                apiKey: "test_key"
            )
        }

        #expect(attempts == 1)
        #expect(sleeperCalls == 0)
    }

    @Test("HTTP 401 Unauthorized fails immediately without retry")
    func testPermanent401FailsImmediately() async {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        let errorJSON = """
        {
          "error": {
            "code": 401,
            "message": "Unauthorized",
            "status": "UNAUTHENTICATED"
          }
        }
        """

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, errorJSON.data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy.testing(maxRetries: 3) { _ in
            sleeperCalls += 1
        }
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        await #expect(throws: GeminiClientError.invalidAPIKey("Unauthorized")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Auth test")],
                systemPrompt: "prompt",
                apiKey: "test_key"
            )
        }

        #expect(attempts == 1)
        #expect(sleeperCalls == 0)
    }

    @Test("HTTP 403 Forbidden fails immediately without retry")
    func testPermanent403FailsImmediately() async {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        let errorJSON = """
        {
          "error": {
            "code": 403,
            "message": "Forbidden",
            "status": "PERMISSION_DENIED"
          }
        }
        """

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, errorJSON.data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy.testing(maxRetries: 3) { _ in
            sleeperCalls += 1
        }
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        await #expect(throws: GeminiClientError.invalidAPIKey("Forbidden")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Forbidden test")],
                systemPrompt: "prompt",
                apiKey: "test_key"
            )
        }

        #expect(attempts == 1)
        #expect(sleeperCalls == 0)
    }

    @Test("HTTP 404 Model Not Found fails immediately without retry")
    func testPermanent404FailsImmediately() async {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        let errorJSON = """
        {
          "error": {
            "code": 404,
            "message": "Model gemini-missing not found",
            "status": "NOT_FOUND"
          }
        }
        """

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, errorJSON.data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy.testing(maxRetries: 3) { _ in
            sleeperCalls += 1
        }
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        await #expect(throws: GeminiClientError.modelNotFound("Model gemini-missing not found")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "404 test")],
                systemPrompt: "prompt",
                apiKey: "test_key"
            )
        }

        #expect(attempts == 1)
        #expect(sleeperCalls == 0)
    }

    // MARK: - Exhaustion and Error Descriptions

    @Test("Exhausting 3 retries on persistent HTTP 503 makes exactly 4 attempts and returns clear overloaded message")
    func testExhausted503ReturnsOverloadedMessage() async {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperDelays: [TimeInterval] = []

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            ) ?? HTTPURLResponse()
            return (response, "High demand".data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxDelay: 8.0,
            jitterRange: 0.0..<0.0,
            sleeper: { delay in
                sleeperDelays.append(delay)
            }
        )
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        do {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Persistent 503")],
                systemPrompt: "You are Ivy",
                apiKey: "test_key"
            )
            Issue.record("Expected serverError to be thrown upon exhaustion")
        } catch let GeminiClientError.serverError(statusCode, message) {
            #expect(statusCode == 503)
            #expect(message == "High demand")
            let clientError = GeminiClientError.serverError(statusCode: statusCode, message: message)
            #expect(clientError.errorDescription == "Gemini is temporarily overloaded. Please try again in a moment.")
            #expect(clientError.localizedDescription == "Gemini is temporarily overloaded. Please try again in a moment.")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(attempts == 4) // 1 initial attempt + 3 retries
        #expect(sleeperDelays.count == 3)
        #expect(sleeperDelays == [1.0, 2.0, 4.0])
    }

    @Test("Exhausting 3 retries on persistent network timeout throws networkError after 4 attempts")
    func testExhaustedNetworkTimeoutThrowsNetworkError() async {
        nonisolated(unsafe) var attempts = 0
        ResilienceMockURLProtocol.requestHandler = { _ in
            attempts += 1
            throw URLError(.timedOut)
        }

        let policy = RetryPolicy.testing(maxRetries: 3)
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        do {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Timeout all")],
                systemPrompt: "You are Ivy",
                apiKey: "test_key"
            )
            Issue.record("Expected networkError to be thrown")
        } catch let GeminiClientError.networkError(msg) {
            #expect(!msg.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(attempts == 4)
    }

    // MARK: - Exponential Backoff Schedule & Jitter

    @Test("Exponential backoff math scales as 1s, 2s, 4s, capped at maxDelay")
    func testExponentialBackoffMath() {
        let policy = RetryPolicy(
            maxRetries: 4,
            baseDelay: 1.0,
            maxDelay: 6.0,
            jitterRange: 0.0..<0.0,
            sleeper: { _ in }
        )

        #expect(policy.delay(forAttempt: 0, jitter: 0.0) == 1.0)
        #expect(policy.delay(forAttempt: 1, jitter: 0.0) == 2.0)
        #expect(policy.delay(forAttempt: 2, jitter: 0.0) == 4.0)
        #expect(policy.delay(forAttempt: 3, jitter: 0.0) == 6.0) // capped at 6.0 instead of 8.0
        #expect(policy.delay(forAttempt: 4, jitter: 0.0) == 6.0)
    }

    @Test("Jitter is bounded strictly within jitterRange")
    func testJitterIsBounded() {
        let policy = RetryPolicy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxDelay: 8.0,
            jitterRange: 0.0..<0.25,
            sleeper: { _ in }
        )

        for attempt in 0...2 {
            for _ in 0..<50 {
                let delay = policy.delay(forAttempt: attempt)
                let nominal = policy.baseDelay * pow(2.0, Double(attempt))
                #expect(delay >= nominal)
                #expect(delay < nominal + 0.25)
            }
        }
    }

    // MARK: - Exact Request Payload Preservation

    @Test("Request payload, headers, query parameters, and thought_signature are identical across retries")
    func testExactRequestPreservedAcrossRetries() async throws {
        nonisolated(unsafe) var capturedBodies: [Data] = []
        nonisolated(unsafe) var capturedHeaders: [[String: String]] = []
        nonisolated(unsafe) var capturedURLs: [URL] = []

        ResilienceMockURLProtocol.requestHandler = { request in
            if let body = request.extractBodyData() {
                capturedBodies.append(body)
            }
            if let allHeaders = request.allHTTPHeaderFields {
                capturedHeaders.append(allHeaders)
            }
            if let url = request.url {
                capturedURLs.append(url)
            }

            if capturedBodies.count < 3 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? HTTPURLResponse()
                return (response, Data())
            }

            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, self.sampleSuccessJSON.data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy.testing(maxRetries: 3)
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        let call = FunctionCall(name: "open_app", args: ["name": "Safari"], thoughtSignature: "test-thought-sig-999")
        let part = Part(functionCall: call, thoughtSignature: "test-thought-sig-999")
        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "Open app"),
            ChatMessage(role: .model, text: "", functionCall: call, functionCallPart: part),
            ChatMessage(role: .function, text: "Done", functionResponse: FunctionResponse(name: "open_app", response: ["status": "ok"]))
        ]

        _ = try await client.generateContent(
            history: history,
            systemPrompt: "You are Ivy",
            tools: nil,
            apiKey: "secret_api_key_456"
        )

        #expect(capturedBodies.count == 3)
        #expect(capturedBodies[0] == capturedBodies[1])
        #expect(capturedBodies[1] == capturedBodies[2])

        #expect(capturedHeaders.count == 3)
        #expect(capturedHeaders[0]["x-goog-api-key"] == "secret_api_key_456")
        #expect(capturedHeaders[0]["Content-Type"] == "application/json")
        #expect(capturedHeaders[0] == capturedHeaders[1])
        #expect(capturedHeaders[1] == capturedHeaders[2])

        #expect(capturedURLs.count == 3)
        #expect(capturedURLs[0] == capturedURLs[1])
        #expect(capturedURLs[1] == capturedURLs[2])

        // Verify thought_signature was preserved in the payload
        let bodyString = String(data: capturedBodies[0], encoding: .utf8) ?? ""
        #expect(bodyString.contains("test-thought-sig-999"))
    }

    // MARK: - Zero Retries Policy

    @Test("RetryPolicy.none performs exactly 1 attempt with 0 retries")
    func testZeroRetriesPolicy() async {
        nonisolated(unsafe) var attempts = 0
        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            ) ?? HTTPURLResponse()
            return (response, Data())
        }

        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: .none)

        await #expect(throws: GeminiClientError.serverError(statusCode: 503, message: "HTTP 503")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Zero retry")],
                systemPrompt: "prompt",
                apiKey: "test_key"
            )
        }

        #expect(attempts == 1)
    }

    // MARK: - IvyBrain Integration on Exhausted 503

    @Test("IvyBrain presents clean user-facing error when Gemini 503 retries exhaust")
    @MainActor
    func testIvyBrainSurfacesOverloadedMessageOnExhausted503() async {
        ResilienceMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            ) ?? HTTPURLResponse()
            return (response, "Spikes in demand".data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy.testing(maxRetries: 3)
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        let brain = IvyBrain(client: client, apiKey: "valid_key")
        await brain.send("Check calendar")

        #expect(brain.errorMessage == "Gemini is temporarily overloaded. Please try again in a moment.")
        let lastMessage = brain.messages.last
        #expect(lastMessage?.role == .model)
        #expect(lastMessage?.isError == true)
        #expect(lastMessage?.text.contains("Gemini is temporarily overloaded. Please try again in a moment.") == true)
    }

    // MARK: - Edge Cases & Policy Unit Checks

    @Test("RetryPolicy predicate helpers distinguish transient and non-transient conditions correctly")
    func testRetryPolicyPredicates() {
        #expect(RetryPolicy.isTransientStatusCode(408) == true)
        #expect(RetryPolicy.isTransientStatusCode(429) == true)
        #expect(RetryPolicy.isTransientStatusCode(500) == true)
        #expect(RetryPolicy.isTransientStatusCode(502) == true)
        #expect(RetryPolicy.isTransientStatusCode(503) == true)
        #expect(RetryPolicy.isTransientStatusCode(504) == true)
        #expect(RetryPolicy.isTransientStatusCode(200) == false)
        #expect(RetryPolicy.isTransientStatusCode(400) == false)
        #expect(RetryPolicy.isTransientStatusCode(401) == false)
        #expect(RetryPolicy.isTransientStatusCode(403) == false)
        #expect(RetryPolicy.isTransientStatusCode(404) == false)
        #expect(RetryPolicy.isTransientStatusCode(501) == false)

        #expect(RetryPolicy.isTransientNetworkError(URLError(.timedOut)) == true)
        #expect(RetryPolicy.isTransientNetworkError(URLError(.networkConnectionLost)) == true)
        #expect(RetryPolicy.isTransientNetworkError(URLError(.notConnectedToInternet)) == true)
        #expect(RetryPolicy.isTransientNetworkError(URLError(.cannotConnectToHost)) == true)
        #expect(RetryPolicy.isTransientNetworkError(URLError(.cannotFindHost)) == true)
        #expect(RetryPolicy.isTransientNetworkError(URLError(.dnsLookupFailed)) == true)
        #expect(RetryPolicy.isTransientNetworkError(URLError(.badURL)) == false)
        #expect(RetryPolicy.isTransientNetworkError(NSError(domain: "custom", code: 999)) == false)

        #expect(RetryPolicy.default.delay(forAttempt: -1) == 0.0)
    }

    @Test("RetryPolicy default sleeper handles zero or negative duration without delay")
    func testDefaultSleeperZeroDuration() async throws {
        try await RetryPolicy.default.sleeper(0.0)
        try await RetryPolicy.default.sleeper(-1.0)
    }

    @Test("Non-transient network error fails immediately without retrying")
    func testNonTransientNetworkErrorFailsImmediately() async {
        nonisolated(unsafe) var attempts = 0
        ResilienceMockURLProtocol.requestHandler = { _ in
            attempts += 1
            throw URLError(.badURL)
        }

        let policy = RetryPolicy.testing(maxRetries: 3)
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        do {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Bad URL test")],
                systemPrompt: "prompt",
                apiKey: "test_key"
            )
            Issue.record("Expected networkError")
        } catch let GeminiClientError.networkError(msg) {
            #expect(!msg.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        #expect(attempts == 1)
    }

    @Test("Retry loop terminates promptly when task is cancelled during backoff sleeper")
    func testTaskCancellationDuringRetry() async {
        ResilienceMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            ) ?? HTTPURLResponse()
            return (response, Data())
        }

        let policy = RetryPolicy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxDelay: 8.0,
            jitterRange: 0.0..<0.0,
            sleeper: { _ in
                throw CancellationError()
            }
        )
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        do {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Cancel test")],
                systemPrompt: "prompt",
                apiKey: "test_key"
            )
            Issue.record("Expected CancellationError to propagate")
        } catch is CancellationError {
            // Success: cancellation propagated cleanly
        } catch {
            Issue.record("Expected CancellationError, got \(error)")
        }
    }
}
