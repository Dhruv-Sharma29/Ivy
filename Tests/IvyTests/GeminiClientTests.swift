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
            // The key is sent in the header only, never in the URL.
            #expect(request.url?.absoluteString.contains("test_api_key_123") == false)
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test_api_key_123")

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

    @Test("Client maps HTTP 401 Unauthorized to invalidAPIKey error")
    func testUnauthorized401Error() async {
        let errorJSON = """
        {
          "error": {
            "code": 401,
            "message": "API key expired or unauthorized",
            "status": "UNAUTHENTICATED"
          }
        }
        """

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, errorJSON.data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        await #expect(throws: GeminiClientError.invalidAPIKey("API key expired or unauthorized")) {
            _ = try await client.generateContent(
                history: [ChatMessage(role: .user, text: "Hello")],
                systemPrompt: "You are Ivy",
                apiKey: "expired_key"
            )
        }
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

        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: .testing)
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

        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: .testing)
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

        let client = URLSessionGeminiClient(session: makeMockSession(), retryPolicy: .testing)
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

    // MARK: - Tool & Function Calling Tests

    @Test("Client sends tools in request and parses functionCall response")
    func testClientSendsToolsAndParsesFunctionCall() async throws {
        let mockResponseJSON = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "functionCall": {
                      "name": "open_app",
                      "args": { "name": "Safari" },
                      "id": "call-safari-1"
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

        MockURLProtocol.requestHandler = { request in
            guard let httpBody = request.extractBodyData(),
                  let json = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
                  let tools = json["tools"] as? [[String: Any]] else {
                Issue.record("Tools missing from request body")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }

            #expect(!tools.isEmpty)

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, mockResponseJSON.data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        let toolDecl = ToolDeclarationWrapper(functionDeclarations: [
            FunctionDeclaration(
                name: "open_app",
                description: "Opens an application",
                parameters: ToolParameters(properties: ["name": ToolProperty(type: "STRING", description: "app")])
            )
        ])

        let result = try await client.generateContent(
            history: [ChatMessage(role: .user, text: "Open Safari")],
            systemPrompt: "Ivy prompt",
            tools: [toolDecl],
            apiKey: "valid_key"
        )

        #expect(result.text == nil)
        #expect(result.functionCalls.count == 1)
        #expect(result.functionCalls.first?.name == "open_app")
        #expect(result.functionCalls.first?.args["name"]?.stringValue == "Safari")
        #expect(result.functionCalls.first?.id == "call-safari-1")
    }

    @Test("Client properly serializes functionResponse in history")
    func testClientEncodesFunctionResponseInHistory() async throws {
        let mockResponseJSON = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "Safari is running." }
                ],
                "role": "model"
              },
              "finishReason": "STOP"
            }
          ]
        }
        """

        MockURLProtocol.requestHandler = { request in
            guard let httpBody = request.extractBodyData(),
                  let json = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
                  let contents = json["contents"] as? [[String: Any]] else {
                Issue.record("Invalid request JSON")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }

            #expect(contents.count == 3)
            let lastContent = contents[2]
            guard let parts = lastContent["parts"] as? [[String: Any]],
                  let funcResp = parts.first?["functionResponse"] as? [String: Any] else {
                Issue.record("functionResponse missing from history content")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }

            #expect(funcResp["name"] as? String == "open_app")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, mockResponseJSON.data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "Open Safari"),
            ChatMessage(role: .model, text: "", functionCall: FunctionCall(name: "open_app", args: ["name": "Safari"])),
            ChatMessage(role: .function, text: "Opened Safari successfully.", functionResponse: FunctionResponse(name: "open_app", response: ["result": "Opened Safari successfully."]))
        ]

        let result = try await client.generateContent(
            history: history,
            systemPrompt: "You are Ivy",
            tools: nil,
            apiKey: "valid_key"
        )

        #expect(result.text == "Safari is running.")
    }

    @Test("Client parses functionCall response preserving thought_signature")
    func testClientParsesFunctionCallWithThoughtSignature() async throws {
        let mockResponseJSON = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "functionCall": {
                      "name": "open_app",
                      "args": { "name": "Safari" },
                      "id": "call-safari-sig"
                    },
                    "thought_signature": "cryptographic-signature-token-777"
                  }
                ],
                "role": "model"
              },
              "finishReason": "STOP"
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
            return (response, mockResponseJSON.data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        let result = try await client.generateContent(
            history: [ChatMessage(role: .user, text: "Open Safari")],
            systemPrompt: "Ivy prompt",
            tools: nil,
            apiKey: "valid_key"
        )

        #expect(result.functionCalls.count == 1)
        #expect(result.functionCalls[0].name == "open_app")
        #expect(result.functionCalls[0].thoughtSignature == "cryptographic-signature-token-777")
        #expect(result.functionCallParts.count == 1)
        #expect(result.functionCallParts[0].thoughtSignature == "cryptographic-signature-token-777")
    }

    @Test("Client reconstructs next request preserving original functionCall part and thought_signature")
    func testClientReconstructsNextRequestWithOriginalFunctionCallPartAndSignature() async throws {
        let mockResponseJSON = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "Safari is now ready." }
                ],
                "role": "model"
              },
              "finishReason": "STOP"
            }
          ]
        }
        """

        MockURLProtocol.requestHandler = { request in
            guard let httpBody = request.extractBodyData(),
                  let json = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
                  let contents = json["contents"] as? [[String: Any]] else {
                Issue.record("Failed to parse request JSON contents")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }

            #expect(contents.count == 3)

            // Validate model turn has exact thought_signature
            let modelTurn = contents[1]
            #expect(modelTurn["role"] as? String == "model")
            guard let modelParts = modelTurn["parts"] as? [[String: Any]], let modelPart = modelParts.first else {
                Issue.record("Missing model parts")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }

            #expect((modelPart["thoughtSignature"] ?? modelPart["thought_signature"]) as? String == "sig-token-preserve-exact")
            guard let callDict = modelPart["functionCall"] as? [String: Any] else {
                Issue.record("Missing functionCall in model part")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            #expect(callDict["name"] as? String == "open_app")
            #expect(callDict["thought_signature"] == nil)
            #expect(callDict["thoughtSignature"] == nil)

            // Validate functionResponse turn
            let respTurn = contents[2]
            #expect(respTurn["role"] as? String == "user")
            guard let respParts = respTurn["parts"] as? [[String: Any]],
                  let respDict = respParts.first?["functionResponse"] as? [String: Any] else {
                Issue.record("Missing functionResponse in user turn")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            #expect(respDict["name"] as? String == "open_app")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, mockResponseJSON.data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        let call = FunctionCall(name: "open_app", args: ["name": "Safari"], id: "call-safari-1", thoughtSignature: "sig-token-preserve-exact")
        let part = Part(functionCall: call, thoughtSignature: "sig-token-preserve-exact")

        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "Open Safari"),
            ChatMessage(role: .model, text: "", functionCall: call, functionCallPart: part),
            ChatMessage(role: .function, text: "Safari opened.", functionResponse: FunctionResponse(name: "open_app", response: ["result": "Safari opened."]))
        ]

        let result = try await client.generateContent(
            history: history,
            systemPrompt: "You are Ivy",
            tools: nil,
            apiKey: "valid_key"
        )

        #expect(result.text == "Safari is now ready.")
    }

    @Test("Client preserves multiple tool-call turns with respective thought_signatures")
    func testClientPreservesMultipleToolTurnsWithSignatures() async throws {
        let mockResponseJSON = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "All tools completed." }
                ],
                "role": "model"
              },
              "finishReason": "STOP"
            }
          ]
        }
        """

        MockURLProtocol.requestHandler = { request in
            guard let httpBody = request.extractBodyData(),
                  let json = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
                  let contents = json["contents"] as? [[String: Any]] else {
                Issue.record("Failed to parse request JSON contents")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }

            #expect(contents.count == 5)

            // Turn 1: model tool call with sig 1
            let turn1Model = contents[1]
            let turn1Parts = turn1Model["parts"] as? [[String: Any]]
            #expect((turn1Parts?.first?["thoughtSignature"] ?? turn1Parts?.first?["thought_signature"]) as? String == "sig-tool-turn-1")
            let callDict1 = turn1Parts?.first?["functionCall"] as? [String: Any]
            #expect(callDict1?["thought_signature"] == nil)
            #expect(callDict1?["thoughtSignature"] == nil)

            // Turn 2: model tool call with sig 2
            let turn2Model = contents[3]
            let turn2Parts = turn2Model["parts"] as? [[String: Any]]
            #expect((turn2Parts?.first?["thoughtSignature"] ?? turn2Parts?.first?["thought_signature"]) as? String == "sig-tool-turn-2")
            let callDict2 = turn2Parts?.first?["functionCall"] as? [String: Any]
            #expect(callDict2?["thought_signature"] == nil)
            #expect(callDict2?["thoughtSignature"] == nil)

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, mockResponseJSON.data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        let call1 = FunctionCall(name: "run_applescript", args: ["script": "beep"], thoughtSignature: "sig-tool-turn-1")
        let part1 = Part(functionCall: call1, thoughtSignature: "sig-tool-turn-1")

        let call2 = FunctionCall(name: "open_app", args: ["name": "Notes"], thoughtSignature: "sig-tool-turn-2")
        let part2 = Part(functionCall: call2, thoughtSignature: "sig-tool-turn-2")

        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "Do both tasks"),
            ChatMessage(role: .model, text: "", functionCall: call1, functionCallPart: part1),
            ChatMessage(role: .function, text: "Beeped.", functionResponse: FunctionResponse(name: "run_applescript", response: ["result": "beeped"])),
            ChatMessage(role: .model, text: "", functionCall: call2, functionCallPart: part2),
            ChatMessage(role: .function, text: "Opened Notes.", functionResponse: FunctionResponse(name: "open_app", response: ["result": "Opened Notes."]))
        ]

        let result = try await client.generateContent(
            history: history,
            systemPrompt: "You are Ivy",
            tools: nil,
            apiKey: "valid_key"
        )

        #expect(result.text == "All tools completed.")
    }

    @Test("Client handles missing thought_signature without error or signature fabrication")
    func testClientHandlesMissingThoughtSignatureGracefully() async throws {
        let mockResponseJSON = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "App opened successfully." }
                ],
                "role": "model"
              },
              "finishReason": "STOP"
            }
          ]
        }
        """

        MockURLProtocol.requestHandler = { request in
            guard let httpBody = request.extractBodyData(),
                  let json = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
                  let contents = json["contents"] as? [[String: Any]] else {
                Issue.record("Failed to parse request JSON contents")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }

            // Verify no thought_signature was fabricated
            let modelTurn = contents[1]
            let modelParts = modelTurn["parts"] as? [[String: Any]]
            #expect(modelParts?.first?["thought_signature"] == nil)
            #expect(modelParts?.first?["thoughtSignature"] == nil)

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, mockResponseJSON.data(using: .utf8)!)
        }

        let client = URLSessionGeminiClient(session: makeMockSession())
        let call = FunctionCall(name: "open_app", args: ["name": "Safari"])
        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "Open Safari"),
            ChatMessage(role: .model, text: "", functionCall: call),
            ChatMessage(role: .function, text: "Opened.", functionResponse: FunctionResponse(name: "open_app", response: ["result": "Opened."]))
        ]

        let result = try await client.generateContent(
            history: history,
            systemPrompt: "You are Ivy",
            tools: nil,
            apiKey: "valid_key"
        )

        #expect(result.text == "App opened successfully.")
    }

    @Test("Client decodes real captured Gemini 3.8 Flash response and emits thoughtSignature in next request")
    func testRealCapturedGeminiFlashShapePreservesThoughtSignatureAcrossTurns() async throws {
        let realCapturedWireJSON = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "functionCall": {
                      "name": "open_app",
                      "args": { "name": "Safari" }
                    },
                    "thoughtSignature": "EvsDCvgDAWkUfRNP/MWBDKWCmdgHTBGuSRWvYnIYtReRirfDEKTcjLJfVseYhz6rmFi/Gay5Bzgx36O5HdmgXtnOFnAHQMXQ3Otk+qHhMTvKiuDN4J2UPbY2XLsTUTSJ94Lobh1Go7jHt4jt2l3MRx2547CqJPESY9JH3791AS57Dym7bUaagvb8uzyXRFDj7IsPpUpmG80oFHc2tVJ/n3G8MGX0ukRS+JCBhEAI+RkaEw0fYnhTgt89rXLdhXcW8B7WSffBLOZctionz/ja60RWaHaMeeAXilf4EEbNULffV5KwVzMWhly45CyQGj1Ge6+M5RA7h77REP5jd/nCVVsR9hPWiUIK6GhvuPjwW/V9Ah7kLrmrilJ9iOAkX3c9fjOeRgnuUfe2dUsD1VFQ0YcUl67PdOqVeEPAHSD4FRm7ooWjMlGjj0MnEjgQOxg6vKZFUGXZz/cesqgMqUKttecTiv3eJCztSYTwN5juFinY8MLfA88grVvJ4BkqFHycjiC1OwK9aOb0ID1eyDB7UOQ7ehTSzBiSKXVu+L1mke2M6Qn8K7RXA/Z9YvG0+rV+5L5OL5SHNxyTIA44oTiBmnTudp/lYbs4M21vq5dfNcRGSVpVv3DwCuzDkuVgLE3yS7nrLl3B3aHv2LboqNxAsdXu/Qh9lXkaAz5d/beO"
                  }
                ],
                "role": "model"
              },
              "finishReason": "STOP",
              "index": 0
            }
          ],
          "usageMetadata": {
            "promptTokenCount": 240,
            "candidatesTokenCount": 43,
            "totalTokenCount": 376
          },
          "modelVersion": "gemini-3.8-flash",
          "responseId": "KvG3atnaC5fRg8UPp9Wt-A4"
        }
        """

        let client = URLSessionGeminiClient(session: makeMockSession())

        // 1. Decode real captured JSON directly
        let responseData = realCapturedWireJSON.data(using: .utf8)!
        let geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: responseData)
        #expect(geminiResponse.functionCalls.count == 1)
        #expect(geminiResponse.functionCallParts.count == 1)

        let capturedSig = "EvsDCvgDAWkUfRNP/MWBDKWCmdgHTBGuSRWvYnIYtReRirfDEKTcjLJfVseYhz6rmFi/Gay5Bzgx36O5HdmgXtnOFnAHQMXQ3Otk+qHhMTvKiuDN4J2UPbY2XLsTUTSJ94Lobh1Go7jHt4jt2l3MRx2547CqJPESY9JH3791AS57Dym7bUaagvb8uzyXRFDj7IsPpUpmG80oFHc2tVJ/n3G8MGX0ukRS+JCBhEAI+RkaEw0fYnhTgt89rXLdhXcW8B7WSffBLOZctionz/ja60RWaHaMeeAXilf4EEbNULffV5KwVzMWhly45CyQGj1Ge6+M5RA7h77REP5jd/nCVVsR9hPWiUIK6GhvuPjwW/V9Ah7kLrmrilJ9iOAkX3c9fjOeRgnuUfe2dUsD1VFQ0YcUl67PdOqVeEPAHSD4FRm7ooWjMlGjj0MnEjgQOxg6vKZFUGXZz/cesqgMqUKttecTiv3eJCztSYTwN5juFinY8MLfA88grVvJ4BkqFHycjiC1OwK9aOb0ID1eyDB7UOQ7ehTSzBiSKXVu+L1mke2M6Qn8K7RXA/Z9YvG0+rV+5L5OL5SHNxyTIA44oTiBmnTudp/lYbs4M21vq5dfNcRGSVpVv3DwCuzDkuVgLE3yS7nrLl3B3aHv2LboqNxAsdXu/Qh9lXkaAz5d/beO"
        #expect(geminiResponse.functionCallParts[0].thoughtSignature == capturedSig)

        // 2. Next turn: Ivy sends follow-up with the captured part + tool result
        let finalReplyJSON = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "Safari is running, as requested." }
                ],
                "role": "model"
              },
              "finishReason": "STOP"
            }
          ]
        }
        """

        MockURLProtocol.requestHandler = { request in
            guard let httpBody = request.extractBodyData(),
                  let json = try? JSONSerialization.jsonObject(with: httpBody) as? [String: Any],
                  let contents = json["contents"] as? [[String: Any]] else {
                Issue.record("Failed to parse request JSON contents")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }

            #expect(contents.count == 3)

            // Turn 1: model tool call with captured signature
            let modelTurn = contents[1]
            #expect(modelTurn["role"] as? String == "model")
            guard let modelParts = modelTurn["parts"] as? [[String: Any]], let modelPart = modelParts.first else {
                Issue.record("Missing model parts in request")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }

            #expect(modelPart["thoughtSignature"] as? String == capturedSig)
            guard let callDict = modelPart["functionCall"] as? [String: Any] else {
                Issue.record("Missing functionCall in modelPart")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            #expect(callDict["name"] as? String == "open_app")
            #expect(callDict["thoughtSignature"] == nil)
            #expect(callDict["thought_signature"] == nil)

            // Turn 2: functionResponse
            let respTurn = contents[2]
            #expect(respTurn["role"] as? String == "user")
            guard let respParts = respTurn["parts"] as? [[String: Any]], let respPart = respParts.first else {
                Issue.record("Missing response parts")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            guard let funcResp = respPart["functionResponse"] as? [String: Any] else {
                Issue.record("Missing functionResponse")
                return (HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!, Data())
            }
            #expect(funcResp["name"] as? String == "open_app")

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, finalReplyJSON.data(using: .utf8)!)
        }

        let history: [ChatMessage] = [
            ChatMessage(role: .user, text: "Open Safari"),
            ChatMessage(
                role: .model,
                text: "",
                functionCall: geminiResponse.functionCalls[0],
                functionCallPart: geminiResponse.functionCallParts[0]
            ),
            ChatMessage(
                role: .function,
                text: "Opened Safari",
                functionResponse: FunctionResponse(name: "open_app", response: ["result": "Launched Safari"])
            )
        ]

        let result = try await client.generateContent(
            history: history,
            systemPrompt: "You are Ivy",
            tools: nil,
            apiKey: "valid_key"
        )

        #expect(result.text == "Safari is running, as requested.")
    }
}

// MARK: - Test Helpers

extension URLRequest {
    func extractBodyData() -> Data? {
        if let body = self.httpBody {
            return body
        }
        guard let stream = self.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}
