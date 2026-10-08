import Foundation
import Testing
@testable import IvyCore

@MainActor
@Suite("Chat feed request ordering")
struct ChatFeedOrderingTests {
    private func message(_ text: String, at seconds: TimeInterval, role: MessageRole = .user) -> ChatMessage {
        ChatMessage(role: role, text: text, timestamp: Date(timeIntervalSince1970: seconds))
    }

    @Test("late voice requests stay above their cards, including equal-time calls and status updates")
    func lateRequests() {
        let first = message("Open my folder", at: 5)
        let second = message("Open Calculator", at: 10)
        let reply = message("Done", at: 11, role: .model)
        let activity = ToolActivity()
        let call = FunctionCall(name: "fixture", args: [:])
        let a = activity.begin(call, now: Date(timeIntervalSince1970: 2), requestMessageID: first.id)
        let b = activity.begin(call, now: Date(timeIntervalSince1970: 1), requestMessageID: second.id)
        let c = activity.begin(call, now: Date(timeIntervalSince1970: 2), requestMessageID: first.id)
        let earlier = activity.begin(call, now: Date(timeIntervalSince1970: 1), requestMessageID: first.id)
        let messages = [first, second, reply]
        let expected = ["message-\(first.id)", "tool-\(earlier)", "tool-\(a)", "tool-\(c)", "message-\(second.id)", "tool-\(b)", "message-\(reply.id)"]
        #expect(ChatFeedTimeline.items(messages: messages, records: activity.records).map(\.id) == expected)
        activity.complete(a, response: FunctionResponse(name: "fixture", response: ["success": true]))
        activity.complete(c, response: FunctionResponse(name: "fixture", response: ["success": false]))
        #expect(ChatFeedTimeline.items(messages: messages, records: activity.records).map(\.id) == expected)
        #expect(activity.records.map(\.status) == [.succeeded, .running, .failed, .running])
    }

    @Test("unlinked, missing and non-user parents keep chronological placement without invented questions")
    func fallback() {
        let request = message("Question", at: 2)
        let reply = message("Reply", at: 4, role: .model)
        let activity = ToolActivity()
        let call = FunctionCall(name: "fixture", args: [:])
        let legacy = activity.begin(call, now: Date(timeIntervalSince1970: 1))
        let missing = activity.begin(call, now: Date(timeIntervalSince1970: 3), requestMessageID: UUID())
        let model = activity.begin(call, now: Date(timeIntervalSince1970: 4), requestMessageID: reply.id)
        #expect(ChatFeedTimeline.items(messages: [request, reply], records: activity.records).map(\.id) ==
            ["tool-\(legacy)", "message-\(request.id)", "tool-\(missing)", "message-\(reply.id)", "tool-\(model)"])
        #expect(ChatFeedTimeline.items(messages: [], records: activity.records).count == 3)
        #expect(ChatFeedTimeline.items(messages: [], records: []).isEmpty)
    }

    @Test("forwarded activity preserves the request through completion and discards stale completions after reset")
    func forwarded() {
        let requestID = UUID()
        let shared = ToolActivity(), voice = ToolActivity()
        voice.destination = shared
        let id = voice.begin(FunctionCall(name: "fixture", args: [:]), requestMessageID: requestID)
        #expect(shared.records.first?.requestMessageID == requestID && voice.records.isEmpty)
        voice.complete(id, response: FunctionResponse(name: "fixture", response: ["success": true]))
        #expect(shared.records.first?.requestMessageID == requestID && shared.records.first?.status == .succeeded)
        voice.reset()
        voice.complete(id, response: FunctionResponse(name: "fixture", response: ["success": true]))
        #expect(shared.records.isEmpty)
    }

    @Test("late transcript chunks merge into one stable request and respect transcript saving")
    func transcriptChunks() {
        let store = InMemoryConversationStore()
        let brain = IvyBrain(client: MockGeminiClient(), apiKey: "fixture", conversationStore: store)
        let requestID = UUID()
        brain.appendVoiceTranscript("Open", fromUser: true, requestMessageID: requestID)
        let timestamp = brain.messages.first?.timestamp
        brain.appendVoiceTranscript("my folder", fromUser: true, requestMessageID: requestID)
        brain.appendVoiceTranscript("Done", fromUser: false, requestMessageID: requestID)
        #expect(brain.messages.count == 2)
        #expect(brain.messages[0].id == requestID && brain.messages[0].text == "Open my folder")
        #expect(brain.messages[0].timestamp == timestamp && brain.messages[1].id != requestID)
        #expect(brain.currentConversation.messages.first?.text == "Open my folder")
        brain.savesVoiceTranscripts = false
        brain.appendVoiceTranscript("Do not save", fromUser: true, requestMessageID: UUID())
        #expect(brain.messages.count == 2)
    }

    @Test("live tools arriving before transcription bind to the correct turn through the environment")
    func voiceWiring() async throws {
        let session = MockGeminiLiveSession()
        let environment = IvyAppEnvironment(settingsStore: InMemorySettingsStore(),
            credentials: FixedCredentialProvider([.geminiAPIKey: "fixture"]),
            conversationStore: InMemoryConversationStore(), geminiClient: MockGeminiClient()) { _, _ in
                GeminiLiveVoiceCoordinator(session: session, audioCapture: MockAudioCapture(),
                    audioPlayer: MockLiveAudioPlayer(autoDrain: true), wakeWordDetector: MockWakeWordDetector(),
                    toolDispatcher: ToolDispatcher(registry: ToolRegistry(tools: [])))
            }
        let coordinator = environment.liveCoordinator
        let brain = environment.brain
        await coordinator.startSession()
        let firstID = coordinator.transcriptTurnID
        session.simulateEvent(.toolCall(FunctionCall(name: "missing_fixture", args: [:], id: "first")))
        #expect(await waitUntil { brain.toolDispatcher.activity.records.first?.status == .failed })
        #expect(brain.messages.isEmpty)
        session.simulateEvent(.inputTranscript("Open my folder"))
        session.simulateEvent(.outputTranscript("Unable to open it"))
        session.simulateEvent(.turnComplete)
        #expect(await waitUntil { brain.messages.count == 2 })
        #expect(brain.messages.first?.id == firstID)
        let firstRecord = try #require(brain.toolDispatcher.activity.records.first)
        #expect(firstRecord.requestMessageID == firstID)
        #expect(ChatFeedTimeline.items(messages: brain.messages, records: [firstRecord]).map(\.id) ==
            ["message-\(firstID)", "tool-\(firstRecord.id)", "message-\(brain.messages[1].id)"])
        let secondID = coordinator.transcriptTurnID
        #expect(secondID != firstID)
        session.simulateEvent(.inputTranscript("Open"))
        session.simulateEvent(.outputTranscript("Checking"))
        // The rest of the request arrives after output has already flushed its first chunk.
        session.simulateEvent(.inputTranscript("Calculator"))
        session.simulateEvent(.toolCall(FunctionCall(name: "missing_fixture", args: [:], id: "second")))
        session.simulateEvent(.turnComplete)
        #expect(await waitUntil { brain.messages.count == 4 && brain.toolDispatcher.activity.records.count == 2 && brain.toolDispatcher.activity.records[1].status == .failed })
        #expect(brain.messages[2].id == secondID && brain.messages[2].text == "Open Calculator")
        #expect(brain.toolDispatcher.activity.records[1].requestMessageID == secondID)
        #expect(coordinator.transcriptTurnID != secondID)
        await coordinator.stopSession()
    }
}
