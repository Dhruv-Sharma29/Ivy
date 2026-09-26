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

public protocol GeminiClientProtocol: Sendable {
    func generateContent(
        history: [ChatMessage],
        systemPrompt: String,
        apiKey: String
    ) async throws -> String
}

public final class URLSessionGeminiClient: GeminiClientProtocol, @unchecked Sendable {
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
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw GeminiClientError.missingAPIKey
        }

        var urlComponents = URLComponents(string: baseURLString)
        urlComponents?.queryItems = [
            URLQueryItem(name: "key", value: trimmedKey)
        ]

        guard let url = urlComponents?.url else {
            throw GeminiClientError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30.0

        // Build contents array from history (filtering out empty messages)
        let contents: [Content] = history.compactMap { msg in
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
            generationConfig: generationConfig
        )

        let requestData: Data
        do {
            requestData = try JSONEncoder().encode(geminiRequest)
        } catch {
            throw GeminiClientError.decodingError(error.localizedDescription)
        }
        request.httpBody = requestData

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

        switch httpResponse.statusCode {
        case 200..<300:
            let geminiResponse: GeminiResponse
            do {
                geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
            } catch {
                throw GeminiClientError.decodingError(error.localizedDescription)
            }

            guard let text = geminiResponse.firstText, !text.isEmpty else {
                throw GeminiClientError.emptyResponse
            }
            return text

        case 400, 403:
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
