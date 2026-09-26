import Testing
import Foundation
@testable import IvyCore

@Suite("Gemini DTO Tests")
struct GeminiDTOTests {

    @Test("GeminiRequest JSON encoding matches Gemini REST specification")
    func testRequestEncoding() throws {
        let request = GeminiRequest(
            systemInstruction: SystemInstruction(text: "Be sarcastic"),
            contents: [
                Content(role: "user", text: "What's the weather?"),
                Content(role: "model", text: "Look outside, genius.")
            ]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(request)

        guard let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Expected valid JSON dictionary")
            return
        }

        #expect(jsonObject["systemInstruction"] != nil)
        guard let contents = jsonObject["contents"] as? [[String: Any]] else {
            Issue.record("Expected contents array")
            return
        }

        #expect(contents.count == 2)
        #expect(contents[0]["role"] as? String == "user")
        #expect(contents[1]["role"] as? String == "model")
    }

    @Test("GeminiResponse decodes successful response payload")
    func testResponseDecodingSuccess() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "text": "Oh, wonderful. Another task for me."
                  }
                ],
                "role": "model"
              },
              "finishReason": "STOP"
            }
          ]
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)

        #expect(response.firstText == "Oh, wonderful. Another task for me.")
        #expect(response.candidates?.first?.finishReason == "STOP")
        #expect(response.error == nil)
    }

    @Test("GeminiResponse decodes API error payload")
    func testResponseDecodingError() throws {
        let json = """
        {
          "error": {
            "code": 400,
            "message": "API key not valid. Please pass a valid API key.",
            "status": "INVALID_ARGUMENT"
          }
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)

        #expect(response.firstText == nil)
        #expect(response.error?.code == 400)
        #expect(response.error?.status == "INVALID_ARGUMENT")
        #expect(response.error?.message.contains("API key not valid") == true)
    }

    @Test("GeminiDTO initializers and properties work as expected")
    func testDTOInitializers() {
        let part = Part(text: "Hello")
        #expect(part.text == "Hello")

        let sys = SystemInstruction(parts: [part])
        #expect(sys.parts.count == 1)

        let content = Content(role: "user", parts: [part])
        #expect(content.role == "user")
        #expect(content.parts.first?.text == "Hello")

        let candidate = Candidate(content: content, finishReason: "STOP")
        #expect(candidate.finishReason == "STOP")

        let apiError = GeminiAPIError(code: 500, message: "Internal Error", status: "INTERNAL")
        let errorResponse = GeminiResponse(candidates: nil, error: apiError)
        #expect(errorResponse.error?.code == 500)
    }
}
