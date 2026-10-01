import Testing
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import os
@testable import IvyCore

// MARK: - Fixtures (images are drawn in memory; nothing here captures the real screen)

private func solidImage(width: Int, height: Int, gray: CGFloat = 1) -> CGImage {
    let context = ImageProcessing.rgbContext(width: width, height: height)!
    context.setFillColor(CGColor(gray: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

private func png(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// Brightness (0…255) of the pixel at a normalized point (origin bottom-left, like Vision).
private func brightness(of jpeg: Data, at point: CGPoint) -> Int {
    let image = ImageProcessing.decode(jpeg)!
    let context = ImageProcessing.rgbContext(width: 1, height: 1)!
    let x = point.x * CGFloat(image.width), y = point.y * CGFloat(image.height)
    context.draw(image, in: CGRect(x: -x, y: -y, width: CGFloat(image.width), height: CGFloat(image.height)))
    let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
    return (Int(pixels[0]) + Int(pixels[1]) + Int(pixels[2])) / 3
}

private struct ScriptedRecognizer: TextRecognizing {
    var lines: [RecognizedText] = []
    func recognize(_ image: Data) async throws -> [RecognizedText] { lines }
}

private let fakeKey = "AIza" + String(repeating: "k", count: 35)

private final class FakeCapturer: ScreenContextCapturing, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (front: String?.none, shotApp: String?.none, captures: 0, cancel: false))
    init(front: String? = "Xcode", shotApp: String? = "Xcode", cancel: Bool = false) {
        state.withLock { $0 = (front, shotApp, 0, cancel) }
    }
    var captures: Int { state.withLock { $0.captures } }
    func frontmostOtherApp() async -> String? { state.withLock { $0.front } }
    func capture(_ target: CaptureTarget) async throws -> CapturedScreen {
        let (app, cancel) = state.withLock { s -> (String?, Bool) in
            s.captures += 1
            return (s.shotApp, s.cancel)
        }
        if cancel { throw VisionError.cancelled }
        return CapturedScreen(png: png(solidImage(width: 800, height: 600)), app: app)
    }
}

// MARK: - Image processing

@Suite("Phase 14 - Image processing")
struct Phase14ImageTests {
    @Test("large images are downscaled to a 2048 px long edge and stay under 4 MB; small ones are never upscaled")
    func downscale() throws {
        let jpeg = try ImageProcessing.jpeg(solidImage(width: 4000, height: 1000))
        let decoded = try #require(ImageProcessing.decode(jpeg))
        #expect(decoded.width == 2048 && decoded.height == 512)
        #expect(jpeg.count <= ImageProcessing.maxBytes)
        let small = try #require(ImageProcessing.decode(try ImageProcessing.jpeg(solidImage(width: 300, height: 200))))
        #expect(small.width == 300 && small.height == 200)
    }

    @Test("re-encoding strips EXIF and GPS")
    func metadataStripped() throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        let gps: [CFString: Any] = [kCGImagePropertyGPSLatitude: 30.3, kCGImagePropertyGPSLatitudeRef: "N",
                                     kCGImagePropertyGPSLongitude: 78.0, kCGImagePropertyGPSLongitudeRef: "E"]
        let exif: [CFString: Any] = [kCGImagePropertyExifUserComment: "taken at home"]
        CGImageDestinationAddImage(destination, solidImage(width: 400, height: 300),
                                   [kCGImagePropertyGPSDictionary: gps, kCGImagePropertyExifDictionary: exif] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        func properties(_ jpeg: Data) -> [CFString: Any] {
            let source = CGImageSourceCreateWithData(jpeg as CFData, nil)!
            return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        }
        #expect(properties(data as Data)[kCGImagePropertyGPSDictionary] != nil, "the fixture really has GPS")

        let clean = try ImageProcessing.jpeg(try #require(ImageProcessing.decode(data as Data)))
        #expect(properties(clean)[kCGImagePropertyGPSDictionary] == nil)
        let exifOut = properties(clean)[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exifOut?[kCGImagePropertyExifUserComment] == nil)
    }

    @Test("masking blacks out exactly the given regions")
    func masking() throws {
        let masked = ImageProcessing.masked(solidImage(width: 400, height: 400), regions: [CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)])
        let jpeg = try ImageProcessing.jpeg(masked)
        #expect(brightness(of: jpeg, at: CGPoint(x: 0.5, y: 0.5)) < 30)
        #expect(brightness(of: jpeg, at: CGPoint(x: 0.05, y: 0.05)) > 225)
    }
}

// MARK: - Pipeline

@Suite("Phase 14 - Vision pipeline")
struct Phase14PipelineTests {
    private let screenshot = png(solidImage(width: 1000, height: 800))
    private let lines = [
        RecognizedText(text: "error: cannot find 'foo' in scope", box: CGRect(x: 0.1, y: 0.8, width: 0.6, height: 0.05)),
        RecognizedText(text: "export GEMINI_API_KEY=\(fakeKey)", box: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.1)),
    ]

    @Test("key-looking text is blacked out in the image and redacted in the text; the rest is kept")
    func masksSecrets() async throws {
        let pipeline = VisionPipeline(recognizer: ScriptedRecognizer(lines: lines))
        let attachment = try await pipeline.prepareImage(screenshot, source: .screenshot(app: "Terminal"), policy: VisionPolicy())
        #expect(attachment.maskedRegions == 1)
        #expect(attachment.text?.contains("cannot find 'foo'") == true)
        #expect(attachment.text?.contains(fakeKey) == false)
        let jpeg = try #require(attachment.jpeg.first)
        #expect(brightness(of: jpeg, at: CGPoint(x: 0.5, y: 0.35)) < 30, "the key's box is black")
        #expect(brightness(of: jpeg, at: CGPoint(x: 0.5, y: 0.6)) > 225, "the rest of the screen isn't")
    }

    @Test("masking can be turned off; text-only mode sends no pixels at all")
    func policies() async throws {
        let pipeline = VisionPipeline(recognizer: ScriptedRecognizer(lines: lines))
        let unmasked = try await pipeline.prepareImage(screenshot, source: .screenshot(app: nil), policy: VisionPolicy(maskSecrets: false))
        #expect(unmasked.maskedRegions == 0)

        let textOnly = try await pipeline.prepareImage(screenshot, source: .screenshot(app: nil), policy: VisionPolicy(textOnly: true))
        #expect(textOnly.jpeg.isEmpty)
        #expect(textOnly.text?.contains("cannot find") == true)

        await #expect(throws: VisionError.nothingToSend) {
            _ = try await VisionPipeline(recognizer: ScriptedRecognizer()).prepareImage(screenshot, source: .screenshot(app: nil), policy: VisionPolicy(textOnly: true))
        }
        await #expect(throws: VisionError.unreadableImage) {
            _ = try await pipeline.prepareImage(Data("not an image".utf8), source: .image(filename: "x"), policy: VisionPolicy())
        }
    }

    @Test("history keeps a placeholder, never pixels; text only when the user allowed it")
    func placeholders() {
        let plain = ImageAttachment(source: .screenshot(app: "Xcode"), jpeg: [Data([1, 2, 3])], text: "Build failed")
        #expect(plain.placeholder == "[screenshot of Xcode — not saved]")
        let kept = ImageAttachment(source: .pdf(filename: "q3.pdf", pages: 12), jpeg: [], text: "Revenue up", keepTextInHistory: true)
        #expect(kept.placeholder == "[q3.pdf (12 pages) — not saved]\nText from it: Revenue up")
    }

    private func makePDF(pages: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for text in pages {
            context.beginPDFPage(nil)
            if !text.isEmpty {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): font]))
                context.textPosition = CGPoint(x: 72, y: 700)
                CTLineDraw(line, context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    @Test("PDFs: text per page; nearly empty pages are treated as scans and rendered (not in text-only mode)")
    func pdf() async throws {
        let pdf = makePDF(pages: ["Quarterly revenue grew twelve percent in the third quarter.", "", "Costs fell slightly across every region we track."])
        let pipeline = VisionPipeline(recognizer: ScriptedRecognizer())
        let attachment = try await pipeline.preparePDF(pdf, filename: "q3.pdf", policy: VisionPolicy())
        #expect(attachment.source == .pdf(filename: "q3.pdf", pages: 3))
        let text = try #require(attachment.text)
        #expect(text.contains("--- Page 1 ---") && text.contains("Quarterly revenue"))
        #expect(text.contains("--- Page 3 ---") && text.contains("Costs fell"))
        #expect(attachment.jpeg.count == 1, "the blank page is rendered as an image")

        let textOnly = try await pipeline.preparePDF(pdf, filename: "q3.pdf", policy: VisionPolicy(textOnly: true))
        #expect(textOnly.jpeg.isEmpty)
        await #expect(throws: VisionError.pdfUnreadable) {
            _ = try await pipeline.preparePDF(Data("nope".utf8), filename: "x.pdf", policy: VisionPolicy())
        }
    }

    @Test("files: images and PDFs only")
    func files() async throws {
        let dir = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let image = dir.appendingPathComponent("photo.png")
        try screenshot.write(to: image)
        let text = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)
        let pipeline = VisionPipeline(recognizer: ScriptedRecognizer())
        let attachment = try await pipeline.prepareFile(image, policy: VisionPolicy())
        #expect(attachment.source == .image(filename: "photo.png"))
        await #expect(throws: VisionError.unsupportedFile("notes.txt")) {
            _ = try await pipeline.prepareFile(text, policy: VisionPolicy())
        }
    }
}

