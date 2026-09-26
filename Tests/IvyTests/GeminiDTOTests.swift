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

    // MARK: - AnyCodable & Tool DTO Tests

    @Test("AnyCodable encodes and decodes primitives, arrays, and dictionaries")
    func testAnyCodablePrimitives() throws {
        let strVal: AnyCodable = "Safari"
        let intVal: AnyCodable = 42
        let dblVal: AnyCodable = 3.14
        let boolVal: AnyCodable = true
        let nullVal: AnyCodable = nil
        let dictVal: AnyCodable = ["appName": "Notes", "timeout": 10]
        let arrVal: AnyCodable = ["a", "b", 3]

        #expect(strVal.stringValue == "Safari")
        #expect(intVal.intValue == 42)
        #expect(dblVal.doubleValue == 3.14)
        #expect(intVal.doubleValue == 42.0)
        #expect(boolVal.boolValue == true)
        #expect(nullVal.isNull == true)
        #expect(dictVal.dictionaryValue?["appName"]?.stringValue == "Notes")
        #expect(arrVal.arrayValue?.count == 3)

        // Test JSON round-trip
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let encodedDict = try encoder.encode(dictVal)
        let decodedDict = try decoder.decode(AnyCodable.self, from: encodedDict)
        #expect(decodedDict == dictVal)

        let encodedArr = try encoder.encode(arrVal)
        let decodedArr = try decoder.decode(AnyCodable.self, from: encodedArr)
        #expect(decodedArr == arrVal)

        let encodedNull = try encoder.encode(nullVal)
        let decodedNull = try decoder.decode(AnyCodable.self, from: encodedNull)
        #expect(decodedNull == .null)
    }

    @Test("AnyCodable direct initializers and float literals")
    func testAnyCodableDirectInits() {
        let str = AnyCodable("test")
        let integer = AnyCodable(100)
        let dbl = AnyCodable(99.9)
        let boolean = AnyCodable(false)
        let dict = AnyCodable(["key": AnyCodable("val")])
        let arr = AnyCodable([AnyCodable(1)])
        let floatLit: AnyCodable = 12.34

        #expect(str.stringValue == "test")
        #expect(integer.intValue == 100)
        #expect(dbl.doubleValue == 99.9)
        #expect(boolean.boolValue == false)
        #expect(dict.dictionaryValue?["key"]?.stringValue == "val")
        #expect(arr.arrayValue?.count == 1)
        #expect(floatLit.doubleValue == 12.34)
    }

    @Test("GeminiRequest encodes tools with functionDeclarations correctly")
    func testToolsEncoding() throws {
        let openAppDecl = FunctionDeclaration(
            name: "open_app",
            description: "Opens a native macOS application by name.",
            parameters: ToolParameters(
                type: "OBJECT",
                properties: [
                    "name": ToolProperty(type: "STRING", description: "The name of the application")
                ],
                required: ["name"]
            )
        )

        let request = GeminiRequest(
            contents: [Content(role: "user", text: "Open Safari")],
            tools: [ToolDeclarationWrapper(functionDeclarations: [openAppDecl])]
        )

        let data = try JSONEncoder().encode(request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tools = json["tools"] as? [[String: Any]],
              let declarations = tools.first?["functionDeclarations"] as? [[String: Any]],
              let firstDecl = declarations.first else {
            Issue.record("Failed to serialize tools in GeminiRequest")
            return
        }

        #expect(firstDecl["name"] as? String == "open_app")
        #expect(firstDecl["description"] as? String == "Opens a native macOS application by name.")
        guard let params = firstDecl["parameters"] as? [String: Any],
              let props = params["properties"] as? [String: Any],
              let nameProp = props["name"] as? [String: Any] else {
            Issue.record("Missing parameters or properties")
            return
        }

        #expect(nameProp["type"] as? String == "STRING")
        #expect((params["required"] as? [String]) == ["name"])
    }

    @Test("GeminiResponse decodes candidate with functionCall")
    func testDecodeFunctionCall() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "functionCall": {
                      "name": "open_app",
                      "args": {
                        "name": "Safari"
                      },
                      "id": "call-123"
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

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)

        #expect(response.firstText == nil)
        guard let call = response.firstFunctionCall else {
            Issue.record("Expected firstFunctionCall to be present")
            return
        }

        #expect(call.name == "open_app")
        #expect(call.args["name"]?.stringValue == "Safari")
        #expect(call.id == "call-123")
        #expect(response.functionCalls.count == 1)
    }

    @Test("Part with functionResponse encodes and decodes properly")
    func testFunctionResponsePart() throws {
        let response = FunctionResponse(
            name: "open_app",
            response: ["result": "Opened Safari successfully."],
            id: "call-123"
        )
        let part = Part(functionResponse: response)

        let encoder = JSONEncoder()
        let data = try encoder.encode(part)

        let decoder = JSONDecoder()
        let decodedPart = try decoder.decode(Part.self, from: data)

        #expect(decodedPart.functionResponse?.name == "open_app")
        #expect(decodedPart.functionResponse?.response["result"]?.stringValue == "Opened Safari successfully.")
        #expect(decodedPart.functionResponse?.id == "call-123")
    }

    @Test("GeminiResponse decodes multiple function calls across candidate parts")
    func testDecodeMultipleFunctionCalls() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "functionCall": {
                      "name": "open_app",
                      "args": { "name": "Safari" },
                      "id": "call-1"
                    }
                  },
                  {
                    "functionCall": {
                      "name": "open_app",
                      "args": { "name": "Notes" },
                      "id": "call-2"
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

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)

        #expect(response.functionCalls.count == 2)
        #expect(response.functionCalls[0].name == "open_app")
        #expect(response.functionCalls[0].args["name"]?.stringValue == "Safari")
        #expect(response.functionCalls[0].id == "call-1")

        #expect(response.functionCalls[1].name == "open_app")
        #expect(response.functionCalls[1].args["name"]?.stringValue == "Notes")
        #expect(response.functionCalls[1].id == "call-2")
    }

    @Test("GeminiResponse decodes functionCall with complex nested and varied argument types")
    func testDecodeFunctionCallComplexArguments() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "functionCall": {
                      "name": "complex_tool",
                      "args": {
                        "name": "MyApp",
                        "retries": 3,
                        "ratio": 0.75,
                        "force": true,
                        "metadata": {
                          "env": "production"
                        },
                        "tags": ["alpha", "beta"]
                      }
                    }
                  }
                ],
                "role": "model"
              }
            }
          ]
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)

        guard let call = response.firstFunctionCall else {
            Issue.record("Expected functionCall")
            return
        }

        #expect(call.name == "complex_tool")
        #expect(call.args["name"]?.stringValue == "MyApp")
        #expect(call.args["retries"]?.intValue == 3)
        #expect(call.args["ratio"]?.doubleValue == 0.75)
        #expect(call.args["force"]?.boolValue == true)
        #expect(call.args["metadata"]?.dictionaryValue?["env"]?.stringValue == "production")
        #expect(call.args["tags"]?.arrayValue?.count == 2)
    }

    @Test("GeminiResponse decodes functionCall with empty arguments object")
    func testDecodeFunctionCallEmptyArguments() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "functionCall": {
                      "name": "no_args_tool",
                      "args": {}
                    }
                  }
                ],
                "role": "model"
              }
            }
          ]
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)

        #expect(response.firstFunctionCall?.name == "no_args_tool")
        #expect(response.firstFunctionCall?.args.isEmpty == true)
    }

    @Test("FunctionResponse serializes exact REST structure with response dictionary")
    func testFunctionResponseSerializationStructure() throws {
        let response = FunctionResponse(
            name: "open_app",
            response: [
                "result": "Opened Safari successfully.",
                "success": true,
                "code": 0
            ],
            id: "call-999"
        )

        let data = try JSONEncoder().encode(response)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let respDict = json["response"] as? [String: Any] else {
            Issue.record("Invalid FunctionResponse JSON")
            return
        }

        #expect(json["name"] as? String == "open_app")
        #expect(json["id"] as? String == "call-999")
        #expect(respDict["result"] as? String == "Opened Safari successfully.")
        #expect(respDict["success"] as? Bool == true)
        #expect(respDict["code"] as? Int == 0)
    }

    // MARK: - Thought Signature Tests

    @Test("GeminiResponse decodes candidate with functionCall and thought_signature")
    func testDecodeFunctionCallWithThoughtSignature() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "functionCall": {
                      "name": "open_app",
                      "args": { "name": "Safari" },
                      "id": "call-1"
                    },
                    "thought_signature": "opaque-cryptographic-token-xyz"
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

        #expect(response.functionCallParts.count == 1)
        let part = response.functionCallParts[0]
        #expect(part.thoughtSignature == "opaque-cryptographic-token-xyz")
        #expect(part.functionCall?.name == "open_app")
        #expect(part.functionCall?.thoughtSignature == "opaque-cryptographic-token-xyz")
        #expect(response.firstFunctionCall?.thoughtSignature == "opaque-cryptographic-token-xyz")
        #expect(response.functionCalls.first?.thoughtSignature == "opaque-cryptographic-token-xyz")
    }

    @Test("Part decodes thoughtSignature from camelCase key")
    func testDecodePartThoughtSignatureCamelCase() throws {
        let json = """
        {
          "functionCall": {
            "name": "open_app",
            "args": { "name": "Safari" }
          },
          "thoughtSignature": "camelCase-signature-token"
        }
        """

        let data = json.data(using: .utf8)!
        let part = try JSONDecoder().decode(Part.self, from: data)

        #expect(part.thoughtSignature == "camelCase-signature-token")
        #expect(part.functionCall?.thoughtSignature == "camelCase-signature-token")
    }

    @Test("Part with thoughtSignature round-trips to snake_case thought_signature")
    func testPartRoundTripPreservesThoughtSignature() throws {
        let call = FunctionCall(name: "open_app", args: ["name": "Notes"])
        let part = Part(functionCall: call, thoughtSignature: "test-sig-12345")

        let encodedData = try JSONEncoder().encode(part)
        guard let jsonObject = try JSONSerialization.jsonObject(with: encodedData) as? [String: Any] else {
            Issue.record("Failed to parse encoded Part JSON")
            return
        }

        #expect(jsonObject["thought_signature"] as? String == "test-sig-12345")
        #expect(jsonObject["thoughtSignature"] == nil)

        let decodedPart = try JSONDecoder().decode(Part.self, from: encodedData)
        #expect(decodedPart.thoughtSignature == "test-sig-12345")
        #expect(decodedPart.functionCall?.thoughtSignature == "test-sig-12345")
    }

    @Test("Missing thought_signature handles safely without crashing or fabricating signature")
    func testMissingThoughtSignatureHandlingInPart() throws {
        let json = """
        {
          "functionCall": {
            "name": "open_app",
            "args": { "name": "Safari" }
          }
        }
        """

        let data = json.data(using: .utf8)!
        let part = try JSONDecoder().decode(Part.self, from: data)

        #expect(part.thoughtSignature == nil)
        #expect(part.functionCall?.thoughtSignature == nil)

        let encoded = try JSONEncoder().encode(part)
        let jsonObject = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(jsonObject?["thought_signature"] == nil)
    }

    @Test("GeminiResponse decodes multiple function calls each preserving distinct thought signatures")
    func testMultipleFunctionCallsEachWithThoughtSignatures() throws {
        let json = """
        {
          "candidates": [
            {
              "content": {
                "parts": [
                  {
                    "functionCall": { "name": "run_applescript", "args": { "script": "beep" } },
                    "thought_signature": "sig-applescript-001"
                  },
                  {
                    "functionCall": { "name": "open_app", "args": { "name": "Safari" } },
                    "thought_signature": "sig-openapp-002"
                  }
                ],
                "role": "model"
              }
            }
          ]
        }
        """

        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(GeminiResponse.self, from: data)

        #expect(response.functionCallParts.count == 2)
        #expect(response.functionCallParts[0].thoughtSignature == "sig-applescript-001")
        #expect(response.functionCallParts[0].functionCall?.name == "run_applescript")
        #expect(response.functionCallParts[1].thoughtSignature == "sig-openapp-002")
        #expect(response.functionCallParts[1].functionCall?.name == "open_app")

        #expect(response.functionCalls.count == 2)
        #expect(response.functionCalls[0].thoughtSignature == "sig-applescript-001")
        #expect(response.functionCalls[1].thoughtSignature == "sig-openapp-002")
    }

    @Test("FunctionCall encoding NEVER emits thought_signature inside functionCall object")
    func testFunctionCallEncodingNeverEmitsThoughtSignature() throws {
        let call = FunctionCall(name: "open_app", args: ["name": "Safari"], id: "call-1", thoughtSignature: "opaque-sig-never-inside")

        // 1. Direct FunctionCall encoding
        let callData = try JSONEncoder().encode(call)
        let callJSON = try JSONSerialization.jsonObject(with: callData) as? [String: Any]
        #expect(callJSON?["name"] as? String == "open_app")
        #expect(callJSON?["thought_signature"] == nil)
        #expect(callJSON?["thoughtSignature"] == nil)

        // 2. Part encoding containing the FunctionCall
        let part = Part(functionCall: call, thoughtSignature: "opaque-sig-never-inside")
        let partData = try JSONEncoder().encode(part)
        let partJSON = try JSONSerialization.jsonObject(with: partData) as? [String: Any]

        #expect(partJSON?["thought_signature"] as? String == "opaque-sig-never-inside")
        guard let nestedCall = partJSON?["functionCall"] as? [String: Any] else {
            Issue.record("Missing functionCall in part JSON")
            return
        }
        #expect(nestedCall["name"] as? String == "open_app")
        #expect(nestedCall["thought_signature"] == nil)
        #expect(nestedCall["thoughtSignature"] == nil)
    }
}

