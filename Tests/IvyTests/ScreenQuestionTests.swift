import Testing
import Foundation
import AppKit
import os
@testable import IvyCore

@Suite("Screen question geometry")
struct ScreenQuestionGeometryTests {
    @Test func transformsAndBounds() throws {
        let screen = CGRect(x: -1500, y: -200, width: 1500, height: 1000)
        let selection = try #require(ScreenRegionSelection(displayID: 4, screen: screen, rect: CGRect(x: -1200, y: 300, width: 200, height: 100)))
        #expect(selection.sourceRect == CGRect(x: 300, y: 400, width: 200, height: 100))
        #expect(selection.pixelSize(atScale: 2) == CGSize(width: 400, height: 200))
        #expect(selection.pixelSize(atScale: 100) == CGSize(width: 2048, height: 1024))
        #expect(selection.pixelSize(atScale: .nan) == nil && selection.pixelSize(atScale: 0) == nil)
        #expect(ScreenRegionSelection(displayID: 1, screen: screen, rect: .zero) == nil)
        #expect(ScreenRegionSelection(displayID: 1, screen: screen, rect: CGRect(x: 0, y: 0, width: 100, height: 100)) == nil)
        #expect(ScreenRegionSelection(displayID: 1, screen: screen, rect: CGRect(x: -.infinity, y: 0, width: 100, height: 100)) == nil)
        #expect(ScreenRegionSelection(displayID: 1, screen: CGRect(x: 0, y: 0, width: 30_000, height: 1000), rect: CGRect(x: 0, y: 0, width: 50, height: 50)) == nil)
    }
    @Test func freehandRectangleAndHover() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var gesture = ScreenSelectionGesture()
        gesture.move(CGPoint(x: 999, y: 2))
        #expect(gesture.crop(in: screen) == CGRect(x: 760, y: 0, width: 240, height: 180))
        gesture.move(CGPoint(x: CGFloat.nan, y: 3))
        #expect(gesture.hover == CGPoint(x: 999, y: 2))
        gesture.drag(.zero)
        #expect(gesture.points.isEmpty)
        gesture.begin(CGPoint(x: 100, y: 100))
        gesture.drag(CGPoint(x: 50, y: 140)); gesture.drag(CGPoint(x: 150, y: 200))
        #expect(gesture.crop(in: screen) == CGRect(x: 50, y: 100, width: 100, height: 100))
        for n in 0..<2000 { gesture.drag(CGPoint(x: n % 100, y: n % 300)) }
        #expect(gesture.points.count == 1024)
        gesture.mode = .rectangle; gesture.begin(CGPoint(x: 300, y: 300))
        gesture.drag(CGPoint(x: 350, y: 400)); gesture.drag(CGPoint(x: 200, y: 100))
        #expect(gesture.points.count == 2 && gesture.crop(in: screen) == CGRect(x: 200, y: 100, width: 100, height: 200))
        gesture.begin(CGPoint(x: CGFloat.nan, y: 0)); #expect(gesture.points.isEmpty)
        gesture.begin(.zero); gesture.drag(CGPoint(x: 3, y: 3))
        #expect(gesture.crop(in: screen).size == CGSize(width: 240, height: 180))
        #expect(gesture.crop(in: CGRect(x: 0, y: 0, width: 100, height: 100)).size == CGSize(width: 100, height: 100))
    }
    @Test func shortcutMigration() throws {
        let old = try JSONDecoder().decode(IvySettings.self, from: Data("{}".utf8))
        #expect(old.screenQuestionEnabled && old.screenQuestionShortcut == .pushToTalk)
        for shortcut in ScreenQuestionShortcut.allCases {
            var settings = old; settings.screenQuestionEnabled = false; settings.screenQuestionShortcut = shortcut
            #expect(try JSONDecoder().decode(IvySettings.self, from: JSONEncoder().encode(settings)) == settings)
            #expect(!shortcut.label.isEmpty)
            #expect(shortcut.hotkey != .defaultScreenHelp && shortcut.hotkey != .defaultCommandBar)
        }
        #expect(ScreenQuestionShortcut.pushToTalk.hotkey == .defaultPushToTalk)
        #expect(ScreenQuestionShortcut.region.hotkey.keyCode == 15 && ScreenQuestionShortcut.area.hotkey.keyCode == 0)
    }
}

private struct RegionRecognizer: TextRecognizing {
    func recognize(_ image: Data) async throws -> [RecognizedText] { [] }
}
private struct RegionCapture: ScreenContextCapturing, SelectedRegionCapturing {
    var app = "TextEdit"
    var error: VisionError?
    var delay: Duration = .zero
    let calls = OSAllocatedUnfairLock(initialState: [[String]]())
    func frontmostOtherApp() async -> String? { app }
    func capture(_ target: CaptureTarget) async throws -> CapturedScreen { throw VisionError.cancelled }
    func capture(selection: ScreenRegionSelection, excludedApps: [String]) async throws -> CapturedScreen {
        calls.withLock { $0.append(excludedApps) }
        if delay != .zero { try await Task.sleep(for: delay) }
        if let error { throw error }
        let context = ImageProcessing.rgbContext(width: 240, height: 180)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 240, height: 180))
        let bytes = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
        return CapturedScreen(png: bytes, app: app, frame: selection.sourceRect)
    }
}