// MARK: - Tray, exclusion list, screen help

@MainActor
@Suite("Phase 14 - Attachment tray and screen help")
struct Phase14TrayTests {
    private func tray(_ capturer: FakeCapturer, policy: VisionPolicy = VisionPolicy()) -> AttachmentTray {
        AttachmentTray(capturer: capturer, pipeline: VisionPipeline(recognizer: ScriptedRecognizer()), policy: { policy })
    }

    @Test("an excluded app in front blocks the capture before it happens")
    func exclusion() async {
        let capturer = FakeCapturer(front: "1password")
        let t = tray(capturer)
        #expect(await t.capture(.frontWindow) == nil)
        #expect(capturer.captures == 0)
        #expect(t.lastError?.contains("excluded") == true)
        #expect(VisionPolicy().isExcluded(app: "Bitwarden"))
        #expect(!VisionPolicy().isExcluded(app: "Xcode"))
    }

    @Test("a region that turns out to be an excluded app's window is dropped")
    func excludedPick() async {
        let t = tray(FakeCapturer(front: "Xcode", shotApp: "Keychain Access"))
        #expect(await t.capture(.region) == nil)
        #expect(t.attachments.isEmpty)
    }

    @Test("captures are attached, counted and labelled; Esc in the selector is not an error")
    func captures() async throws {
        let t = tray(FakeCapturer())
        let attachment = try #require(await t.capture(.frontWindow))
        #expect(attachment.label == "screenshot of Xcode")
        #expect(t.attachments.count == 1 && t.captureCount == 1)
        #expect(t.take().count == 1 && t.attachments.isEmpty)

        let cancelled = tray(FakeCapturer(cancel: true))
        #expect(await cancelled.capture(.region) == nil)
        #expect(cancelled.lastError == nil)
    }

