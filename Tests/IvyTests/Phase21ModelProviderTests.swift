import Foundation
import Testing
@testable import IvyCore

actor Phase21Provider: ModelProvider {
    nonisolated let descriptor: ModelProviderDescriptor
    private var replies: [ModelTurnResponse]
    private(set) var requests: [ModelRequest] = []
    private(set) var emittedCalls: [FunctionCall] = []

    init(_ replies: [ModelTurnResponse], tools: Bool = true, images: Bool = true) {
        self.replies = replies
        descriptor = ModelProviderDescriptor(providerID: "offline-fixture", modelID: "scripted-v1",
                                             supportsTools: tools, supportsImages: images)
    }

    func generate(_ request: ModelRequest) throws -> ModelTurnResponse {
        requests.append(request)
        if request.purpose == .conversationTitle { return ModelTurnResponse(text: "Fixture conversation") }
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let reply = replies.removeFirst()
        emittedCalls += reply.functionCalls
        return reply
    }
}

private actor Phase21GeminiClient: GeminiClientProtocol {
    private(set) var history: [ChatMessage] = []
    private(set) var tools: [ToolDeclarationWrapper]?
    private(set) var prompt = ""
    private(set) var key = ""
    let reply: ModelTurnResponse
    init(_ reply: ModelTurnResponse) { self.reply = reply }
    func generateContent(history: [ChatMessage], systemPrompt: String,
                         tools: [ToolDeclarationWrapper]?, apiKey: String) -> ModelTurnResponse {
        self.history = history; self.tools = tools; prompt = systemPrompt; key = apiKey
        return reply
    }
}

private actor Phase21LateProvider: ModelProvider {
    nonisolated let descriptor = ModelProviderDescriptor(providerID: "late-fixture", supportsTools: true)
    private var waiting: CheckedContinuation<ModelTurnResponse, Never>?
    var isWaiting: Bool { waiting != nil }
    func generate(_ request: ModelRequest) async -> ModelTurnResponse {
        await withCheckedContinuation { waiting = $0 }
    }
    func release() {
        waiting?.resume(returning: ModelTurnResponse(functionCalls: [FunctionCall(name: "open_app", args: ["name": "Calculator"])]))
        waiting = nil
    }
}

private actor Phase21Workspace: WorkspaceProtocol {
    private(set) var opened = 0
    nonisolated func findApplicationURL(named name: String) -> URL? { URL(fileURLWithPath: "/fixture/Calculator.app") }
    func openApplication(at url: URL) { opened += 1 }
}

@Suite("Phase 21 model boundary")
struct Phase21ModelProviderTests {
    private let request = ModelRequest(history: [ChatMessage(role: .user, text: "Hello")], systemPrompt: "Ivy")

