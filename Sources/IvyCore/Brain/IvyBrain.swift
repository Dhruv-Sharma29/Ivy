import Foundation
import Combine

@MainActor
public final class IvyBrain: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isThinking: Bool = false
    @Published public private(set) var errorMessage: String? = nil
    @Published public var apiKey: String

    private let client: GeminiClientProtocol
    private let systemPrompt: String

    public init(
        client: GeminiClientProtocol = URLSessionGeminiClient(),
        apiKey: String? = nil,
        systemPrompt: String = IvyPersona.systemPrompt,
        initialMessages: [ChatMessage] = []
    ) {
        self.client = client
        self.systemPrompt = systemPrompt
        self.messages = initialMessages
        self.apiKey = apiKey ?? ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? ""
    }

    public var statusIcon: String {
        if isThinking {
            return "sparkle.magnifyingglass"
        } else if errorMessage != nil {
            return "exclamationmark.bubble"
        } else {
            return "sparkle"
        }
    }

    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isThinking else { return }

        errorMessage = nil
        let userMessage = ChatMessage(role: .user, text: trimmed)
        messages.append(userMessage)

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            let errorText = "I need a Gemini API key to work. Enter it in settings above so I can stop staring at you blankly."
            messages.append(ChatMessage(role: .model, text: errorText, isError: true))
            errorMessage = "API key missing"
            return
        }

        isThinking = true
        defer {
            isThinking = false
        }

        do {
            let reply = try await client.generateContent(
                history: messages.filter { !$0.isError },
                systemPrompt: systemPrompt,
                apiKey: trimmedKey
            )
            messages.append(ChatMessage(role: .model, text: reply))
        } catch let err as GeminiClientError {
            let errorText = "Failed: \(err.localizedDescription)"
            errorMessage = err.localizedDescription
            messages.append(ChatMessage(role: .model, text: errorText, isError: true))
        } catch {
            let errorText = "Something broke: \(error.localizedDescription)"
            errorMessage = error.localizedDescription
            messages.append(ChatMessage(role: .model, text: errorText, isError: true))
        }
    }

    public func clearHistory() {
        messages.removeAll()
        errorMessage = nil
        isThinking = false
    }
}
