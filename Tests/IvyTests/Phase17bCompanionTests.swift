import Testing
import Foundation
import CoreGraphics
import ImageIO
import os
@testable import IvyCore

private final class RecordingPresenter: AnnotationPresenting, @unchecked Sendable {
    private let shown = OSAllocatedUnfairLock(initialState: [(CGRect, String)]())
    var all: [(CGRect, String)] { shown.withLock { $0 } }
    func show(_ rect: CGRect, label: String) async { shown.withLock { $0.append((rect, label)) } }
}

private func run(_ phase: TaskPhase, steps: [StepStatus]) -> TaskRun {
    var plan = TaskPlan(goal: "g", steps: steps.enumerated().map { TaskStep(id: "\($0.offset)", title: "s", tool: "echo") })
    for (i, status) in steps.enumerated() { plan.steps[i].status = status }
    return TaskRun(plan: plan, phase: phase, createdAt: Date())
}

@Suite("Phase 17b - Companion mood")
struct Phase17bMoodTests {
    private func mood(_ voice: VoiceSessionState = .idle, thinking: Bool = false, approval: Bool = false,
                      task: TaskRun? = nil, idle: Bool = false) -> CompanionMood {
        CompanionMood.resolve(voice: voice, chatThinking: thinking, approvalPending: approval, task: task, showWhileIdle: idle)
    }

    @Test("hidden when nothing is happening, unless the user keeps it on screen")
    func idle() {
        #expect(mood() == .hidden)
        #expect(mood(idle: true) == .idle)
    }

    @Test("each activity has its face")
    func states() {
        #expect(mood(.listening) == .listening)
        #expect(mood(.speaking) == .speaking)
        #expect(mood(.connecting) == .thinking)
        #expect(mood(.reconnecting(2)) == .thinking)
        #expect(mood(.toolExecution) == .thinking)
        #expect(mood(thinking: true) == .thinking)
        #expect(mood(.error("mic gone")) == .error("mic gone"))
        #expect(mood(task: run(.running(stepID: "1"), steps: [.succeeded, .running, .pending, .pending])) == .working(0.25))
        #expect(mood(task: run(.planning, steps: [])) == .thinking)
        #expect(mood(task: run(.finished(.succeeded), steps: [.succeeded])) == .hidden, "a finished task doesn't keep it up")
    }

    @Test("approval always wins: a waiting card is never hidden behind another face")
    func approvalWins() {
        #expect(mood(.speaking, approval: true) == .needsApproval)
        #expect(mood(.toolConfirmation) == .needsApproval)
        #expect(mood(.listening, task: run(.awaitingApproval, steps: [.pending])) == .needsApproval)
        #expect(mood(task: run(.paused(.budget("x")), steps: [.succeeded, .pending])) == .needsApproval)
        #expect(mood(.error("x"), approval: true) == .needsApproval)
    }
}

@Suite("Phase 17b - Placement and pointing")
struct Phase17bGeometryTests {
    @Test("corners sit inside the visible frame with a margin; a drag snaps to the nearest one")
    func corners() {
        let visible = CGRect(x: 0, y: 25, width: 1440, height: 875) // below the menu bar, above nothing
        let size = CGSize(width: 280, height: 150)
        #expect(CompanionCorner.bottomRight.origin(for: size, in: visible) == CGPoint(x: 1440 - 280 - 16, y: 25 + 16))
        #expect(CompanionCorner.topLeft.origin(for: size, in: visible) == CGPoint(x: 16, y: 25 + 875 - 150 - 16))
        #expect(CompanionCorner.nearest(to: CGPoint(x: 1300, y: 100), in: visible) == .bottomRight)
        #expect(CompanionCorner.nearest(to: CGPoint(x: 100, y: 800), in: visible) == .topLeft)
        // A second display to the left, with a negative origin.
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        #expect(CompanionCorner.nearest(to: CGPoint(x: -200, y: 900), in: left) == .topRight)
    }

    @Test("screenshot pixels map back to the right screen area: scale, offset, flipped Y, other displays")
    func mapping() throws {
        // A Retina window capture: 800×600 points at (100, 50) top-left, sent as a 1600×1200 image.
        let window = CaptureGeometry(frame: CGRect(x: 100, y: 50, width: 800, height: 600), imageSize: CGSize(width: 1600, height: 1200))
        let rect = try #require(window.screenRect(forImageRect: CGRect(x: 200, y: 100, width: 400, height: 200), mainDisplayHeight: 900))
        #expect(rect == CGRect(x: 200, y: 900 - (50 + 50 + 100), width: 200, height: 100))

        // A display to the left of the main one (negative x), captured downscaled to 2048 wide.
        let display = CaptureGeometry(frame: CGRect(x: -2560, y: 0, width: 2560, height: 1440), imageSize: CGSize(width: 2048, height: 1152))
        let left = try #require(display.screenRect(forImageRect: CGRect(x: 0, y: 0, width: 2048, height: 1152), mainDisplayHeight: 1440))
        #expect(left == CGRect(x: -2560, y: 0, width: 2560, height: 1440))

        // Clamped to the image; entirely outside → nil.
        let clamped = try #require(window.screenRect(forImageRect: CGRect(x: 1500, y: 1100, width: 500, height: 500), mainDisplayHeight: 900))
        #expect(clamped.width == 50 && clamped.height == 50)
        #expect(window.screenRect(forImageRect: CGRect(x: 5000, y: 5000, width: 10, height: 10), mainDisplayHeight: 900) == nil)
    }