    @Test("Gemini adapter forwards credentials privately and preserves signed tool parts")
    func gemini() async throws {
        let call = FunctionCall(name: "open_app", args: ["name": "Calculator"])
        let reply = ModelTurnResponse(functionCalls: [call], functionCallParts: [Part(functionCall: call, thoughtSignature: "opaque-signature")])
        let client = Phase21GeminiClient(reply)
        let provider = GeminiModelProvider(client: client, credentials: FixedCredentialProvider([.geminiAPIKey: "fixture-credential"]), modelID: "fixture-gemini")
        let tools = [ToolDeclarationWrapper(functionDeclarations: [OpenAppTool().declaration])]
        let input = ModelRequest(history: request.history, systemPrompt: request.systemPrompt, tools: tools)
        #expect(try await provider.response(to: input) == reply)
        #expect(await client.history == input.history)
        #expect(await client.tools == tools)
        #expect(await client.prompt == "Ivy")
        #expect(await client.key == "fixture-credential")
        #expect(provider.descriptor.requiresGeminiCredential)
        #expect(provider.descriptor.modelID == "fixture-gemini")
        #expect(GeminiModelProvider(client: URLSessionGeminiClient(), credentials: FixedCredentialProvider([:])).descriptor.modelID == "gemini-3.8-flash")
        #expect(GeminiModelProvider(client: client, credentials: FixedCredentialProvider([:])).descriptor.modelID == nil)
        let custom = URLSessionGeminiClient(baseURLString: "https://example.invalid/v1/models/fixture-model?trace=ignore")
        #expect(GeminiModelProvider(client: custom, credentials: FixedCredentialProvider([:])).descriptor.modelID == "fixture-model")
        await #expect(throws: ModelProviderError.unexpectedToolCalls) { try await provider.text(for: request) }
        await #expect(throws: GeminiClientError.missingAPIKey) {
            try await GeminiModelProvider(client: client, credentials: FixedCredentialProvider([:])).response(to: input)
        }
        let plannerClient = Phase21GeminiClient(ModelTurnResponse(text: "{\"steps\":[]}"))
        let planner = GeminiTaskPlanner(client: plannerClient, credentials: FixedCredentialProvider([.geminiAPIKey: "fixture-credential"]))
        #expect(try await planner.plan(goal: "Open Calculator", context: "Previous attempt", tools: [OpenAppTool().declaration]) == "{\"steps\":[]}")
        #expect(await plannerClient.history.first?.text.contains("Previous attempt") == true)
    }

    @Test("Unsupported capabilities fail before contacting a provider; OCR remains usable")
    func capabilities() async throws {
        let provider = Phase21Provider([ModelTurnResponse(text: "OCR answer")], tools: false, images: false)
        let image = ImageAttachment(source: .image(filename: "fixture"), jpeg: [Data([1])], text: nil)
        await #expect(throws: ModelProviderError.unsupportedImages) {
            try await provider.response(to: ModelRequest(history: [ChatMessage(role: .user, text: "What's this?", attachments: [image])], systemPrompt: "Ivy"))
        }
        await #expect(throws: ModelProviderError.unsupportedTools) {
            try await provider.response(to: ModelRequest(history: [], systemPrompt: "Ivy", tools: [ToolDeclarationWrapper(functionDeclarations: [OpenAppTool().declaration])]))
        }
        #expect(await provider.requests.isEmpty)
        let ocr = ImageAttachment(source: .image(filename: "fixture"), jpeg: [], text: "OCR text")
        #expect(try await provider.text(for: ModelRequest(history: [ChatMessage(role: .user, text: "Explain", attachments: [ocr])], systemPrompt: "Ivy")) == "OCR answer")
    }

    @Test("Text-only planning and empty answers cannot hide tool calls")
    func textErrors() async {
        let call = FunctionCall(name: "open_app", args: ["name": "Calculator"])
        let provider = Phase21Provider([ModelTurnResponse(functionCalls: [call]), ModelTurnResponse(text: " \n"), ModelTurnResponse()])
        await #expect(throws: ModelProviderError.unexpectedToolCalls) {
            try await ModelTaskPlanner(provider: provider).plan(goal: "Open Calculator", context: "", tools: [OpenAppTool().declaration])
        }
        for _ in 0..<2 {
            await #expect(throws: ModelProviderError.emptyResponse) { try await provider.text(for: request) }
        }
        let toolRequest = ModelRequest(history: [], systemPrompt: "Ivy", tools: [ToolDeclarationWrapper(functionDeclarations: [OpenAppTool().declaration])])
        await #expect(throws: ModelProviderError.unexpectedToolCalls) {
            try await Phase21Provider([ModelTurnResponse(functionCalls: [call])]).text(for: toolRequest)
        }
    }

    @Test("Alternate provider completes chat, titles and briefings without a Gemini key")
    @MainActor func alternate() async {
        let provider = Phase21Provider([ModelTurnResponse(text: "Hello"), ModelTurnResponse(text: "Your briefing")], tools: false)
        let brain = IvyBrain(modelProvider: provider, credentials: FixedCredentialProvider([:]))
        brain.autoTitles = true
        await brain.send("Hi")
        await brain.waitForMaintenance()
        #expect(brain.messages.last?.text == "Hello")
        #expect(brain.errorMessage == nil)
        #expect(brain.currentConversation.title == "Fixture conversation")
        #expect(await brain.composeBriefing(from: "One task") == "Your briefing")
        #expect(await provider.requests.map(\.purpose) == [.chat, .conversationTitle, .briefing])
        #expect(await provider.requests.first?.tools == nil)
        await brain.send("Network fails")
        #expect(brain.messages.last?.isError == true)
        #expect(!brain.isThinking)
    }

    @Test("A cancelled late response cannot execute tools or append an answer")
    @MainActor func cancellation() async throws {
        let provider = Phase21LateProvider()
        let workspace = Phase21Workspace()
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [OpenAppTool(workspace: workspace)]))
        let brain = IvyBrain(modelProvider: provider, toolDispatcher: dispatcher, credentials: FixedCredentialProvider([:]))
        let task = Task { await brain.send("Open Calculator") }
        for _ in 0..<10_000 {
            if await provider.isWaiting { break }
            await Task.yield()
        }
        #expect(await provider.isWaiting)
        task.cancel()
        await provider.release()
        await task.value
        #expect(brain.messages.count == 1)
        #expect(!brain.isThinking)
        #expect(brain.toolNotes.isEmpty)
        #expect(await workspace.opened == 0)
        let cancelled = Task { () throws -> ModelTurnResponse in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.response(to: request)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }

    @Test("Chat exposes unsupported images, unexpected tools and empty replies, then recovers")
    @MainActor func visibleErrors() async {
        let provider = Phase21Provider([ModelTurnResponse(),
            ModelTurnResponse(functionCalls: [FunctionCall(name: "open_app", args: ["name": "Calculator"])]),
            ModelTurnResponse(text: "Recovered")], tools: false, images: false)
        let brain = IvyBrain(modelProvider: provider, credentials: FixedCredentialProvider([:]))
        let image = ImageAttachment(source: .image(filename: "fixture"), jpeg: [Data([1])], text: nil)
        await brain.send("Image", attachments: [image])
        #expect(brain.errorMessage == ModelProviderError.unsupportedImages.localizedDescription)
        #expect(await provider.requests.isEmpty)
        await brain.send("Empty reply")
        #expect(brain.errorMessage == ModelProviderError.emptyResponse.localizedDescription)
        await brain.send("Unexpected action")
        #expect(brain.errorMessage == ModelProviderError.unexpectedToolCalls.localizedDescription)
        #expect(brain.toolNotes.isEmpty)
        await brain.send("Try again")
        #expect(brain.messages.last?.text == "Recovered")
        #expect(brain.errorMessage == nil && !brain.isThinking)
    }

    @Test("Production environment shares the alternate provider between chat and planning")
    @MainActor func environment() async {
        let plan = """
        {"steps":[{"id":"1","title":"Open Calculator","tool":"open_app","arguments":{"name":"Calculator"},"dependsOn":[],"onFailure":"abort"}]}
        """
        let provider = Phase21Provider([ModelTurnResponse(text: "Hello"), ModelTurnResponse(text: plan)])
        let env = IvyAppEnvironment(settingsStore: InMemorySettingsStore(), credentials: FixedCredentialProvider([:]),
                                    conversationStore: InMemoryConversationStore(), modelProvider: provider) { _, _ in
            GeminiLiveVoiceCoordinator(session: MockGeminiLiveSession(), audioCapture: MockAudioCapture(),
                                       audioPlayer: MockLiveAudioPlayer(), wakeWordDetector: MockWakeWordDetector())
        }
        env.brain.autoTitles = false
        await env.brain.send("Hi")
        await env.brain.waitForMaintenance()
        await env.tasks.start(goal: "Open Calculator")
        #expect(env.brain.messages.last?.text == "Hello")
        #expect(env.tasks.run?.phase == .awaitingApproval)
        #expect(env.tasks.run?.plan.steps.first?.tool == "open_app")
        #expect(await provider.requests.map(\.purpose) == [.chat, .taskPlan])
        #expect(await provider.requests.last?.tools == nil)
        env.tasks.cancel()
    }
}
