import Testing
import Foundation
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import os
@testable import IvyCore

private func captureGeometry(_ x: CGFloat = 0) -> CaptureGeometry {
    CaptureGeometry(frame: CGRect(x: x, y: 50, width: 400, height: 300), imageSize: CGSize(width: 800, height: 600))
}

private func captureImage() throws -> Data {
    let context = try #require(ImageProcessing.rgbContext(width: 800, height: 600))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

private struct GuidanceNoText: TextRecognizing {
    func recognize(_ image: Data) async throws -> [RecognizedText] { [] }
}

private final class GuidanceCapturer: ScreenContextCapturing, @unchecked Sendable {
    let image: Data
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    init(image: Data) { self.image = image }
    func frontmostOtherApp() async -> String? { "Editor" }
    func capture(_ target: CaptureTarget) async throws -> CapturedScreen {
        let x = calls.withLock { count in count += 1; return CGFloat(count * 500) }
        return CapturedScreen(png: image, app: "Editor", frame: captureGeometry(x).frame)
    }
}

private final class GuidancePresenter: AnnotationPresenting, @unchecked Sendable {
    private let frames = OSAllocatedUnfairLock(initialState: [CGRect]())
    var all: [CGRect] { frames.withLock { $0 } }
    func show(_ rect: CGRect, label: String) async { frames.withLock { $0.append(rect) } }
}

@Suite("Screen guidance - screenshot identity and model context")
struct ScreenGuidanceTests {
    @Test("coordinates select the requested image, not the last attached image")
    func selectsCapture() async throws {
        let relay = ScreenGeometryRelay()
        let first = UUID(), second = UUID()
        relay.record([first: captureGeometry(-500), second: captureGeometry(500)])
        #expect(relay.current == nil)
        #expect(throws: ToolError.self) { try relay.resolve(screenshotID: nil) }
        #expect(throws: ToolError.self) { try relay.resolve(screenshotID: UUID().uuidString) }
        #expect(throws: ToolError.self) { try relay.resolve(screenshotID: "not-an-id") }
        let presenter = GuidancePresenter()
        let tool = PointAtTool(geometry: relay, presenter: presenter, mainDisplayHeight: { 900 })
        var args: [String: AnyCodable] = ["x": 40, "y": 60, "width": 80, "height": 40, "label": "Save"]
        #expect(throws: ToolError.self) { try tool.validate(arguments: args) }
        args["screenshot_id"] = AnyCodable(first.uuidString)
        try tool.validate(arguments: args)
        #expect(try await tool.execute(arguments: args).isError == false)
        #expect(presenter.all == [CGRect(x: -480, y: 800, width: 40, height: 20)])
        args["screenshot_id"] = AnyCodable(second.uuidString)
        #expect(try await tool.execute(arguments: args).isError == false)
        #expect(presenter.all.last?.minX == 520)
        args["x"] = 5000
        #expect(try await tool.execute(arguments: args).isError)
        relay.record([:])
        #expect(throws: ToolError.self) { try tool.validate(arguments: args) }
    }

    @Test("single-capture calls remain compatible; replacing a batch rejects old IDs")
    func replacesMappings() throws {
        let relay = ScreenGeometryRelay()
        relay.record(captureGeometry())
        #expect(try relay.resolve(screenshotID: nil) == captureGeometry())
        relay.record(nil)
        #expect(relay.current == nil)
        #expect(throws: ToolError.self) { try relay.resolve(screenshotID: nil) }
        let old = UUID(), new = UUID()
        relay.record([old: captureGeometry()])
        relay.record([new: captureGeometry(300)])
        #expect(throws: ToolError.self) { try relay.resolve(screenshotID: old.uuidString) }
        #expect(try relay.resolve(screenshotID: new.uuidString) == captureGeometry(300))
    }

    @MainActor
    @Test("sending keeps every eligible image mapping; files and OCR-only frames clear stale mappings")
    func trayBatch() async throws {
        let relay = ScreenGeometryRelay()
        let tray = AttachmentTray(capturer: GuidanceCapturer(image: try captureImage()),
                                  pipeline: VisionPipeline(recognizer: GuidanceNoText()), geometry: relay)
        let first = try #require(await tray.capture(.frontWindow))
        let second = try #require(await tray.capture(.display))
        #expect(relay.current == nil, "attaching does not send")
        #expect(tray.take().count == 2)
        #expect(try relay.resolve(screenshotID: first.id.uuidString) == first.geometry)
        #expect(try relay.resolve(screenshotID: second.id.uuidString) == second.geometry)
        tray.markShown(ImageAttachment(source: .image(filename: "old.png"), jpeg: [try captureImage()], text: nil))
        #expect(throws: ToolError.self) { try relay.resolve(screenshotID: second.id.uuidString) }
        tray.markShown(first)
        #expect(relay.current == first.geometry)
        tray.markShown(ImageAttachment(source: .screenshot(app: nil), jpeg: [], text: "Export", geometry: first.geometry))
        #expect(relay.current == nil)
        #expect(tray.take().isEmpty)
    }

    @Test("model metadata carries actual dimensions and eligibility without desktop coordinates")
    func metadata() async throws {
        let pipeline = VisionPipeline(recognizer: GuidanceNoText())
        let shot = try await pipeline.prepareImage(captureImage(), source: .screenshot(app: "Editor"),
                                                   policy: VisionPolicy(), frame: captureGeometry(-500).frame)
        #expect(shot.canPointOnScreen)
        #expect(shot.modelContext.contains("screenshot_id=\(shot.id.uuidString)"))
        #expect(shot.modelContext.contains("800x600 pixels"))
        #expect(shot.modelContext.contains("on-screen pointing available"))
        #expect(!shot.modelContext.contains("-500"))
        let file = try await pipeline.prepareImage(captureImage(), source: .image(filename: "old\nimage.png"), policy: VisionPolicy())
        #expect(!file.canPointOnScreen)
        #expect(file.modelContext.contains("800x600 pixels"))
        #expect(file.modelContext.contains("on-screen pointing unavailable"))
        #expect(file.modelContext.contains("\\n"))
        let text = ImageAttachment(source: .pdf(filename: "a.pdf", pages: 1), jpeg: [], text: "Export")
        #expect(text.modelContext.contains("no image pixels"))
        let invalid = ImageAttachment(source: .screenshot(app: nil), jpeg: [Data()], text: nil,
                                      geometry: CaptureGeometry(frame: .zero, imageSize: CGSize(width: CGFloat.nan, height: 0)))
        #expect(!invalid.canPointOnScreen)
        #expect(invalid.modelContext.contains("unavailable"))
    }

    @Test("Live frame metadata stays with the JPEG payload; audio messages carry no image context")
    func livePayload() throws {
        let frame = BidiRealtimeInput(jpegFrame: Data([1, 2]), context: "screenshot_id=frame; 800x600 pixels")
        let decoded = try JSONDecoder().decode(BidiRealtimeInput.self, from: JSONEncoder().encode(frame))
        #expect(decoded.video?.data == Data([1, 2]).base64EncodedString())
        #expect(decoded.text == frame.text)
        #expect(decoded.audio == nil && decoded.audioStreamEnd == nil)
        #expect(BidiRealtimeInput(pcmData: Data([0, 0])).text == nil)
        #expect(BidiRealtimeInput(mediaChunks: []).text == nil)
        #expect(BidiRealtimeInput(audioStreamEnd: true).text == nil)
    }

    @Test("arrow animates from the screen edge and keeps its arrowhead attached, with bounded progress")
    func arrowEntrance() throws {
        let geometry = try #require(AnnotationGeometry(screen: CGRect(x: -800, y: 0, width: 800, height: 600),
                                                       target: CGRect(x: -600, y: 200, width: 180, height: 100)))
        #expect(geometry.arrow(at: 0).tip == geometry.start)
        #expect(geometry.arrow(at: 1).tip == geometry.end)
        #expect(geometry.arrow(at: 1).headA == geometry.headA)
        #expect(geometry.arrow(at: 1).headB == geometry.headB)
        let halfway = geometry.arrow(at: 0.5)
        #expect(halfway.tip.x == (geometry.start.x + geometry.end.x) / 2)
        #expect(halfway.tip.y == (geometry.start.y + geometry.end.y) / 2)
        #expect(halfway.headA.x - halfway.tip.x == geometry.headA.x - geometry.end.x)
        #expect(geometry.arrow(at: -1).tip == geometry.start)
        #expect(geometry.arrow(at: 2).tip == geometry.end)
        #expect(geometry.arrow(at: .nan).tip == geometry.start)
    }
}

