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

    // MARK: - 1. HTTP 200: Returns immediately, zero retries

    @Test("1. HTTP 200 returns immediately with zero retries")
    func test01_HTTP200_ReturnsImmediatelyWithZeroRetries() async throws {
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

    // MARK: - 2. HTTP 400: Zero retries, returns client error

    @Test("2. HTTP 400 makes zero retries and returns client error")
    func test02_HTTP400_ZeroRetries_ReturnsClientError() async {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        let errorJSON = """
        {
          "error": {
            "code": 400,
            "message": "Bad Request: invalid parameter format",
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

        await #expect(throws: GeminiClientError.invalidAPIKey("Bad Request: invalid parameter format")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Bad request")],
                systemPrompt: "prompt",
                apiKey: "test_key"
            )
        }

        #expect(attempts == 1)
        #expect(sleeperCalls == 0)
    }

    // MARK: - 3. HTTP 401: Zero retries

    @Test("3. HTTP 401 makes zero retries")
    func test03_HTTP401_ZeroRetries() async {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        let errorJSON = """
        {
          "error": {
            "code": 401,
            "message": "Unauthorized API key",
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

        await #expect(throws: GeminiClientError.invalidAPIKey("Unauthorized API key")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Auth check")],
                systemPrompt: "prompt",
                apiKey: "bad_key"
            )
        }

        #expect(attempts == 1)
        #expect(sleeperCalls == 0)
    }

    // MARK: - 4. HTTP 403: Zero retries

    @Test("4. HTTP 403 makes zero retries")
    func test04_HTTP403_ZeroRetries() async {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        let errorJSON = """
        {
          "error": {
            "code": 403,
            "message": "Forbidden access to resource",
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

        await #expect(throws: GeminiClientError.invalidAPIKey("Forbidden access to resource")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Forbidden check")],
                systemPrompt: "prompt",
                apiKey: "restricted_key"
            )
        }

        #expect(attempts == 1)
        #expect(sleeperCalls == 0)
    }

    // MARK: - 5. HTTP 404: Zero retries

    @Test("5. HTTP 404 makes zero retries")
    func test05_HTTP404_ZeroRetries() async {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        let errorJSON = """
        {
          "error": {
            "code": 404,
            "message": "Model gemini-3.8-flash not found",
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

        await #expect(throws: GeminiClientError.modelNotFound("Model gemini-3.8-flash not found")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Model check")],
                systemPrompt: "prompt",
                apiKey: "valid_key"
            )
        }

        #expect(attempts == 1)
        #expect(sleeperCalls == 0)
    }

    // MARK: - 6. HTTP 408: Retries

    @Test("6. HTTP 408 retries and recovers")
    func test06_HTTP408_Retries() async throws {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 408,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? HTTPURLResponse()
                return (response, "Request Timeout".data(using: .utf8) ?? Data())
            }

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
            history: [ChatMessage(role: .user, text: "408 check")],
            systemPrompt: "You are Ivy",
            apiKey: "test_key"
        )

        #expect(result == "All systems operational.")
        #expect(attempts == 2)
        #expect(sleeperCalls == 1)
    }

    // MARK: - 7. HTTP 429: Retries

    @Test("7. HTTP 429 retries and recovers")
    func test07_HTTP429_Retries() async throws {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

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

        let policy = RetryPolicy.testing(maxRetries: 3) { _ in
            sleeperCalls += 1
        }
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        let result = try await client.generateContent(
            history: [ChatMessage(role: .user, text: "429 check")],
            systemPrompt: "You are Ivy",
            apiKey: "test_key"
        )

        #expect(result == "All systems operational.")
        #expect(attempts == 2)
        #expect(sleeperCalls == 1)
    }

    // MARK: - 8. HTTP 500: Retries

    @Test("8. HTTP 500 retries and recovers")
    func test08_HTTP500_Retries() async throws {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? HTTPURLResponse()
                return (response, "Internal Server Error".data(using: .utf8) ?? Data())
            }

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
            history: [ChatMessage(role: .user, text: "500 check")],
            systemPrompt: "You are Ivy",
            apiKey: "test_key"
        )

        #expect(result == "All systems operational.")
        #expect(attempts == 2)
        #expect(sleeperCalls == 1)
    }

    // MARK: - 9. HTTP 502: Retries

    @Test("9. HTTP 502 retries and recovers")
    func test09_HTTP502_Retries() async throws {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 502,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? HTTPURLResponse()
                return (response, "Bad Gateway".data(using: .utf8) ?? Data())
            }

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
            history: [ChatMessage(role: .user, text: "502 check")],
            systemPrompt: "You are Ivy",
            apiKey: "test_key"
        )

        #expect(result == "All systems operational.")
        #expect(attempts == 2)
        #expect(sleeperCalls == 1)
    }

    // MARK: - 10. HTTP 503: Retries & High Demand Response

    @Test("10. HTTP 503 retries, specifically covering 'model experiencing high demand' response")
    func test10_HTTP503_HighDemand_Retries() async throws {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        let highDemandJSON = """
        {
          "error": {
            "code": 503,
            "message": "This model is currently experiencing high demand. Spikes in demand are usually temporary. Please try again later.",
            "status": "UNAVAILABLE"
          }
        }
        """

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                ) ?? HTTPURLResponse()
                return (response, highDemandJSON.data(using: .utf8) ?? Data())
            }

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
            history: [ChatMessage(role: .user, text: "Check schedule")],
            systemPrompt: "You are Ivy",
            apiKey: "test_key"
        )

        #expect(result == "All systems operational.")
        #expect(attempts == 2)
        #expect(sleeperCalls == 1)
    }

    // MARK: - 11. HTTP 504: Retries

    @Test("11. HTTP 504 retries and recovers")
    func test11_HTTP504_Retries() async throws {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 504,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? HTTPURLResponse()
                return (response, "Gateway Timeout".data(using: .utf8) ?? Data())
            }

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
            history: [ChatMessage(role: .user, text: "504 check")],
            systemPrompt: "You are Ivy",
            apiKey: "test_key"
        )

        #expect(result == "All systems operational.")
        #expect(attempts == 2)
        #expect(sleeperCalls == 1)
    }

    // MARK: - 12. Successful Retry (503 then 200)

    @Test("12. Successful retry: first request returns 503, second request returns 200, final result is successful")
    func test12_SuccessfulRetry_503Then200_ReturnsFinalResult() async throws {
        nonisolated(unsafe) var attempts = 0

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? HTTPURLResponse()
                return (response, "Unavailable".data(using: .utf8) ?? Data())
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
            history: [ChatMessage(role: .user, text: "Retry test")],
            systemPrompt: "You are Ivy",
            apiKey: "test_key"
        )

        #expect(result == "All systems operational.")
        #expect(attempts == 2)
    }

    // MARK: - 13. Exhausted Retries (Retry limit respected, no infinite loop, clean error)

    @Test("13. Exhausted retries: every attempt returns 503, retry limit is respected, no infinite loop, clean final error returned")
    func test13_ExhaustedRetries_RespectsLimit_NoInfiniteLoop_CleanFinalError() async {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var sleeperCalls = 0

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            ) ?? HTTPURLResponse()
            return (response, "Server Unavailable".data(using: .utf8) ?? Data())
        }

        let maxRetries = 3
        let policy = RetryPolicy.testing(maxRetries: maxRetries) { _ in
            sleeperCalls += 1
        }
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        do {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Exhaust me")],
                systemPrompt: "prompt",
                apiKey: "test_key"
            )
            Issue.record("Expected serverError to be thrown upon exhaustion")
        } catch let GeminiClientError.serverError(statusCode, message) {
            #expect(statusCode == 503)
            #expect(message == "Server Unavailable")
            let clientErr = GeminiClientError.serverError(statusCode: statusCode, message: message)
            #expect(clientErr.errorDescription == "Gemini is temporarily overloaded. Please try again in a moment.")
            #expect(clientErr.localizedDescription == "Gemini is temporarily overloaded. Please try again in a moment.")
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        // 1 initial attempt + 3 retries = exactly 4 attempts
        #expect(attempts == 4)
        #expect(sleeperCalls == 3)
    }

    // MARK: - 14. Backoff: Increasing delays, fake sleeper, no real-time sleeping

    @Test("14. Backoff: increasing retry delays (1s, 2s, 4s) using injectable fake sleeper without real-time delay")
    func test14_Backoff_IncreasingDelaysWithInjectableFakeSleeper() async throws {
        nonisolated(unsafe) var attempts = 0
        nonisolated(unsafe) var recordedDelays: [TimeInterval] = []

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts <= 3 {
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

        let startTime = Date()
        let result = try await client.generateContent(
            history: [ChatMessage(role: .user, text: "Backoff check")],
            systemPrompt: "You are Ivy",
            apiKey: "test_key"
        )
        let duration = Date().timeIntervalSince(startTime)

        #expect(result == "All systems operational.")
        #expect(attempts == 4)
        #expect(recordedDelays.count == 3)
        #expect(recordedDelays[0] == 1.0) // attempt 0 failure -> ~1s
        #expect(recordedDelays[1] == 2.0) // attempt 1 failure -> ~2s
        #expect(recordedDelays[2] == 4.0) // attempt 2 failure -> ~4s
        // Verify tests did NOT actually sleep seconds
        #expect(duration < 1.0)
    }

    // MARK: - 15. Jitter: Bounded strictly within configured range

    @Test("15. Jitter stays strictly within configured bounds across multiple attempts")
    func test15_Jitter_StaysWithinConfiguredBounds() {
        let policy = RetryPolicy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxDelay: 8.0,
            jitterRange: 0.0..<0.25,
            sleeper: { _ in }
        )

        for attempt in 0...3 {
            let nominal = min(policy.maxDelay, policy.baseDelay * pow(2.0, Double(attempt)))
            for _ in 0..<100 {
                let delay = policy.delay(forAttempt: attempt)
                #expect(delay >= nominal)
                #expect(delay < nominal + 0.25)
            }
        }

        // Test deterministic injectable jitter override
        let deterministicDelay = policy.delay(forAttempt: 1, jitter: 0.123)
        #expect(deterministicDelay == 2.123)
    }

    // MARK: - 16. Request Preservation: Same payload sent on every retry

    @Test("16. Request preservation: verify the exact same request payload is sent on every retry")
    func test16_RequestPreservation_SamePayloadSentOnEveryRetry() async throws {
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

        _ = try await client.generateContent(
            history: [ChatMessage(role: .user, text: "Preserve me")],
            systemPrompt: "You are Ivy",
            tools: nil,
            apiKey: "test_key_preserve_123"
        )

        #expect(capturedBodies.count == 3)
        #expect(capturedBodies[0] == capturedBodies[1])
        #expect(capturedBodies[1] == capturedBodies[2])

        #expect(capturedHeaders.count == 3)
        #expect(capturedHeaders[0] == capturedHeaders[1])
        #expect(capturedHeaders[1] == capturedHeaders[2])

        #expect(capturedURLs.count == 3)
        #expect(capturedURLs[0] == capturedURLs[1])
        #expect(capturedURLs[1] == capturedURLs[2])
    }

    // MARK: - 17. Function-Calling Preservation: Tools, calls, responses unchanged

    @Test("17. Function-calling preservation: tool declarations, function calls, and function responses remain unchanged across retries")
    func test17_FunctionCallingPreservation_ToolDeclarationsAndCallsUnchanged() async throws {
        nonisolated(unsafe) var capturedBodies: [Data] = []

        ResilienceMockURLProtocol.requestHandler = { request in
            if let body = request.extractBodyData() {
                capturedBodies.append(body)
            }

            if capturedBodies.count < 2 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? HTTPURLResponse()
                return (response, Data())
            }

            let mockResponseJSON = """
            {
              "candidates": [
                {
                  "content": {
                    "parts": [
                      {
                        "functionCall": {
                          "name": "calendar_event",
                          "args": { "title": "Dentist", "date": "2026-10-01" },
                          "id": "call-cal-1"
                        }
                      }
                    ],
                    "role": "model"
                  },
                  "finishReason": "STOP"
                }
              ]
            }
            """
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, mockResponseJSON.data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy.testing(maxRetries: 3)
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)

        let toolDecl = ToolDeclarationWrapper(functionDeclarations: [
            FunctionDeclaration(
                name: "calendar_event",
                description: "Add an event",
                parameters: ToolParameters(properties: [
                    "title": ToolProperty(type: "STRING", description: "title"),
                    "date": ToolProperty(type: "STRING", description: "date")
                ])
            )
        ])

        let priorCall = FunctionCall(name: "calendar_event", args: ["title": "Doctor", "date": "2026-09-30"], id: "call-cal-0")
        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "Book appointment"),
            ChatMessage(role: .model, text: "", functionCall: priorCall),
            ChatMessage(role: .function, text: "Booked", functionResponse: FunctionResponse(name: "calendar_event", response: ["status": "ok"]))
        ]

        let response = try await client.generateContent(
            history: history,
            systemPrompt: "You are Ivy",
            tools: [toolDecl],
            apiKey: "valid_key"
        )

        #expect(capturedBodies.count == 2)
        #expect(capturedBodies[0] == capturedBodies[1])

        // Verify tool declaration structure and functionResponse preserved in payload
        for body in capturedBodies {
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let tools = json?["tools"] as? [[String: Any]]
            #expect(tools?.count == 1)

            let contents = json?["contents"] as? [[String: Any]]
            #expect(contents?.count == 3)

            let lastTurn = contents?[2]
            let lastParts = lastTurn?["parts"] as? [[String: Any]]
            let funcResp = lastParts?.first?["functionResponse"] as? [String: Any]
            #expect(funcResp?["name"] as? String == "calendar_event")
        }

        #expect(response.functionCalls.count == 1)
        #expect(response.functionCalls[0].name == "calendar_event")
        #expect(response.functionCalls[0].args["title"]?.stringValue == "Dentist")
    }

    // MARK: - 18. thought_signature: Part level, never inside function_call

    @Test("18. thought_signature remains strictly at Part level and never appears inside function_call")
    func test18_ThoughtSignature_RemainsAtPartLevelNeverInFunctionCall() async throws {
        nonisolated(unsafe) var capturedBodies: [Data] = []

        ResilienceMockURLProtocol.requestHandler = { request in
            if let body = request.extractBodyData() {
                capturedBodies.append(body)
            }

            if capturedBodies.count < 2 {
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

        let sig = "crypto-sig-token-part-level-999"
        let call = FunctionCall(name: "run_shell", args: ["command": "echo test"], id: "call-sh-1", thoughtSignature: sig)
        let part = Part(functionCall: call, thoughtSignature: sig)

        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "Run command"),
            ChatMessage(role: .model, text: "", functionCall: call, functionCallPart: part),
            ChatMessage(role: .function, text: "Executed", functionResponse: FunctionResponse(name: "run_shell", response: ["result": "test"]))
        ]

        _ = try await client.generateContent(
            history: history,
            systemPrompt: "You are Ivy",
            tools: nil,
            apiKey: "valid_key"
        )

        #expect(capturedBodies.count == 2)
        for body in capturedBodies {
            let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            let contents = json?["contents"] as? [[String: Any]]
            guard let modelTurn = contents?[1],
                  let parts = modelTurn["parts"] as? [[String: Any]],
                  let modelPart = parts.first else {
                Issue.record("Missing model turn in payload")
                continue
            }

            // Verify thought_signature is at the Part level
            let partSig = (modelPart["thoughtSignature"] ?? modelPart["thought_signature"]) as? String
            #expect(partSig == sig)

            // Verify thought_signature is NOT in functionCall dictionary
            let callDict = modelPart["functionCall"] as? [String: Any]
            #expect(callDict?["thought_signature"] == nil)
            #expect(callDict?["thoughtSignature"] == nil)
        }
    }

    // MARK: - 19. No Duplicate Conversation State

    @Test("19. No duplicate conversation state in IvyBrain: retries do not duplicate user messages or function responses")
    @MainActor
    func test19_NoDuplicateConversationState_NoDuplicateUserOrFunctionResponses() async {
        nonisolated(unsafe) var attempts = 0

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            if attempts == 1 {
                let response = HTTPURLResponse(
                    url: request.url ?? URL(string: "https://example.com")!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                ) ?? HTTPURLResponse()
                return (response, "Unavailable".data(using: .utf8) ?? Data())
            }

            let responseJSON = """
            {
              "candidates": [
                {
                  "content": {
                    "parts": [
                      { "text": "Task processed successfully." }
                    ],
                    "role": "model"
                  },
                  "finishReason": "STOP"
                }
              ]
            }
            """
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            ) ?? HTTPURLResponse()
            return (response, responseJSON.data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy.testing(maxRetries: 3)
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)
        let brain = IvyBrain(client: client, apiKey: "valid_key")

        await brain.send("Execute workflow")

        #expect(attempts == 2)
        // Verify exactly 2 messages exist in history: 1 user, 1 model (no duplicated user message)
        #expect(brain.messages.count == 2)
        #expect(brain.messages[0].role == .user)
        #expect(brain.messages[0].text == "Execute workflow")
        #expect(brain.messages[1].role == .model)
        #expect(brain.messages[1].text == "Task processed successfully.")
    }

    // MARK: - 20. Error Message: Clean user-facing error, no leaked credentials

    @Test("20. Error message: exhausted 503 produces clean user-facing error and never exposes API key or auth information")
    @MainActor
    func test20_ErrorMessage_Exhausted503ProducesCleanErrorWithoutExposingAPIKey() async {
        let secretKey = "AIzaSySecretApiKeyDoNotLeak999"
        nonisolated(unsafe) var attempts = 0

        ResilienceMockURLProtocol.requestHandler = { request in
            attempts += 1
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.com")!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            ) ?? HTTPURLResponse()
            let rawError = "{\"error\": {\"code\": 503, \"message\": \"This model is currently experiencing high demand.\", \"status\": \"UNAVAILABLE\"}}"
            return (response, rawError.data(using: .utf8) ?? Data())
        }

        let policy = RetryPolicy.testing(maxRetries: 3)
        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: policy)
        let brain = IvyBrain(client: client, apiKey: secretKey)

        await brain.send("Organize files")

        #expect(attempts == 4)
        let cleanExpected = "Gemini is temporarily overloaded. Please try again in a moment."
        #expect(brain.errorMessage == cleanExpected)

        let lastMessage = brain.messages.last
        #expect(lastMessage?.role == .model)
        #expect(lastMessage?.isError == true)
        #expect(lastMessage?.text.contains(cleanExpected) == true)

        // Verify API key is NOT leaked anywhere in messages or error descriptions
        for msg in brain.messages {
            #expect(!msg.text.contains(secretKey))
        }
        if let errMsg = brain.errorMessage {
            #expect(!errMsg.contains(secretKey))
        }
    }

    // MARK: - Network Errors & Auxiliary Invariants

    @Test("Transient network errors (timedOut, networkConnectionLost, notConnectedToInternet) retry and recover")
    func testTransientNetworkErrorsRetryAndRecover() async throws {
        let transientErrors = [
            URLError(.timedOut),
            URLError(.networkConnectionLost),
            URLError(.notConnectedToInternet)
        ]

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
                history: [ChatMessage(role: .user, text: "Net error check")],
                systemPrompt: "You are Ivy",
                apiKey: "test_key"
            )

            #expect(result == "All systems operational.")
            #expect(attempts == 2)
        }
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
}
