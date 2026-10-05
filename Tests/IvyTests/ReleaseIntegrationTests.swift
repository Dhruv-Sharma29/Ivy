import Foundation
import Testing
@testable import IvyCore

private struct CardTool: IvyTool {
    let name = "card_fixture"
    let description = "Fixture"
    let safetyClassification: ToolSafetyClassification = .risky
    let declaration = FunctionDeclaration(name: "card_fixture", description: "Fixture", parameters: ToolParameters(type: "OBJECT", properties: [:], required: []))
    func execute(arguments: [String: AnyCodable]) async throws -> ToolResult { .success("finished") }
}

@MainActor
private final class CardApproval: ConfirmationHandler {
    var continuation: CheckedContinuation<Bool, Never>?
    func handleConfirmation(_ request: ConfirmationRequest) async -> Bool {
        await withCheckedContinuation { continuation = $0 }
    }
    func answer(_ approved: Bool) { continuation?.resume(returning: approved); continuation = nil }
}

@MainActor
@Suite("Release integration — display-only tool activity")
struct ToolActivityTests {
    @Test("running cards precede approval; cancellation cannot execute; duplicate call IDs retain distinct cards")
    func lifecycle() async throws {
        let approval = CardApproval()
        let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: [CardTool()]),
            safetyGate: InteractiveSafetyGate(confirmationProvider: ConfirmationBridge(handler: approval)))
        let call = FunctionCall(name: "card_fixture", args: [:], id: "same")
        let first = Task { await dispatcher.dispatch(call) }
        for _ in 0..<200 where approval.continuation == nil { await Task.yield() }
        #expect(approval.continuation != nil)
        #expect(dispatcher.activity.records.first?.status == .running)
        approval.answer(false)
        let rejected = await first.value
        #expect(rejected.response["success"]?.boolValue == false)
        #expect(dispatcher.activity.records.first?.status == .failed)
        let second = Task { await dispatcher.dispatch(call) }
        for _ in 0..<200 where approval.continuation == nil { await Task.yield() }
        #expect(approval.continuation != nil)
        approval.answer(true)
        _ = await second.value
        #expect(dispatcher.activity.records.last?.status == .succeeded)
        #expect(dispatcher.activity.records.last?.output?.contains("finished") == true)
        #expect(Set(dispatcher.activity.records.map(\.id)).count == 2)
        _ = await dispatcher.dispatch(FunctionCall(name: "missing", args: [:]))
        #expect(dispatcher.activity.records.last?.status == .failed)
        #expect(dispatcher.activity.records.last?.output?.contains("not recognized") == true)
    }

    @Test("nested credentials are masked, long outputs capped, old conversation completions discarded")
    func displaySafety() {
        let activity = ToolActivity()
        let voice = ToolActivity()
        voice.destination = activity
        let call = FunctionCall(name: "fixture", args: ["api_key": "short", "nested": ["access_token": "value"],
            "array": [.dictionary(["password": "secret-value"])], "message": "Bearer abcdefghijklmnopqrst"])
        let id = voice.begin(call)
        let arguments = activity.records[0].arguments
        #expect(!arguments.contains("short") && !arguments.contains("secret-value") && !arguments.contains("abcdefghijklmnopqrst"))
        #expect(arguments.contains("[REDACTED]"))
        voice.complete(id, response: FunctionResponse(name: "fixture", response: ["success": true, "result": .string(String(repeating: "x", count: 20_000))]))
        #expect(activity.records[0].output?.hasSuffix("… (truncated)") == true)
        #expect((activity.records[0].output?.count ?? 0) < 12_040)
        voice.reset()
        voice.complete(id, response: FunctionResponse(name: "fixture", response: ["success": true]))
        #expect(activity.records.isEmpty)
        for _ in 0..<110 { _ = activity.begin(call) }
        #expect(activity.records.count == 100)
        let brain = IvyBrain(toolDispatcher: ToolDispatcher(registry: ToolRegistry(tools: [])), apiKey: "fixture")
        _ = brain.toolDispatcher.activity.begin(call)
        #expect(brain.currentConversation.messages.isEmpty)
        brain.startNewConversation()
        #expect(brain.toolDispatcher.activity.records.isEmpty)
        #expect(ToolExecution.displayJSON(["number": .double(.nan)]).contains("Details unavailable"))
    }
}

@Suite("Release integration — diff requests")
struct DiffDraftTests {
    @Test("diff requests preserve drafts, require a target and never treat patches as replacement contents")
    func drafts() throws {
        let diff = "--- a/notes.txt\n+++ b/notes.txt\n@@ -1 +1 @@\n-old\n+new"
        #expect(DiffDraft.suggestedPath(in: diff) == "notes.txt")
        #expect(DiffDraft.suggestedPath(in: "+++ /dev/null") == "")
        #expect(DiffDraft.suggestedPath(in: "-old\n+new") == "")
        let draft = try DiffDraft.make(diff: diff, path: "~/Documents/notes.txt")
        #expect(draft.contains("file_op") && draft.contains("approval") && draft.contains("proposed_diff"))
        #expect(!draft.contains("\"content\""))
        #expect(DiffDraft.appending(draft, to: "My draft") == "My draft\n\n" + draft)
        #expect(DiffDraft.appending(draft, to: " \n") == draft)
        for path in ["", "../notes.txt", "/tmp/../notes.txt", "notes\n.txt", "x\0y"] {
            #expect(throws: DiffDraft.DraftError.self) { try DiffDraft.make(diff: diff, path: path) }
        }
        for invalid in ["prose", "--- a/file\n+++ b/file", "GIT binary patch\n+new", "Binary files a and b differ\n+new", String(repeating: "+", count: 200_001)] {
            #expect(throws: DiffDraft.DraftError.self) { try DiffDraft.make(diff: invalid, path: "notes.txt") }
        }
    }
}