    @Test("at most five attachments per message")
    func limit() async {
        let t = tray(FakeCapturer())
        for _ in 0..<6 { await t.capture(.display) }
        #expect(t.attachments.count == AttachmentTray.maxAttachments)
        #expect(t.lastError != nil)
    }

    @Test("screen help attaches the front window and pre-fills the question; during Live the frame goes to Live")
    func screenHelp() async throws {
        let capturer = FakeCapturer()
        let session = MockGeminiLiveSession()
        var opened = 0
        let env = IvyAppEnvironment(
            settingsStore: InMemorySettingsStore(), credentials: FixedCredentialProvider([.geminiAPIKey: "k"]),
            conversationStore: InMemoryConversationStore(), geminiClient: RecordingGeminiClient(),
            wakeWordListener: Phase14SilentListener(), screenCapturer: capturer,
            visionPipeline: VisionPipeline(recognizer: ScriptedRecognizer())
        ) { _, _ in
            GeminiLiveVoiceCoordinator(session: session, audioCapture: MockAudioCapture(), audioPlayer: MockLiveAudioPlayer(),
                                       wakeWordDetector: MockWakeWordDetector())
        }
        env.onScreenHelp = { opened += 1 }

        await env.handleScreenHelp()
        #expect(env.attachments.attachments.count == 1)
        #expect(env.attachments.suggestedPrompt == "What am I looking at?")
        #expect(opened == 1)
        #expect(env.brain.messages.isEmpty, "nothing is sent until the user presses Return")

        env.attachments.clear()
        await env.liveCoordinator.startSession()
        await env.handleScreenHelp()
        #expect(session.sentImages.count == 1)
        #expect(env.attachments.attachments.isEmpty)
        #expect(opened == 1)
        await env.liveCoordinator.stopSession()
    }

    @Test("the screen-help shortcut doesn't collide with push-to-talk or Save As")
    func shortcut() {
        #expect(HotkeyShortcut.defaultScreenHelp != HotkeyShortcut.defaultPushToTalk)
        #expect(HotkeyShortcut.defaultScreenHelp.modifiers == [.control, .option, .command])
    }

    @Test("vision settings: safe defaults, persisted")
    func settings() throws {
        let d = IvySettings.defaults
        #expect(d.visionMaskSecrets && !d.visionTextOnly && !d.visionKeepTextFromImages && d.screenHelpHotkeyEnabled)
        #expect(d.visionExcludedApps.contains("1Password"))
        var s = d
        s.visionTextOnly = true
        s.visionExcludedApps = ["Banking"]
        let decoded = try JSONDecoder().decode(IvySettings.self, from: JSONEncoder().encode(s))
        #expect(decoded.visionPolicy == VisionPolicy(textOnly: true, excludedApps: ["Banking"]))
    }
}

// MARK: - Requests, history, Live

