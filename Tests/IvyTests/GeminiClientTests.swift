import Testing
import Foundation
@testable import IvyCore

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        guard let handler = MockURLProtocol.requestHandler else {
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

@Suite("Gemini Client Unit Tests", .serialized)
struct GeminiClientTests {

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("Client throws missingAPIKey when empty key provided")
    func testMissingAPIKey() async {
        let client = URLSessionGeminiClient(session: makeMockSession())
        await #expect(throws: GeminiClientError.missingAPIKey) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "hello")],
                systemPrompt: "prompt",
                apiKey: "   "
            )
        }
    }

    @Test("Client sends valid request targeting gemini-3.8-flash and parses response")
    func testSuccessfulGeneration() async throws {
        let mockResponseJSON = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "thought": true, "text": "Analyzing the user's intent." },
                  { "text": "I suppose I can answer that for you." }
                ],
                "role": "model"
              },
              "finishReason": "STOP"
            }
          ]
        }
        """

        MockURLProtocol.requestHandler = { request in
            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString.contains("gemini-3.8-flash:generateContent") == true)
            #expect(request.url?.query?.contains("key=test_api_key_123") == true)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, mockResponseJSON.data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession(), thinkingLevel: .medium)
        let reply = try await client.generateContent(
            history: [ChatMessage(role: .user, text: "Do something")],
            systemPrompt: "You are Ivy",
            apiKey: "test_api_key_123"
        )

        #expect(reply == "I suppose I can answer that for you.")
    }

    @Test("Client maps HTTP 400 with invalid API key to invalidAPIKey error")
    func testInvalidAPIKeyError() async {
        let errorJSON = """
        {
          "error": {
            "code": 400,
            "message": "API key not valid",
            "status": "INVALID_ARGUMENT"
          }
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 400,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, errorJSON.data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        await #expect(throws: GeminiClientError.invalidAPIKey("API key not valid")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Hello")],
                systemPrompt: "You are Ivy",
                apiKey: "bad_key"
            )
        }
    }

    @Test("Client maps HTTP 404 to modelNotFound error")
    func testModelNotFoundError() async {
        let errorJSON = """
        {
          "error": {
            "code": 404,
            "message": "This model is no longer available. Use gemini-3.8-flash.",
            "status": "NOT_FOUND"
          }
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 404,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, errorJSON.data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        await #expect(throws: GeminiClientError.modelNotFound("This model is no longer available. Use gemini-3.8-flash.")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Hello")],
                systemPrompt: "You are Ivy",
                apiKey: "valid_key"
            )
        }
    }

    @Test("Client maps HTTP 429 to rateLimited error")
    func testRateLimitedError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        await #expect(throws: GeminiClientError.rateLimited) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Hello")],
                systemPrompt: "You are Ivy",
                apiKey: "valid_key"
            )
        }
    }

    @Test("Client maps HTTP 500 to serverError")
    func testServerError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            let errorJSON = "{\"error\": {\"code\": 500, \"message\": \"Internal Server Error\", \"status\": \"INTERNAL\"}}"
            return (response, errorJSON.data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        await #expect(throws: GeminiClientError.serverError(statusCode: 500, message: "Internal Server Error")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Hello")],
                systemPrompt: "You are Ivy",
                apiKey: "valid_key"
            )
        }
    }

    @Test("Client maps HTTP 403 Forbidden to invalidAPIKey error")
    func testForbiddenError() async {
        let errorJSON = """
        {
          "error": {
            "code": 403,
            "message": "The caller does not have permission",
            "status": "PERMISSION_DENIED"
          }
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, errorJSON.data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        await #expect(throws: GeminiClientError.invalidAPIKey("The caller does not have permission")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Hello")],
                systemPrompt: "You are Ivy",
                apiKey: "restricted_key"
            )
        }
    }

    @Test("Client maps HTTP 503 to serverError")
    func testServiceUnavailableError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        await #expect(throws: GeminiClientError.serverError(statusCode: 503, message: "HTTP 503")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Hello")],
                systemPrompt: "You are Ivy",
                apiKey: "valid_key"
            )
        }
    }

    @Test("Client maps malformed JSON to decodingError")
    func testMalformedJSON() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, "not valid json at all".data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        do {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Hello")],
                systemPrompt: "You are Ivy",
                apiKey: "valid_key"
            )
            Issue.record("Expected decodingError to be thrown")
        } catch let GeminiClientError.decodingError(msg) {
            #expect(!msg.isEmpty)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }

    @Test("Client throws emptyResponse when candidate parts contain empty string")
    func testEmptyCandidateText() async {
        let emptyJSON = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "" }
                ],
                "role": "model"
              }
            }
          ]
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, emptyJSON.data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        await #expect(throws: GeminiClientError.emptyResponse) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Hello")],
                systemPrompt: "You are Ivy",
                apiKey: "valid_key"
            )
        }
    }

    @Test("Client throws emptyResponse when all history messages are whitespace")
    func testAllWhitespaceHistory() async {
        let client = URLSessionGeminiClient(session: makeMockSession())
        await #expect(throws: GeminiClientError.emptyResponse) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "   "), ChatMessage(role: .model, text: "\n\t")],
                systemPrompt: "You are Ivy",
                apiKey: "valid_key"
            )
        }
    }

    @Test("GeminiClientError descriptions are non-empty")
    func testErrorDescriptions() {
        let errors: [GeminiClientError] = [
            .missingAPIKey,
            .invalidURL,
            .invalidAPIKey("bad"),
            .rateLimited,
            .modelNotFound("model missing"),
            .serverError(statusCode: 500, message: "fail"),
            .networkError("fail"),
            .decodingError("fail"),
            .emptyResponse
        ]

        for err in errors {
            #expect(err.errorDescription != nil)
            #expect(!err.errorDescription!.isEmpty)
        }
    }
}
