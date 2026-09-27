import Foundation

public enum GeminiClientError: Error, LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidURL
    case invalidAPIKey(String)
    case rateLimited
    case modelNotFound(String)
    case serverError(statusCode: Int, message: String)
    case networkError(String)
    case decodingError(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "No Gemini API key provided. I can't think without fuel."
        case .invalidURL:
            return "Invalid Gemini API endpoint URL."
        case .invalidAPIKey(let msg):
            return "Invalid API key: \(msg)"
        case .rateLimited:
            return "Rate limited. Slow down, give me a second."
        case .modelNotFound(let msg):
            return "Gemini model not found (404): \(msg)"
        case .serverError(let code, let msg):
            return "Gemini server error (\(code)): \(msg)"
        case .networkError(let msg):
            return "Network connection failed: \(msg)"
        case .decodingError(let msg):
            return "Failed to parse model response: \(msg)"
        case .emptyResponse:
            return "Gemini responded with absolute silence."
        }
    }
}

public struct ModelTurnResponse: Sendable, Equatable {
    public let text: String?
    public let functionCalls: [FunctionCall]
    public let functionCallParts: [Part]
    public let thoughtSignature: String?

    public init(
        text: String? = nil,
        functionCalls: [FunctionCall] = [],
        functionCallParts: [Part] = [],
        thoughtSignature: String? = nil
    ) {
        self.text = text
        self.functionCalls = functionCalls
        let resolvedSig = thoughtSignature
            ?? functionCallParts.compactMap(\.thoughtSignature).first
            ?? functionCalls.compactMap(\.thoughtSignature).first
        self.thoughtSignature = resolvedSig
        if functionCallParts.isEmpty && !functionCalls.isEmpty {
            self.functionCallParts = functionCalls.map {
                Part(functionCall: $0, thoughtSignature: $0.thoughtSignature ?? resolvedSig)
            }
        } else {
            self.functionCallParts = functionCallParts
        }
    }
}

public protocol GeminiClientProtocol: Sendable {
    func generateContent(
        history: [ChatMessage],
        systemPrompt: String,
        apiKey: String
    ) async throws -> String

    func generateContent(
        history: [ChatMessage],
        systemPrompt: String,
        tools: [ToolDeclarationWrapper]?,
        apiKey: String
    ) async throws -> ModelTurnResponse
}

public extension GeminiClientProtocol {
    func generateContent(
        history: [ChatMessage],
        systemPrompt: String,
        tools: [ToolDeclarationWrapper]?,
        apiKey: String
    ) async throws -> ModelTurnResponse {
        let text = try await generateContent(history: history, systemPrompt: systemPrompt, apiKey: apiKey)
        return ModelTurnResponse(text: text)
    }

    func generateContent(
        history: [ChatMessage],
        systemPrompt: String,
        apiKey: String
    ) async throws -> String {
        let response = try await generateContent(history: history, systemPrompt: systemPrompt, tools: nil, apiKey: apiKey)
        guard let text = response.text, !text.isEmpty else {
            throw GeminiClientError.emptyResponse
        }
        return text
    }
}

public final class URLSessionGeminiClient: GeminiClientProtocol, Sendable {
    private let session: URLSession
    public let baseURLString: String
    public let thinkingLevel: ThinkingLevel?

    public init(
        session: URLSession = .shared,
        baseURLString: String = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent",
        thinkingLevel: ThinkingLevel? = .medium
    ) {
        self.session = session
        self.baseURLString = baseURLString
        self.thinkingLevel = thinkingLevel
    }

    public func generateContent(
        history: [ChatMessage],
        systemPrompt: String,
        apiKey: String
    ) async throws -> String {
        let response = try await generateContent(history: history, systemPrompt: systemPrompt, tools: nil, apiKey: apiKey)
        guard let text = response.text, !text.isEmpty else {
            throw GeminiClientError.emptyResponse
        }
        return text
    }

    public func generateContent(
        history: [ChatMessage],
        systemPrompt: String,
        tools: [ToolDeclarationWrapper]?,
        apiKey: String
    ) async throws -> ModelTurnResponse {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw GeminiClientError.missingAPIKey
        }

        var urlComponents = URLComponents(string: baseURLString)
        if urlComponents?.queryItems?.contains(where: { $0.name == "key" }) != true {
            var items = urlComponents?.queryItems ?? []
            items.append(URLQueryItem(name: "key", value: trimmedKey))
            urlComponents?.queryItems = items
        }

