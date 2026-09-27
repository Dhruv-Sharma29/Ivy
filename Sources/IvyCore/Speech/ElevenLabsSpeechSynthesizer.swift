import Foundation

/// Production implementation of `SpeechSynthesizer` communicating directly with the ElevenLabs REST API.
public final class ElevenLabsSpeechSynthesizer: SpeechSynthesizer, Sendable {
    public let configuration: ElevenLabsConfiguration
    public let keyProvider: ElevenLabsKeyProvider
    private let session: URLSession

    public init(
        configuration: ElevenLabsConfiguration = ElevenLabsConfiguration(),
        keyProvider: ElevenLabsKeyProvider = ConfigurableElevenLabsKeyProvider(),
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.keyProvider = keyProvider
        self.session = session
    }

    /// Synthesizes input text into audio binary data using the ElevenLabs Text-to-Speech REST endpoint.
    public func synthesize(text: String) async throws -> Data {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else {
            throw SpeechError.emptyText
        }

        guard let apiKey = keyProvider.getAPIKey(), !apiKey.isEmpty else {
            throw SpeechError.missingAPIKey
        }

        let trimmedBase = configuration.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedVoice = configuration.voiceID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBase.isEmpty, !trimmedVoice.isEmpty else {
            throw SpeechError.decodingError("Invalid ElevenLabs configuration: baseURL or voiceID cannot be empty.")
        }

        guard var urlComponents = URLComponents(string: "\(trimmedBase)/\(trimmedVoice)"),
              urlComponents.scheme == "https" || urlComponents.scheme == "http" else {
            throw SpeechError.networkError("Invalid endpoint URL for ElevenLabs voice.")
        }

        if !configuration.outputFormat.isEmpty {
            urlComponents.queryItems = [
                URLQueryItem(name: "output_format", value: configuration.outputFormat)
            ]
        }

        guard let url = urlComponents.url else {
            throw SpeechError.networkError("Failed to build ElevenLabs URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 30.0

        let payload: [String: String] = [
            "text": trimmedText,
            "model_id": configuration.modelID
        ]

        let requestBody: Data
        do {
            requestBody = try JSONEncoder().encode(payload)
        } catch {
            throw SpeechError.decodingError("Failed to encode synthesis payload: \(error.localizedDescription)")
        }
        request.httpBody = requestBody

        let sanitizeText: @Sendable (String) -> String = { raw in
            guard !apiKey.isEmpty else { return raw }
            return raw.replacingOccurrences(of: apiKey, with: "[REDACTED_API_KEY]")
        }

        if Task.isCancelled {
            throw SpeechError.cancelled
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw SpeechError.cancelled
        } catch let urlErr as URLError where urlErr.code == .cancelled {
            throw SpeechError.cancelled
        } catch {
            if Task.isCancelled {
                throw SpeechError.cancelled
            }
            throw SpeechError.networkError(sanitizeText(error.localizedDescription))
        }

        if Task.isCancelled {
            throw SpeechError.cancelled
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpeechError.networkError("Invalid response type received from speech service.")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            guard !data.isEmpty else {
                throw SpeechError.emptyAudioData
            }
            return data

        case 400:
            let detail = parseErrorDetail(from: data, sanitize: sanitizeText)
            throw SpeechError.decodingError(detail.isEmpty ? "Invalid request payload (HTTP 400)" : detail)

        case 401, 403:
            let detail = parseErrorDetail(from: data, sanitize: sanitizeText)
            throw SpeechError.invalidAPIKey(detail.isEmpty ? "Unauthorized (HTTP \(httpResponse.statusCode))" : detail)

        case 402:
            let detail = parseErrorDetail(from: data, sanitize: sanitizeText)
            throw SpeechError.serverError(
                statusCode: 402,
                message: detail.isEmpty ? "Payment or subscription required (HTTP 402)" : detail
            )

        case 404:
            throw SpeechError.voiceNotFound(configuration.voiceID)

        case 429:
            throw SpeechError.rateLimited

        default:
            let detail = parseErrorDetail(from: data, sanitize: sanitizeText)
            throw SpeechError.serverError(
                statusCode: httpResponse.statusCode,
                message: detail.isEmpty ? "HTTP \(httpResponse.statusCode)" : detail
            )
        }
    }

    private func parseErrorDetail(from data: Data, sanitize: (String) -> String) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detailDict = json["detail"] as? [String: Any],
               let message = detailDict["message"] as? String {
                return sanitize(message)
            } else if let detailStr = json["detail"] as? String {
                return sanitize(detailStr)
            } else if let msg = json["message"] as? String {
                return sanitize(msg)
            }
        }
        if let rawString = String(data: data, encoding: .utf8), !rawString.isEmpty {
            return sanitize(rawString)
        }
        return ""
    }
}