private actor BarCapture: ScreenContextCapturing {
    var calls: [CaptureTarget] = []
    let image: Data
    init(image: Data) { self.image = image }
    func frontmostOtherApp() async -> String? { "Fixture" }
    func capture(_ target: CaptureTarget) async throws -> CapturedScreen {
        calls.append(target)
        return CapturedScreen(png: image, app: "Fixture")
    }
}

private struct BarRecognizer: TextRecognizing {
    func recognize(_ image: Data) async throws -> [RecognizedText] { [] }
}

@MainActor
@Suite("Release integration — floating screen attachment")
struct CommandBarSessionTests {
    @Test("capture stays in the shared tray until explicit send, then reaches chat without persisted pixels")
    func captureAndSend() async throws {
        let context = try #require(ImageProcessing.rgbContext(width: 40, height: 30))
        let image = try #require(context.makeImage())
        let jpeg = try ImageProcessing.jpeg(image)
        let capturer = BarCapture(image: jpeg)
        let client = MockGeminiClient()
        let environment = IvyAppEnvironment(settingsStore: UserDefaultsSettingsStore(defaults: try #require(UserDefaults(suiteName: UUID().uuidString))),
            credentials: FixedCredentialProvider([.geminiAPIKey: "fixture"]), conversationStore: InMemoryConversationStore(),
            geminiClient: client, screenCapturer: capturer, visionPipeline: VisionPipeline(recognizer: BarRecognizer())) { _, _ in
            GeminiLiveVoiceCoordinator(session: MockGeminiLiveSession(), audioCapture: MockAudioCapture(), audioPlayer: MockLiveAudioPlayer())
        }
        let bar = CommandBarSession(brain: environment.brain, tray: environment.attachments, tasks: environment.tasks, live: environment.liveCoordinator)
        #expect(await bar.send() == false)
        await bar.captureFrontWindow()
        #expect(await capturer.calls == [.frontWindow])
        #expect(environment.attachments.attachments.count == 1 && environment.brain.messages.isEmpty)
        let selected = try #require(environment.attachments.attachments.first)
        bar.prepareScreenQuestion(selected)
        #expect(bar.screenQuestionID == selected.id && bar.text == "What is this, and how does it work?")
        bar.text = "Keep my draft"; bar.prepareScreenQuestion(selected)
        #expect(bar.text == "Keep my draft")
        bar.text = "/agent organize"
        #expect(bar.blocked != nil)
        #expect(await bar.send() == false)
        #expect(bar.text == "/agent organize" && environment.attachments.attachments.count == 1)
        await bar.captureFrontWindow()
        #expect(await capturer.calls.count == 1)
        bar.text = "Explain this window"
        #expect(await bar.send())
        #expect(environment.attachments.attachments.isEmpty)
        #expect(client.recordedHistory.first?.attachments.count == 1)
        #expect(bar.askedID == environment.brain.messages.first?.id && bar.text.isEmpty)
        #expect(bar.screenQuestionID == nil)
        #expect(environment.brain.currentConversation.messages.first?.text.contains("not saved") == true)
        #expect(!(try JSONEncoder().encode(environment.brain.currentConversation)).contains(jpeg))
        await environment.liveCoordinator.startSession()
        bar.text = "preserve this"
        #expect(bar.blocked != nil)
        #expect(await bar.send() == false)
        await bar.captureFrontWindow()
        #expect(await capturer.calls.count == 1)
        #expect(bar.text == "preserve this")
        await environment.liveCoordinator.stopSession()
    }
}

@Suite("Release integration — screen-edge pointer")
struct AnnotationGeometryTests {
    @Test("arrows point toward the nearest usable edge of a target on every side, including negative display origins")
    func displays() throws {
        for origin in [CGPoint.zero, CGPoint(x: -900, y: 400)] {
            let screen = CGRect(origin: origin, size: CGSize(width: 800, height: 600))
            for offset in [CGPoint(x: 100, y: 260), CGPoint(x: 650, y: 260), CGPoint(x: 370, y: 100), CGPoint(x: 370, y: 450)] {
                let target = CGRect(x: origin.x + offset.x, y: origin.y + offset.y, width: 50, height: 50)
                let geometry = try #require(AnnotationGeometry(screen: screen, target: target))
                #expect(geometry.highlight.minX == offset.x)
                #expect(geometry.highlight.minY == 600 - offset.y - 50)
                #expect(hypot(geometry.end.x - geometry.start.x, geometry.end.y - geometry.start.y) >= 40)
                #expect(geometry.headA != geometry.headB)
                #expect(geometry.labelOrigin.x >= 16 && geometry.labelOrigin.y >= 16)
            }
        }
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        #expect(AnnotationGeometry(screen: screen, target: screen)?.highlight == screen)
        #expect(AnnotationGeometry(screen: screen, target: CGRect(x: 900, y: 900, width: 50, height: 50)) == nil)
        #expect(AnnotationGeometry(screen: .zero, target: screen) == nil)
        #expect(AnnotationGeometry(screen: screen, target: .zero) == nil)
        #expect(AnnotationGeometry(screen: screen, target: CGRect(x: CGFloat.infinity, y: 0, width: 40, height: 40)) == nil)
        let clipped = try #require(AnnotationGeometry(screen: screen, target: CGRect(x: -20, y: 200, width: 100, height: 100)))
        #expect(clipped.highlight.width == 80 && clipped.highlight.minX == 0)
    }
}
