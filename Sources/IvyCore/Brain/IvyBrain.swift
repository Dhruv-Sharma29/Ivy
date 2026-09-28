import Foundation
import Combine

@MainActor
public final class IvyBrain: ObservableObject {
    @Published public private(set) var messages: [ChatMessage] = []
    @Published public private(set) var isThinking: Bool = false
    @Published public private(set) var errorMessage: String? = nil
    @Published public private(set) var pendingConfirmation: ConfirmationRequest? = nil
    /// Whether a Gemini key is configured. The key itself is never held in observable/UI state.
    @Published public private(set) var geminiCredentialSource: CredentialSource = .missing
    public var isGeminiKeyConfigured: Bool { geminiCredentialSource != .missing }

    public let credentials: CredentialProvider
    /// Current conversation boundary; a new id starts on clear.
    public private(set) var conversationID = UUID()
    private var conversationCreatedAt = Date()
    private let conversationStore: ConversationStore?
    /// Driven by settings; when false nothing is written to disk.
    public var persistsHistory: Bool = true

    public let toolDispatcher: ToolDispatcher
    private let client: GeminiClientProtocol
    private let systemPrompt: String
    private var confirmationContinuation: CheckedContinuation<Bool, Never>? = nil
    private let confirmationBridge: ConfirmationBridge?

    public init(
        client: GeminiClientProtocol = URLSessionGeminiClient(),
        toolDispatcher: ToolDispatcher? = nil,
        apiKey: String? = nil,
        credentials: CredentialProvider? = nil,
        conversationStore: ConversationStore? = nil,
        systemPrompt: String = IvyPersona.systemPrompt,
        initialMessages: [ChatMessage] = []
    ) {
        self.client = client
        self.systemPrompt = systemPrompt
        self.messages = initialMessages
        self.conversationStore = conversationStore
        // An explicit key wins (tests, injection); otherwise Keychain with environment fallback.
        self.credentials = apiKey.map { FixedCredentialProvider([.geminiAPIKey: $0]) } ?? credentials ?? KeychainCredentialProvider()
        self.geminiCredentialSource = self.credentials.source(for: .geminiAPIKey)

        if let toolDispatcher {
            self.toolDispatcher = toolDispatcher
            self.confirmationBridge = nil
        } else {
            let bridge = ConfirmationBridge()
            let safetyGate = InteractiveSafetyGate(confirmationProvider: bridge)
            self.toolDispatcher = ToolDispatcher(registry: .defaultRegistry(), safetyGate: safetyGate)
            self.confirmationBridge = bridge
            bridge.handler = self
        }
    }

    /// Re-reads where the Gemini key comes from (after the user saves or removes it).
    public func refreshCredentialStatus() {
        geminiCredentialSource = credentials.source(for: .geminiAPIKey)
    }

    public var statusIcon: String {
        if pendingConfirmation != nil {
            return "exclamationmark.shield"
        } else if isThinking {
            return "sparkle.magnifyingglass"
        } else if errorMessage != nil {
            return "exclamationmark.bubble"
        } else {
            return "sparkle"
        }
    }

    /// Responds to the currently pending confirmation request with the user's decision.
    /// If an optional request `id` is specified, it guarantees that only the matching pending confirmation is answered.
    public func respondToPendingConfirmation(id: UUID? = nil, approved: Bool) {
        guard let continuation = confirmationContinuation, let pending = pendingConfirmation else { return }
        if let id, pending.id != id {
            return
        }
        confirmationContinuation = nil
        pendingConfirmation = nil
        continuation.resume(returning: approved)
    }

    public func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isThinking, pendingConfirmation == nil else { return }

        errorMessage = nil
        let userMessage = ChatMessage(role: .user, text: trimmed)
        messages.append(userMessage)
        // Saved after every turn (success or failure) so an abrupt quit loses nothing.
        defer { persistConversation() }

        refreshCredentialStatus()
        guard let trimmedKey = credentials.credential(for: .geminiAPIKey) else {
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
                    for (index, call) in response.functionCalls.enumerated() {
                        let matchingPart = (index < response.functionCallParts.count)
                            ? response.functionCallParts[index]
                            : Part(functionCall: call, thoughtSignature: call.thoughtSignature)

                        // Append the model's tool call turn, preserving the exact Part and thought_signature
                        let callMsg = ChatMessage(
                            role: .model,
                            text: "",
                            functionCall: call,
                            functionCallPart: matchingPart,
                            thoughtSignature: matchingPart.thoughtSignature ?? call.thoughtSignature
                        )
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
                    messages.append(ChatMessage(role: .model, text: reply, thoughtSignature: response.thoughtSignature))
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
        cancelPendingConfirmation()
        if let conversationStore {
            do {
                try conversationStore.delete(conversationID)
            } catch {
                print("[HISTORY] failed to delete conversation: \(error.localizedDescription)")
            }
        }
        messages.removeAll()
        errorMessage = nil
        isThinking = false
        conversationID = UUID()
        conversationCreatedAt = Date()
    }

    /// Reopens the most recently updated saved conversation, if any. Never runs tools or contacts Gemini.
    @discardableResult
    public func restoreLatestConversation() -> Bool {
        guard let conversationStore, messages.isEmpty,
              let latest = conversationStore.list().first,
              let conversation = conversationStore.load(latest.id) else { return false }
        messages = conversation.chatMessages
        conversationID = conversation.id
        conversationCreatedAt = conversation.createdAt
        return true
    }

    /// Quit path: a pending approval is denied (never executed) and the conversation is saved.
    public func prepareForTermination() {
        cancelPendingConfirmation()
        persistConversation()
    }

    public func persistConversation() {
        guard persistsHistory, let conversationStore else { return }
        let conversation = Conversation(id: conversationID, createdAt: conversationCreatedAt, chatMessages: messages)
        guard !conversation.messages.isEmpty else { return }
        do {
            try conversationStore.save(conversation)
        } catch {
            print("[HISTORY] failed to save conversation: \(error.localizedDescription)")
        }
    }

    private func cancelPendingConfirmation() {
        guard let continuation = confirmationContinuation else { return }
        confirmationContinuation = nil
        pendingConfirmation = nil
        continuation.resume(returning: false)
    }
}

// MARK: - ConfirmationHandler Conformance

extension IvyBrain: ConfirmationHandler {
    public func handleConfirmation(_ request: ConfirmationRequest) async -> Bool {
        if let existing = self.confirmationContinuation {
            self.confirmationContinuation = nil
            existing.resume(returning: false)
        }
        self.pendingConfirmation = request
        return await withCheckedContinuation { continuation in
            self.confirmationContinuation = continuation
        }
    }
}
