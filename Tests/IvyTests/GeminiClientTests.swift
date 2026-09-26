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

    @Test("Client sends valid request and parses successful response")
    func testSuccessfulGeneration() async throws {
        let mockResponseJSON = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
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

        let client = URLSessionGeminiClient(session: makeMockSession())
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

    @Test("GeminiClientError descriptions are non-empty")
    func testErrorDescriptions() {
        let errors: [GeminiClientError] = [
            .missingAPIKey,
            .invalidURL,
            .invalidAPIKey("bad"),
            .rateLimited,
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