    @Test("point_at: safe, needs a screenshot Ivy was actually shown, draws at the mapped place, can't do anything else")
    func pointAt() async throws {
        let relay = ScreenGeometryRelay()
        let presenter = RecordingPresenter()
        let tool = PointAtTool(geometry: relay, presenter: presenter, mainDisplayHeight: { 900 })
        #expect(SafetyPolicy().classification(for: tool, call: FunctionCall(name: "point_at")) == .safe)
        let args: [String: AnyCodable] = ["x": 200, "y": 100, "width": 400, "height": 200, "label": "Export"]
        #expect(throws: ToolError.self) { try tool.validate(arguments: args) }

        relay.record(CaptureGeometry(frame: CGRect(x: 100, y: 50, width: 800, height: 600), imageSize: CGSize(width: 1600, height: 1200)))
        try tool.validate(arguments: args)
        let result = try await tool.execute(arguments: args)
        #expect(!result.isError)
        #expect(presenter.all.first?.0 == CGRect(x: 200, y: 700, width: 200, height: 100))
        #expect(presenter.all.first?.1 == "Export")

        for bad: [String: AnyCodable] in [
            ["x": -1, "y": 0, "width": 10, "height": 10, "label": "a"],
            ["x": 0, "y": 0, "width": 1, "height": 10, "label": "a"],
            ["x": 0, "y": 0, "width": 10, "height": 10, "label": .string(String(repeating: "a", count: 61))],
            ["x": 0, "y": 0, "width": 10, "height": 10, "label": "a", "click": true],
        ] {
            #expect(throws: ToolError.self) { try tool.validate(arguments: bad) }
        }
    }

    @MainActor
    @Test("the screenshot's geometry is recorded only when Ivy is shown it (sent), not when it's merely attached")
    func geometryOnSend() async throws {
        final class Capturer: ScreenContextCapturing, @unchecked Sendable {
            func frontmostOtherApp() async -> String? { "Xcode" }
            func capture(_ target: CaptureTarget) async throws -> CapturedScreen {
                let ctx = ImageProcessing.rgbContext(width: 400, height: 300)!
                let image = ctx.makeImage()!
                let data = NSMutableData()
                let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
                return CapturedScreen(png: data as Data, app: "Xcode", frame: CGRect(x: 10, y: 20, width: 400, height: 300))
            }
        }
        struct NoText: TextRecognizing { func recognize(_ image: Data) async throws -> [RecognizedText] { [] } }
        let relay = ScreenGeometryRelay()
        let tray = AttachmentTray(capturer: Capturer(), pipeline: VisionPipeline(recognizer: NoText()), policy: { VisionPolicy() }, geometry: relay)
        let attachment = try #require(await tray.capture(.frontWindow))
        #expect(attachment.geometry == CaptureGeometry(frame: CGRect(x: 10, y: 20, width: 400, height: 300), imageSize: CGSize(width: 400, height: 300)))
        #expect(relay.current == nil)
        _ = tray.take()
        #expect(relay.current == attachment.geometry)
    }
}

@Suite("Phase 17b - Captions, settings, shortcuts, wiring")
struct Phase17bWiringTests {
    @MainActor
    @Test("captions follow what Ivy is saying and clear when the reply ends")
    func captions() async {
        let session = MockGeminiLiveSession()
        let coordinator = GeminiLiveVoiceCoordinator(session: session, audioCapture: MockAudioCapture(), audioPlayer: MockLiveAudioPlayer(),
                                                     wakeWordDetector: MockWakeWordDetector())
        await coordinator.startSession()
        session.simulateEvent(.outputTranscript("Your build failed "))
        session.simulateEvent(.outputTranscript("because of a typo."))
        #expect(await waitUntil { coordinator.caption == "Your build failed because of a typo." })
        session.simulateEvent(.turnComplete)
        #expect(await waitUntil { coordinator.caption.isEmpty })
        await coordinator.stopSession()
    }

    @Test("companion on by default (it only shows while active), not while idle; shortcuts don't collide")
    func defaults() throws {
        let d = IvySettings.defaults
        #expect(d.companionEnabled && !d.companionShowWhileIdle && d.companionCorner == .bottomRight && d.commandBarHotkeyEnabled)
        var s = d
        s.companionCorner = .topLeft
        #expect(try JSONDecoder().decode(IvySettings.self, from: JSONEncoder().encode(s)).companionCorner == .topLeft)
        let shortcuts = [HotkeyShortcut.defaultPushToTalk, .defaultScreenHelp, .defaultCommandBar]
        #expect(Set(shortcuts).count == 3)
    }

    @MainActor
    @Test("point_at is in the app's catalogue, sharing the screenshot geometry with the attachment tray")
    func wiring() {
        let geometry = ScreenGeometryRelay()
        let registry = IvyAppEnvironment.toolRegistry(relay: ProactiveRelay(), geometry: geometry)
        #expect(registry.tool(named: "point_at")?.group == .core)
    }
}
