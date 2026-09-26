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

    @Test("Gemini 3.8 thinkingConfig encodes thinking_level correctly")
    func testThinkingConfigEncoding() throws {
        let request = GeminiRequest(
            contents: [Content(role: "user", text: "Explain quantum physics")],
            generationConfig: GenerationConfig(thinkingConfig: ThinkingConfig(thinkingLevel: .low))
        )

        let data = try JSONEncoder().encode(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let genConfig = json["generationConfig"] as? [String: Any],
              let thinkConfig = genConfig["thinkingConfig"] as? [String: Any] else {
            Issue.record("Failed to serialize generationConfig.thinkingConfig")
            return
        }

        #expect(thinkConfig["thinking_level"] as? String == "low")
    }

    @Test("Gemini 3.8 thought parts are filtered from user-facing text")
    func testThoughtPartsFiltered() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "thought": true,
                    "text": "The user wants a sarcastic retort. Let me come up with something witty."
                  },
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

        // Must filter out the internal thought and return only the final text
        #expect(response.firstText == "Oh, wonderful. Another task for me.")
    }

    @Test("GeminiRequest with nil systemInstruction and nil generationConfig encodes minimal JSON")
    func testMinimalRequestEncoding() throws {
        let request = GeminiRequest(
            systemInstruction: nil,
            contents: [Content(role: "user", text: "Minimal turn")],
            generationConfig: nil
        )

        let data = try JSONEncoder().encode(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Failed to parse JSON")
            return
        }

        #expect(json["contents"] != nil)
        #expect(json["systemInstruction"] == nil)
        #expect(json["generationConfig"] == nil)
    }

    @Test("GeminiRequest encodes multi-turn conversation and multiple ThinkingLevels")
    func testMultiTurnAndThinkingLevels() throws {
        for level in [ThinkingLevel.low, ThinkingLevel.medium, ThinkingLevel.high] {
            let request = GeminiRequest(
                systemInstruction: SystemInstruction(text: "Be sharp"),
                contents: [
                    Content(role: "user", text: "Question 1"),
                    Content(role: "model", text: "Answer 1"),
                    Content(role: "user", text: "Question 2")
                ],
                generationConfig: GenerationConfig(thinkingConfig: ThinkingConfig(thinkingLevel: level))
            )

            let data = try JSONEncoder().encode(request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contents = json["contents"] as? [[String: Any]],
                  let genConfig = json["generationConfig"] as? [String: Any],
                  let thinkConfig = genConfig["thinkingConfig"] as? [String: Any] else {
                Issue.record("Failed to decode JSON for level \(level)")
                return
            }

            #expect(contents.count == 3)
            #expect(contents[0]["role"] as? String == "user")
            #expect(contents[1]["role"] as? String == "model")
            #expect(contents[2]["role"] as? String == "user")
            #expect(thinkConfig["thinking_level"] as? String == level.rawValue)
        }
    }

    @Test("GeminiResponse concatenates multiple text parts in single candidate")
    func testMultipleTextPartsConcatenation() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  { "text": "Part 1. " },
                  { "text": "Part 2." }
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
        #expect(response.firstText == "Part 1. Part 2.")
    }

    @Test("GeminiResponse gracefully handles candidates with empty parts or finishReason flags")
    func testFinishReasonsAndEmptyParts() throws {
        for reason in ["SAFETY", "MAX_TOKENS", "RECITATION", "OTHER"] {
            let json = """
            {
              "candidates": [
                {
                  "content": {
                    "parts": [],
                    "role": "model"
                  },
                  "finishReason": "\(reason)"
                }
              ]
            }
            """

            let data = json.data(using: .utf8)!
            let response = try JSONDecoder().decode(GeminiResponse.self, from: data)
            #expect(response.candidates?.first?.finishReason == reason)
            #expect(response.firstText == nil || response.firstText == "")
        }
    }

    @Test("GeminiResponse falls back to thought parts if only thought parts are returned")
    func testFallbackToThoughtPartsIfNoOtherText() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "thought": true,
                    "text": "Only thought content available."
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
        #expect(response.firstText == "Only thought content available.")
    }

    @Test("GeminiResponse searches subsequent candidates if first candidate has no valid content")
    func testCandidateFallbackWhenFirstCandidateEmpty() throws {
        let json = """
        {
          "candidates": [
            {
              "content": null,
              "finishReason": "SAFETY"
            },
            {
              "content": {
                "parts": [
                  { "text": "Valid text from second candidate." }
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
        #expect(response.firstText == "Valid text from second candidate.")
    }
}
