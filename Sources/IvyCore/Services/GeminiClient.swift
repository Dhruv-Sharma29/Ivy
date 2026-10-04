import Foundation

public enum GeminiClientError: Error, LocalizedError, Equatable, Sendable {
    case missingAPIKey
    case invalidURL
    case invalidAPIKey(String)
    case invalidRequest(String)
    case rateLimited
    /// Rate limited, and the server said how long to wait.
    case rateLimitedRetry(after: TimeInterval)
    case dailyQuotaExhausted
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
        case .invalidRequest(let msg):
            return "Gemini couldn't accept this request: \(msg)"
        case .rateLimited:
            return "Rate limited. Slow down, give me a second."
        case .rateLimitedRetry(let seconds):
            return "Rate limited. Try again in \(Int(seconds.rounded(.up))) s."
        case .dailyQuotaExhausted:
            return "Gemini's daily request quota for this API key is used up. It resets at midnight Pacific time, or switch to a key with billing enabled."
        case .modelNotFound(let msg):
            return "Gemini model not found (404): \(msg)"
        case .serverError(let code, let msg):
            if code == 503 {
                return "Gemini is temporarily overloaded. Please try again in a moment."
            }
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
    public let retryPolicy: RetryPolicy
    /// Longest server-requested rate-limit delay the client waits out itself before surfacing it.
    static let maxInlineRateLimitWait: TimeInterval = 10

    public init(
        session: URLSession = .shared,
        baseURLString: String = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent",
        thinkingLevel: ThinkingLevel? = .medium,
        retryPolicy: RetryPolicy = .default
    ) {
        self.session = session
        self.baseURLString = baseURLString
        self.thinkingLevel = thinkingLevel
        self.retryPolicy = retryPolicy
    }