        guard let url = urlComponents?.url else {
            throw GeminiClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")
        request.timeoutInterval = 30.0

        // Build contents array from history (handling text, functionCall, and functionResponse)
        let contents: [Content] = history.compactMap { msg in
            if msg.role == .model {
                if let functionCallPart = msg.functionCallPart {
                    return Content(role: "model", parts: [functionCallPart])
                }
                if let functionCall = msg.functionCall {
                    return Content(
                        role: "model",
                        parts: [Part(functionCall: functionCall, thoughtSignature: msg.thoughtSignature ?? functionCall.thoughtSignature)]
                    )
                }
                return Content(
                    role: "model",
                    parts: [Part(text: msg.text, thoughtSignature: msg.thoughtSignature)]
                )
            }
            if let functionResponse = msg.functionResponse {
                return Content(role: "user", parts: [Part(functionResponse: functionResponse)])
            }
            guard !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let roleString = (msg.role == .user) ? "user" : "model"
            return Content(role: roleString, text: msg.text)
        }

        guard !contents.isEmpty else {
            throw GeminiClientError.emptyResponse
        }

        let systemInstruction = systemPrompt.isEmpty ? nil : SystemInstruction(text: systemPrompt)
        let generationConfig: GenerationConfig? = thinkingLevel.map {
            GenerationConfig(thinkingConfig: ThinkingConfig(thinkingLevel: $0))
        }

        let geminiRequest = GeminiRequest(
            systemInstruction: systemInstruction,
            contents: contents,
            generationConfig: generationConfig,
            tools: tools
        )

        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(geminiRequest)
        } catch {
            throw GeminiClientError.decodingError(error.localizedDescription)
        }
        request.httpBody = requestData

        if ProcessInfo.processInfo.environment["IVY_DEBUG_WIRE"] != nil,
           let reqStr = String(data: requestData, encoding: .utf8) {
            let sanitizedReq = trimmedKey.isEmpty ? reqStr : reqStr.replacingOccurrences(of: trimmedKey, with: "[REDACTED_API_KEY]")
            let logLine = "\n=== [GEMINI REQUEST] ===\n\(sanitizedReq)\n========================\n"
            fputs(logLine, stderr)
            let logURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("gemini_wire.log")
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                if let logData = logLine.data(using: .utf8) { handle.write(logData) }
                try? handle.close()
            } else {
                try? logLine.write(to: logURL, atomically: true, encoding: .utf8)
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GeminiClientError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiClientError.networkError("Invalid response type")
        }

        if ProcessInfo.processInfo.environment["IVY_DEBUG_WIRE"] != nil,
           let respStr = String(data: data, encoding: .utf8) {
            let sanitizedResp = trimmedKey.isEmpty ? respStr : respStr.replacingOccurrences(of: trimmedKey, with: "[REDACTED_API_KEY]")
            let logLine = "\n=== [GEMINI RESPONSE (\(httpResponse.statusCode))] ===\n\(sanitizedResp)\n=====================================\n"
            fputs(logLine, stderr)
            let logURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("gemini_wire.log")
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                if let logData = logLine.data(using: .utf8) { handle.write(logData) }
                try? handle.close()
            } else {
                try? logLine.write(to: logURL, atomically: true, encoding: .utf8)
            }
        }

        switch httpResponse.statusCode {
        case 200..<300:
            let geminiResponse: GeminiResponse
            do {
                geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
            } catch {
                throw GeminiClientError.decodingError(error.localizedDescription)
            }

            let functionCalls = geminiResponse.functionCalls
            let functionCallParts = geminiResponse.functionCallParts
            let text = geminiResponse.firstText

            if functionCalls.isEmpty && (text?.isEmpty ?? true) {
                throw GeminiClientError.emptyResponse
            }

            let thoughtSig = geminiResponse.candidates?.first?.content?.parts.compactMap(\.thoughtSignature).first
                ?? functionCallParts.compactMap(\.thoughtSignature).first

            return ModelTurnResponse(
                text: text,
                functionCalls: functionCalls,
                functionCallParts: functionCallParts,
                thoughtSignature: thoughtSig
            )

        case 400, 401, 403:
            if let apiError = try? JSONDecoder().decode(GeminiResponse.self, from: data).error {
                throw GeminiClientError.invalidAPIKey(apiError.message)
            } else if let bodyString = String(data: data, encoding: .utf8), !bodyString.isEmpty {
                throw GeminiClientError.invalidAPIKey(bodyString)
            } else {
                throw GeminiClientError.invalidAPIKey("Authentication failure (HTTP \(httpResponse.statusCode))")
            }

        case 404:
            let errorMsg: String
            if let apiError = try? JSONDecoder().decode(GeminiResponse.self, from: data).error {
                errorMsg = apiError.message
            } else if let bodyString = String(data: data, encoding: .utf8), !bodyString.isEmpty {
                errorMsg = bodyString
            } else {
                errorMsg = "Model not found"
            }
            throw GeminiClientError.modelNotFound(errorMsg)

        case 429:
            throw GeminiClientError.rateLimited

        default:
            let errorMsg: String
            if let apiError = try? JSONDecoder().decode(GeminiResponse.self, from: data).error {
                errorMsg = apiError.message
            } else if let bodyString = String(data: data, encoding: .utf8), !bodyString.isEmpty {
                errorMsg = bodyString
            } else {
                errorMsg = "HTTP \(httpResponse.statusCode)"
            }
            throw GeminiClientError.serverError(statusCode: httpResponse.statusCode, message: errorMsg)
        }
    }
}