private final class RecoverableCapturer: ScreenContextCapturing, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (error: Error?.none, targets: [CaptureTarget]()))
    let image: Data
    init(image: Data) { self.image = image }
    var targets: [CaptureTarget] { state.withLock { $0.targets } }
    func fail(with error: Error?) { state.withLock { $0.error = error } }
    func frontmostOtherApp() async -> String? { "Editor" }
    func capture(_ target: CaptureTarget) async throws -> CapturedScreen {
        let error = state.withLock { s -> Error? in s.targets.append(target); return s.error }
        if let error { throw error }
        return CapturedScreen(png: image, app: "Editor", frame: captureGeometry().frame)
    }
}

@Suite("Screen guidance - capture permission recovery")
struct CaptureRecoveryTests {
    @MainActor
    @Test("denial explains permission and offers explicit retry without sending anything")
    func permissionRetry() async throws {
        let capturer = RecoverableCapturer(image: try captureImage())
        let declined = NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        capturer.fail(with: declined)
        let relay = ScreenGeometryRelay()
        let tray = AttachmentTray(capturer: capturer, pipeline: VisionPipeline(recognizer: GuidanceNoText()), geometry: relay)
        #expect(await tray.retryCapture() == nil)
        #expect(await tray.capture(.display) == nil)
        #expect(tray.needsScreenPermission && tray.canRetryCapture)
        #expect(tray.lastError == VisionError.screenPermissionDenied.localizedDescription)
        #expect(!tray.lastError!.contains("TCC"))
        #expect(tray.attachments.isEmpty && relay.current == nil)
        #expect(capturer.targets == [.display])
        capturer.fail(with: nil)
        #expect(await tray.retryCapture() != nil)
        #expect(capturer.targets == [.display, .display])
        #expect(!tray.needsScreenPermission && !tray.canRetryCapture && tray.lastError == nil)
        #expect(tray.attachments.count == 1 && relay.current == nil, "retry attaches but never sends")
        #expect(await tray.retryCapture() == nil)
    }

    @MainActor
    @Test("unrelated errors keep their meaning; dismiss and cancellation remove retry state")
    func errorKinds() async throws {
        let capturer = RecoverableCapturer(image: try captureImage())
        let error = VisionError.captureFailed("window closed")
        #expect(SystemScreenContext.userFacingError(error) as? VisionError == error)
        let unrelated = NSError(domain: "OtherFramework", code: SCStreamError.Code.userDeclined.rawValue)
        #expect((SystemScreenContext.userFacingError(unrelated) as NSError).domain == "OtherFramework")
        capturer.fail(with: error)
        let tray = AttachmentTray(capturer: capturer, pipeline: VisionPipeline(recognizer: GuidanceNoText()))
        #expect(await tray.capture(.frontWindow) == nil)
        #expect(!tray.needsScreenPermission && tray.canRetryCapture)
        #expect(tray.lastError == error.localizedDescription)
        tray.dismissError()
        #expect(!tray.canRetryCapture && tray.lastError == nil)
        capturer.fail(with: VisionError.cancelled)
        #expect(await tray.capture(.region) == nil)
        #expect(!tray.canRetryCapture && !tray.needsScreenPermission && tray.lastError == nil)
        tray.clear()
    }
}