    public convenience init(
        session: URLSession = .shared,
        baseURLString: String = "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.8-flash:generateContent",
        thinkingLevel: ThinkingLevel? = .medium
    ) {
        self.init(
            session: session,
            baseURLString: baseURLString,
            thinkingLevel: thinkingLevel,
            retryPolicy: .default
        )
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

        // The key travels only in the `x-goog-api-key` header: a URL ends up in logs, proxies and error text.
        guard let url = URLComponents(string: baseURLString)?.url else {
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
            if !msg.attachments.isEmpty {
                // Images inline (JPEG, no metadata) plus their on-device text, which helps accuracy.
                var parts: [Part] = []
                if !msg.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(Part(text: msg.text)) }
                for attachment in msg.attachments {
                    parts.append(Part(text: attachment.modelContext))
                    for jpeg in attachment.jpeg { parts.append(Part(inlineData: InlineData(mimeType: "image/jpeg", data: jpeg))) }
                    if let text = attachment.text, !text.isEmpty {
                        parts.append(Part(text: "Text recognised in the \(attachment.label):\n\(text)"))
                    } else if attachment.jpeg.isEmpty {
                        parts.append(Part(text: "[\(attachment.label): nothing readable]"))
                    }
                }
                return Content(role: "user", parts: parts)
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

        let sanitizeText: @Sendable (String) -> String = { raw in
            guard !trimmedKey.isEmpty else { return raw }
            return raw.replacingOccurrences(of: trimmedKey, with: "[REDACTED_API_KEY]")
        }

        var attempt = 0
        while true {
            // Opt-in wire dump for debug builds only, to stderr only: payloads hold conversation text and tool
            // results, so they are never written to disk.
            #if DEBUG
            if ProcessInfo.processInfo.environment["IVY_DEBUG_WIRE"] != nil,
               let reqStr = String(data: requestData, encoding: .utf8) {
                let sanitizedReq = sanitizeText(reqStr)
                let logLine = "\n=== [GEMINI REQUEST (attempt \(attempt + 1))] ===\n\(sanitizedReq)\n========================\n"
                fputs(logLine, stderr)
            }
            #endif

            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                if RetryPolicy.isTransientNetworkError(error) && attempt < retryPolicy.maxRetries {
                    let delay = retryPolicy.delay(forAttempt: attempt)
                    attempt += 1
                    try await retryPolicy.sleeper(delay)
                    continue
                }
                throw GeminiClientError.networkError(sanitizeText(error.localizedDescription))
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw GeminiClientError.networkError("Invalid response type")
            }

            #if DEBUG
            if ProcessInfo.processInfo.environment["IVY_DEBUG_WIRE"] != nil,
               let respStr = String(data: data, encoding: .utf8) {
                let sanitizedResp = sanitizeText(respStr)
                let logLine = "\n=== [GEMINI RESPONSE (\(httpResponse.statusCode)) (attempt \(attempt + 1))] ===\n\(sanitizedResp)\n=====================================\n"
                fputs(logLine, stderr)
            }
            #endif

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

            case 400:
                let apiError = try? JSONDecoder().decode(GeminiResponse.self, from: data).error
                let body = String(data: data, encoding: .utf8) ?? ""
                let message = sanitizeText(apiError?.message ?? (body.isEmpty ? "Bad request (HTTP 400)" : body))
                let invalidKey = apiError?.details?.contains { $0.reason == "API_KEY_INVALID" } == true
                    || message.lowercased().hasPrefix("api key not valid")
                if invalidKey { throw GeminiClientError.invalidAPIKey(message) }
                throw GeminiClientError.invalidRequest(message)

            case 401, 403:
                if let apiError = try? JSONDecoder().decode(GeminiResponse.self, from: data).error {
                    throw GeminiClientError.invalidAPIKey(sanitizeText(apiError.message))
                } else if let bodyString = String(data: data, encoding: .utf8), !bodyString.isEmpty {
                    throw GeminiClientError.invalidAPIKey(sanitizeText(bodyString))
                } else {
                    throw GeminiClientError.invalidAPIKey("Authentication failure (HTTP \(httpResponse.statusCode))")
                }

            case 404:
                let errorMsg: String
                if let apiError = try? JSONDecoder().decode(GeminiResponse.self, from: data).error {
                    errorMsg = sanitizeText(apiError.message)
                } else if let bodyString = String(data: data, encoding: .utf8), !bodyString.isEmpty {
                    errorMsg = sanitizeText(bodyString)
                } else {
                    errorMsg = "Model not found"
                }
                throw GeminiClientError.modelNotFound(errorMsg)

            default:
                // A per-day quota won't recover within any retry window; fail fast with the real reason.
                if httpResponse.statusCode == 429 {
                    let quota = QuotaStatus.parse(responseBody: data)
                    if quota.isDaily {
                        throw GeminiClientError.dailyQuotaExhausted
                    }
                    if let serverDelay = quota.retryDelay {
                        // Honour the server's own delay when it's short; a long one goes back to the UI as a countdown.
                        guard serverDelay <= Self.maxInlineRateLimitWait, attempt < retryPolicy.maxRetries else {
                            throw GeminiClientError.rateLimitedRetry(after: serverDelay)
                        }
                        attempt += 1
                        try await retryPolicy.sleeper(serverDelay)
                        continue
                    }
                }
                if RetryPolicy.isTransientStatusCode(httpResponse.statusCode) && attempt < retryPolicy.maxRetries {
                    let delay = retryPolicy.delay(forAttempt: attempt)
                    attempt += 1
                    try await retryPolicy.sleeper(delay)
                    continue
                }

                if httpResponse.statusCode == 429 {
                    throw GeminiClientError.rateLimited
                }

                let errorMsg: String
                if let apiError = try? JSONDecoder().decode(GeminiResponse.self, from: data).error {
                    errorMsg = sanitizeText(apiError.message)
                } else if let bodyString = String(data: data, encoding: .utf8), !bodyString.isEmpty {
                    errorMsg = sanitizeText(bodyString)
                } else {
                    errorMsg = "HTTP \(httpResponse.statusCode)"
                }
                throw GeminiClientError.serverError(statusCode: httpResponse.statusCode, message: errorMsg)
            }
        }
    }
}
