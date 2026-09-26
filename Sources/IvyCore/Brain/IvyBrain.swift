import Foundation
import Combine

@MainActor
public final class IvyBrain: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isThinking: Bool = false
    @Published public private(set) var errorMessage: String? = nil
    @Published public var apiKey: String

    public let toolDispatcher: ToolDispatcher
    private let client: GeminiClientProtocol
    private let systemPrompt: String

    public init(
        client: GeminiClientProtocol = URLSessionGeminiClient(),
        toolDispatcher: ToolDispatcher = ToolDispatcher(registry: .defaultRegistry()),
        apiKey: String? = nil,
        systemPrompt: String = IvyPersona.systemPrompt,
        initialMessages: [ChatMessage] = []
    ) {
        self.client = client
        self.toolDispatcher = toolDispatcher
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
            var currentHistory = messages.filter { !$0.isError }
            var turnCount = 0
            let maxTurns = 5

            while turnCount < maxTurns {
                turnCount += 1
                let response = try await client.generateContent(
                    history: currentHistory,
                    systemPrompt: systemPrompt,
                    tools: toolDispatcher.registry.toolDeclarations,
                    apiKey: trimmedKey
                )

                if !response.functionCalls.isEmpty {
                    for call in response.functionCalls {
                        // Append the model's tool call turn
                        let callMsg = ChatMessage(role: .model, text: "", functionCall: call)
                        currentHistory.append(callMsg)

                        // Execute tool via dispatcher
                        let toolResponse = await toolDispatcher.dispatch(call)

                        // Append the function response turn
                        let respMsg = ChatMessage(
                            role: .function,
                            text: toolResponse.response["result"]?.stringValue ?? toolResponse.response["error"]?.stringValue ?? "",
                            functionResponse: toolResponse
                        )
                        currentHistory.append(respMsg)
                    }
                    // Loop continues with updated history containing function response
                } else if let reply = response.text, !reply.isEmpty {
                    messages.append(ChatMessage(role: .model, text: reply))
                    return
                } else {
                    throw GeminiClientError.emptyResponse
                }
            }

            let loopError = "Tool execution limit reached."
            errorMessage = loopError
            messages.append(ChatMessage(role: .model, text: loopError, isError: true))
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