@Suite("Selected-area privacy and staging") @MainActor
struct SelectedAreaTrayTests {
    let selection = ScreenRegionSelection(displayID: 1, screen: CGRect(x: 0, y: 0, width: 1000, height: 800), rect: CGRect(x: 100, y: 200, width: 240, height: 180))!
    @Test func stagingAndGeometry() async throws {
        let capture = RegionCapture()
        let tray = AttachmentTray(capturer: capture, pipeline: VisionPipeline(recognizer: RegionRecognizer()))
        let attachment = try #require(await tray.capture(selection: selection))
        #expect(attachment.canPointOnScreen && attachment.geometry?.frame == selection.sourceRect)
        #expect(tray.attachments == [attachment] && tray.captureCount == 1)
        #expect(capture.calls.withLock { $0.first } == VisionPolicy.defaultExcludedApps)
        tray.clear()
        let voice = await tray.capture(selection: selection, stage: false)
        #expect(voice != nil && tray.attachments.isEmpty)
        tray.reportCaptureError("Fixture failure")
        #expect(tray.lastError == "Fixture failure" && !tray.canRetryCapture)
    }
    @Test func exclusionPermissionAndCancellation() async {
        let denied = RegionCapture(app: "Passwords")
        let tray = AttachmentTray(capturer: denied)
        #expect(await tray.capture(selection: selection) == nil)
        #expect(denied.calls.withLock { $0.isEmpty })
        let permission = AttachmentTray(capturer: RegionCapture(error: .screenPermissionDenied))
        #expect(await permission.capture(selection: selection) == nil)
        #expect(permission.needsScreenPermission && !permission.canRetryCapture)
        let cancelled = AttachmentTray(capturer: RegionCapture(delay: .milliseconds(100)))
        let task = Task { await cancelled.capture(selection: selection) }
        await Task.yield(); task.cancel()
        #expect(await task.value == nil && cancelled.attachments.isEmpty && cancelled.lastError == nil)
    }
}

/// Records protocol order without network, microphone hardware, or user screen capture.
private final class OrderedSpatialSession: GeminiLiveSession, Sendable {
    let inner = MockGeminiLiveSession()
    let events = OSAllocatedUnfairLock(initialState: [String]())
    var order: [String] { events.withLock { $0 } }
    func connect() async throws { try await inner.connect() }
    func disconnect() async { await inner.disconnect() }
    func receiveEvents() -> AsyncThrowingStream<LiveEvent, Error> { inner.receiveEvents() }
    func sendAudio(_ data: Data) async throws { events.withLock { $0.append("audio") }; try await inner.sendAudio(data) }
    func endAudioInput() async throws { events.withLock { $0.append("end") }; try await inner.endAudioInput() }
    func sendImage(_ jpeg: Data, context: String) async throws { events.withLock { $0.append("image") }; try await inner.sendImage(jpeg, context: context) }
    func sendToolResponses(_ responses: [FunctionResponse]) async throws { try await inner.sendToolResponses(responses) }
}