/// Records the history of every request.
private final class HistoryRecordingClient: GeminiClientProtocol, @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [[ChatMessage]]())
    var histories: [[ChatMessage]] { state.withLock { $0 } }
    func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
    func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
        state.withLock { $0.append(history) }
        return ModelTurnResponse(text: "It's a build error.")
    }
}

/// Captures request bodies for this suite only (the shared stub's global handler races other suites).
private final class Phase14URLProtocol: URLProtocol, @unchecked Sendable {
    static let bodies = OSAllocatedUnfairLock(initialState: [Data]())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.bodies.withLock { $0.append(request.extractBodyData() ?? Data()) }
        let body = #"{"candidates":[{"content":{"role":"model","parts":[{"text":"A build error."}]}}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Phase 14 - Requests, history and Live", .serialized)
struct Phase14RequestTests {
    private let attachment = ImageAttachment(source: .screenshot(app: "Xcode"), jpeg: [Data([0xFF, 0xD8, 0xFF, 0xD9])], text: "error: missing return")

    @Test("the image goes inline as JPEG with its recognised text, alongside the question")
    func wire() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Phase14URLProtocol.self]
        let client = URLSessionGeminiClient(session: URLSession(configuration: config), thinkingLevel: nil)
        Phase14URLProtocol.bodies.withLock { $0 = [] }
        _ = try await client.generateContent(
            history: [ChatMessage(role: .user, text: "What's wrong?", attachments: [attachment])],
            systemPrompt: "p", tools: nil, apiKey: "k")
        let body = try #require(Phase14URLProtocol.bodies.withLock { $0.first })
        let request = try JSONDecoder().decode(GeminiRequest.self, from: body)
        let parts = try #require(request.contents.first?.parts)
        #expect(parts.first?.text == "What's wrong?")
        #expect(parts.contains { $0.inlineData == InlineData(mimeType: "image/jpeg", data: Data([0xFF, 0xD8, 0xFF, 0xD9])) })
        #expect(parts.contains { $0.text?.contains("Text recognised in the screenshot of Xcode:\nerror: missing return") == true })
    }

    @MainActor
    @Test("pixels travel once: later turns carry the placeholder; saved history never holds the image")
    func onceOnly() async throws {
        let client = HistoryRecordingClient()
        let store = InMemoryConversationStore()
        let brain = IvyBrain(client: client, apiKey: "k", conversationStore: store)
        await brain.send("What's wrong?", attachments: [attachment])
        await brain.send("And how do I fix it?")

        let first = try #require(client.histories.first?.last)
        #expect(first.attachments == [attachment])
        let second = try #require(client.histories.last)
        #expect(second.allSatisfy { $0.attachments.isEmpty })
        #expect(second.first?.text.contains("[screenshot of Xcode — not saved]") == true)

        let saved = try #require(store.all.first)
        let encoded = String(decoding: try JSONEncoder().encode(saved), as: UTF8.self)
        #expect(encoded.contains("screenshot of Xcode"))
        #expect(!encoded.contains(Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()))
        #expect(!encoded.contains("missing return"), "OCR text is kept only when the user allows it")
    }

    @Test("an attachment alone (no typed text) can be sent; ChatMessage never encodes attachments")
    @MainActor
    func attachmentOnly() async throws {
        let client = HistoryRecordingClient()
        let brain = IvyBrain(client: client, apiKey: "k")
        await brain.send("", attachments: [attachment])
        #expect(client.histories.count == 1)
        let encoded = String(decoding: try JSONEncoder().encode(brain.messages[0]), as: UTF8.self)
        #expect(!encoded.contains("attachments"))
    }

    @Test("Live: one JPEG frame as realtime video, never alongside audio")
    func liveFrameSchema() throws {
        let encoded = try JSONEncoder().encode(BidiClientMessage(realtimeInput: BidiRealtimeInput(jpegFrame: Data([1, 2]))))
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let realtime = try #require(json["realtimeInput"] as? [String: Any])
        #expect(Set(realtime.keys) == ["video"])
        #expect((realtime["video"] as? [String: Any])?["mimeType"] as? String == "image/jpeg")
    }

    @MainActor
    @Test("Live: a frame is sent only while a session is live")
    func liveSend() async {
        let session = MockGeminiLiveSession()
        let coordinator = GeminiLiveVoiceCoordinator(session: session, audioCapture: MockAudioCapture(), audioPlayer: MockLiveAudioPlayer(),
                                                     wakeWordDetector: MockWakeWordDetector())
        #expect(await coordinator.sendImage(Data([1])) == false)
        await coordinator.startSession()
        #expect(await coordinator.sendImage(Data([1])) == true)
        #expect(session.sentImages == [Data([1])])
        await coordinator.stopSession()
    }
}

private final class Phase14SilentListener: WakeWordListening, @unchecked Sendable {
    func start(onWake: @escaping @Sendable () -> Void) async throws {}
    func stop() async {}
}