@Suite("One-key spatial voice requests") @MainActor
struct SpatialVoiceTests {
    private var loud: Data { (0..<1600).map { Int16($0 % 2 == 0 ? 6000 : -6000) }.withUnsafeBytes { Data($0) } }
    private func make() -> (GeminiLiveVoiceCoordinator, OrderedSpatialSession, MockAudioCapture) {
        let session = OrderedSpatialSession(), capture = MockAudioCapture()
        return (GeminiLiveVoiceCoordinator(session: session, audioCapture: capture,
            audioPlayer: MockLiveAudioPlayer(), wakeWordDetector: MockWakeWordDetector()), session, capture)
    }
    @Test func cropBeforeSpeechAndMicClosed() async {
        let (voice, session, mic) = make()
        let attachment = ImageAttachment(source: .screenshot(app: "TextEdit"), jpeg: [Data([1, 2, 3])], text: nil)
        voice.onPushToTalkContextBegin = { .screen }
        var shown = false
        voice.onPushToTalkContextRelease = {
            #expect(!mic.isCapturing)
            #expect(session.order.isEmpty)
            return attachment
        }
        voice.onPushToTalkContextShown = { shown = $0.id == attachment.id }
        await voice.beginPushToTalk()
        mic.simulateAudioChunk(loud); mic.simulateAudioChunk(loud)
        await voice.endPushToTalk()
        #expect(session.order.first == "image" && session.order.last == "end")
        #expect(session.inner.sentAudioChunks.reduce(Data(), +) == loud + loud)
        #expect(shown && !mic.isCapturing && !voice.isPushToTalkActive && voice.state == .thinking)
        await voice.stopSession(); #expect(voice.activeTaskCount == 0)
    }
    @Test func failedCropAndSilentPressSendNothing() async {
        for speaks in [true, false] {
            let (voice, session, mic) = make()
            voice.onPushToTalkContextBegin = { .screen }
            voice.onPushToTalkContextRelease = { nil }
            var cancelled = false; voice.onPushToTalkContextCancel = { cancelled = true }
            await voice.beginPushToTalk()
            if speaks { mic.simulateAudioChunk(loud) }
            await voice.endPushToTalk()
            #expect(session.order.isEmpty && !mic.isCapturing && cancelled)
            #expect(voice.state.isLive == false && voice.activeTaskCount == 0)
            await voice.stopSession()
        }
    }
    @Test func cancelBeforeStartAndBoundedAudio() async {
        let (voice, session, mic) = make()
        voice.onPushToTalkContextBegin = { .cancel }
        await voice.beginPushToTalk()
        #expect(!mic.isCapturing && voice.state == .idle)
        voice.onPushToTalkContextBegin = { .screen }
        await voice.beginPushToTalk()
        mic.simulateAudioChunk(Data(repeating: 10, count: 960_002))
        for _ in 0..<100 { if !voice.state.isLive { break }; await Task.yield() }
        #expect(!mic.isCapturing && session.order.isEmpty)
        await voice.stopSession()
    }
    @Test func stoppingDuringCropCannotSubmitToNewSession() async {
        let (voice, session, mic) = make()
        var preparing = false
        let late = ImageAttachment(source: .screenshot(app: "TextEdit"), jpeg: [Data([1])], text: nil)
        voice.onPushToTalkContextBegin = { .screen }
        voice.onPushToTalkContextRelease = {
            preparing = true
            // Model a framework that still returns its image after cancellation, with a bounded wait.
            do { try await Task.sleep(for: .milliseconds(200)); return late }
            catch { return late }
        }
        await voice.beginPushToTalk(); mic.simulateAudioChunk(loud)
        let release = Task { await voice.endPushToTalk() }
        for _ in 0..<100 {
            if preparing { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(preparing && !mic.isCapturing)
        await voice.stopSession()
        await release.value
        #expect(session.order.isEmpty && voice.state == .idle && voice.activeTaskCount == 0)
    }
    @Test func microphoneDenialCancelsSelector() async {
        let session = OrderedSpatialSession(), mic = MockAudioCapture(isPermissionGranted: false)
        let voice = GeminiLiveVoiceCoordinator(session: session, audioCapture: mic,
            audioPlayer: MockLiveAudioPlayer(), wakeWordDetector: MockWakeWordDetector())
        var cancelled = false
        voice.onPushToTalkContextBegin = { .screen }; voice.onPushToTalkContextCancel = { cancelled = true }
        await voice.beginPushToTalk()
        #expect(cancelled && !mic.isCapturing && session.order.isEmpty && !voice.state.isLive)
        await voice.stopSession()
    }
    @Test func selectorOpensAfterPermissionsBeforeMic() async {
        let (voice, session, mic) = make()
        var ready = false
        voice.onPushToTalkContextBegin = { .screen }
        voice.onPushToTalkContextReady = { ready = true; #expect(!mic.isCapturing); return false }
        await voice.beginPushToTalk()
        #expect(ready && !mic.isCapturing && voice.state == .idle && session.order.isEmpty)
    }
    @Test func releaseDuringPermissionPromptDoesNotReopenMic() async {
        let session = OrderedSpatialSession(), mic = DelayedSpatialPermission()
        let voice = GeminiLiveVoiceCoordinator(session: session, audioCapture: mic,
            audioPlayer: MockLiveAudioPlayer(), wakeWordDetector: MockWakeWordDetector())
        var opened = false
        voice.onPushToTalkContextBegin = { .screen }
        voice.onPushToTalkContextReady = { opened = true; return true }
        let start = Task { await voice.beginPushToTalk() }
        for _ in 0..<100 { if voice.isPushToTalkActive { break }; await Task.yield() }
        await voice.endPushToTalk(); await start.value
        #expect(!opened && !mic.inner.isCapturing && session.order.isEmpty && voice.state == .idle)
    }
}

private struct DelayedSpatialPermission: AudioCaptureProtocol {
    let inner = MockAudioCapture()
    func requestPermission() async -> Bool {
        do { try await Task.sleep(for: .milliseconds(50)); return true } catch { return false }
    }
    func startCapture() async throws -> AsyncThrowingStream<Data, Error> { try await inner.startCapture() }
    func stopCapture() async { await inner.stopCapture() }
}
