import Foundation
import Testing
import os
@testable import IvyCore

/// Advances only response deadlines, leaving microphone/socket/approval behavior real in the harness.
private final class VoiceResponseClock: @unchecked Sendable {
    private struct State {
        var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
        var durations: [Duration] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var pendingCount: Int { state.withLock { $0.pending.count } }
    var durations: [Duration] { state.withLock { $0.durations } }

    func wait(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.withLock { s in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else {
                        s.durations.append(duration)
                        s.pending[id] = continuation
                    }
                }
            }
        } onCancel: {
            let continuation = self.state.withLock { $0.pending.removeValue(forKey: id) }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance() { finish(throwing: nil) }
    func fail() { finish(throwing: LiveError.serverError("deadline clock unavailable")) }

    private func finish(throwing error: (any Error)?) {
        let continuations = state.withLock { s in
            defer { s.pending.removeAll() }
            return Array(s.pending.values)
        }
        for continuation in continuations {
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
}

private actor SuspendedVoiceTool: IvyTool {
    nonisolated let name = "slow_test_tool"
    nonisolated let description = "A test tool that finishes only when released."
    nonisolated var safetyClassification: ToolSafetyClassification { .safe }
    nonisolated var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description,
            parameters: ToolParameters(type: "OBJECT", properties: [:], required: []))
    }
    private(set) var executionCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        executionCount += 1
        await withCheckedContinuation { continuation = $0 }
        return .success("Finished the test work.")
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Voice reply stalls recover without replaying actions")
@MainActor
struct VoiceReplyRecoveryTests {
    @MainActor
    private struct Harness {
        let coordinator: GeminiLiveVoiceCoordinator
        let session = MockGeminiLiveSession()
        let capture = MockAudioCapture()
        let player = MockLiveAudioPlayer(autoDrain: false)
        let clock = VoiceResponseClock()

        init(tool: (any IvyTool)? = nil) {
            let bridge = ConfirmationBridge()
            let dispatcher = ToolDispatcher(registry: ToolRegistry(tools: tool.map { [$0] } ?? []),
                safetyGate: InteractiveSafetyGate(confirmationProvider: bridge))
            coordinator = GeminiLiveVoiceCoordinator(session: session, audioCapture: capture,
                audioPlayer: player, wakeWordDetector: MockWakeWordDetector(),
                toolDispatcher: dispatcher, voiceResponseWait: clock.wait)
        }

        func submit() async throws {
            await coordinator.beginPushToTalk()
            capture.simulateAudioChunk(Self.speech)
            #expect(try await VoiceReplyRecoveryTests.until { !session.sentAudioChunks.isEmpty })
            await coordinator.endPushToTalk()
            #expect(coordinator.state == .thinking)
            #expect(try await VoiceReplyRecoveryTests.until { clock.pendingCount == 1 })
        }

        static let speech = Data(repeating: 0x20, count: 1280)
    }

    private static func until(_ condition: () async -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    @Test("Noise without a recognized request times out, releases resources and allows another hold")
    func missedRecognition() async throws {
        let h = Harness()
        try await h.submit()
        #expect(h.clock.durations.last == .seconds(8))
        h.session.simulateEvent(.inputTranscript("  "))
        h.session.simulateEvent(.audioChunk(Data()))
        h.clock.advance()
        #expect(try await Self.until { !h.coordinator.state.isLive && h.coordinator.activeTaskCount == 0 })
        #expect(h.coordinator.state == .error("I couldn't confirm what you said. Please try again."))
        #expect(!h.capture.isCapturing && !h.session.isConnected && !h.player.isPlaying)
        #expect(h.session.audioInputEndCount == 1 && h.session.sentToolResponses.isEmpty)
        await h.coordinator.beginPushToTalk()
        #expect(h.coordinator.state == .listening && h.capture.isCapturing)
        #expect(h.capture.startCaptureCallCount == 2)
        await h.coordinator.shutdown()
        #expect(h.coordinator.activeTaskCount == 0 && h.clock.pendingCount == 0)
    }

    @Test("An unexpected deadline-monitor failure is visible and releases the session")
    func monitorFailure() async throws {
        let h = Harness()
        try await h.submit()
        h.clock.fail()
        #expect(try await Self.until { !h.coordinator.state.isLive && h.coordinator.activeTaskCount == 0 })
        guard case .error(let message) = h.coordinator.state else {
            Issue.record("A failed deadline monitor must not leave Thinking active")
            await h.coordinator.shutdown()
            return
        }
        #expect(message.contains("Couldn't monitor Ivy's voice reply") && message.contains("deadline clock unavailable"))
        #expect(!h.capture.isCapturing && !h.session.isConnected && h.clock.pendingCount == 0)
        await h.coordinator.shutdown()
    }

    @Test("Recognized speech uses the reply deadline and preserves its transcript on failure")
    func recognizedButStalled() async throws {
        let h = Harness()
        var transcripts: [String] = []
        h.coordinator.onTranscript = { text, _, _ in transcripts.append(text) }
        try await h.submit()
        h.session.simulateEvent(.inputTranscript("Open Calculator"))
        #expect(try await Self.until { h.clock.durations.last == .seconds(15) })
        h.clock.advance()
        #expect(try await Self.until { !h.coordinator.state.isLive })
        #expect(h.coordinator.state == .error("Ivy's voice reply stalled. Please try again."))
        #expect(transcripts == ["Open Calculator"])
        #expect(h.session.audioInputEndCount == 1 && h.session.sentToolResponses.isEmpty)
        await h.coordinator.shutdown()
    }

    @Test("Audio progress renews the deadline; completed generation does not time out playback")
    func streamingAndPlayback() async throws {
        let h = Harness()
        try await h.submit()
        for _ in 0..<4 {
            let previous = h.clock.durations.count
            h.session.simulateEvent(.audioChunk(Harness.speech))
            #expect(try await Self.until { h.clock.durations.count > previous && h.player.isPlaying })
            #expect(h.coordinator.state == .speaking)
        }
        h.session.simulateEvent(.turnComplete)
        #expect(try await Self.until { h.clock.pendingCount == 0 })
        h.clock.advance()
        #expect(h.coordinator.state == .speaking && h.player.isPlaying)
        h.player.finishPlayback()
        #expect(try await Self.until { h.coordinator.state == .idle })
        #expect(h.coordinator.activeTaskCount == 0)
        await h.coordinator.shutdown()
    }

    @Test("A streamed reply missing turnComplete recovers and keeps partial speech")
    func missingCompletion() async throws {
        let h = Harness()
        var replies: [String] = []
        var interrupted = false
        h.coordinator.onTranscript = { text, user, cutOff in
            if !user { replies.append(text); interrupted = cutOff }
        }
        try await h.submit()
        h.session.simulateEvent(.audioChunk(Harness.speech))
        #expect(try await Self.until { h.coordinator.state == .speaking && h.clock.durations.last == .seconds(15) })
        h.session.simulateEvent(.outputTranscript("I started checking"))
        #expect(try await Self.until { h.coordinator.caption == "I started checking" && h.clock.pendingCount == 1 })
        h.clock.advance()
        #expect(try await Self.until { !h.coordinator.state.isLive && h.coordinator.activeTaskCount == 0 })
        #expect(h.coordinator.state == .error("Ivy's voice reply stalled. Please try again."))
        #expect(replies == ["I started checking"] && interrupted)
        #expect(!h.player.isPlaying && h.coordinator.caption.isEmpty)
        await h.coordinator.shutdown()
    }

    @Test("Approval review has no deadline; denial remains safe and the missing follow-up recovers")
    func approvalNeverTimesOutOrApproves() async throws {
        let executor = MockShellExecutor()
        let h = Harness(tool: RunShellTool(executor: executor))
        try await h.submit()
        h.session.simulateEvent(.toolCall(FunctionCall(name: "run_shell", args: ["command": "echo test"], id: "approval")))
        #expect(try await Self.until { h.coordinator.pendingConfirmation != nil && h.clock.pendingCount == 0 })
        let request = try #require(h.coordinator.pendingConfirmation)
        h.clock.advance()
        #expect(h.coordinator.state == .toolConfirmation && h.coordinator.pendingConfirmation?.id == request.id)
        #expect(executor.recordedCommands.isEmpty)
        h.coordinator.respondToPendingConfirmation(id: request.id, approved: false)
        #expect(try await Self.until { h.session.sentToolResponses.count == 1 && h.clock.pendingCount == 1 })
        h.clock.advance()
        #expect(try await Self.until { !h.coordinator.state.isLive })
        #expect(executor.recordedCommands.isEmpty && h.session.sentToolResponses.count == 1)
        await h.coordinator.shutdown()
    }

    @Test("Slow tools are allowed to finish once; only the missing model follow-up times out")
    func slowTool() async throws {
        let tool = SuspendedVoiceTool()
        let h = Harness(tool: tool)
        try await h.submit()
        h.session.simulateEvent(.toolCall(FunctionCall(name: tool.name, args: [:], id: "slow")))
        #expect(try await Self.until { h.coordinator.state == .toolExecution && h.clock.pendingCount == 0 })
        // Entering TOOL_EXECUTION precedes the actor's execute call; wait for real execution too.
        #expect(try await Self.until { await tool.executionCount == 1 })
        h.clock.advance()
        #expect(h.coordinator.state == .toolExecution)
        await tool.release()
        #expect(try await Self.until { h.session.sentToolResponses.count == 1 && h.clock.pendingCount == 1 })
        h.clock.advance()
        #expect(try await Self.until { !h.coordinator.state.isLive })
        #expect(await tool.executionCount == 1)
        #expect(h.session.sentToolResponses.count == 1 && h.coordinator.executingToolName == nil)
        await h.coordinator.shutdown()
    }

    @Test("Withdrawing a queued tool resumes the reply deadline when the last real tool finishes")
    func cancelledQueuedTool() async throws {
        let tool = SuspendedVoiceTool()
        let h = Harness(tool: tool)
        try await h.submit()
        h.session.simulateEvent(.toolCall(FunctionCall(name: tool.name, args: [:], id: "first")))
        #expect(try await Self.until { await tool.executionCount == 1 })
        h.session.simulateEvent(.toolCall(FunctionCall(name: tool.name, args: [:], id: "queued")))
        h.session.simulateEvent(.toolCallCancelled(["queued"]))
        // Event-loop order consumes the withdrawal before an unrelated text event can be published.
        h.session.simulateEvent(.textTurn("Queued call withdrawn"))
        #expect(try await Self.until { h.coordinator.latestTranscript == "Queued call withdrawn" })
        #expect(h.clock.pendingCount == 0)
        await tool.release()
        #expect(try await Self.until { h.session.sentToolResponses.count == 1 && h.clock.pendingCount == 1 })
        h.clock.advance()
        #expect(try await Self.until { !h.coordinator.state.isLive })
        #expect(await tool.executionCount == 1)
        #expect(h.session.sentToolResponses.count == 1 && h.coordinator.activeTaskCount == 0)
        await h.coordinator.shutdown()
    }

    @Test("Interruption cancels the old deadline and normal completion cancels the replacement deadline")
    func replacementAndCompletion() async throws {
        let h = Harness()
        try await h.submit()
        // Resume the old expiry just before replacement; its queued callback must not own the new session.
        h.clock.advance()
        await h.coordinator.beginPushToTalk()
        #expect(try await Self.until { h.clock.pendingCount == 0 })
        h.clock.advance()
        #expect(h.coordinator.state == .listening && h.capture.isCapturing)
        h.capture.simulateAudioChunk(Harness.speech)
        #expect(try await Self.until { h.session.sentAudioChunks.count == 2 })
        await h.coordinator.endPushToTalk()
        #expect(try await Self.until { h.clock.pendingCount == 1 })
        h.session.simulateEvent(.turnComplete)
        #expect(try await Self.until { h.coordinator.state == .idle && h.clock.pendingCount == 0 })
        h.clock.advance()
        #expect(h.coordinator.state == .idle && h.coordinator.activeTaskCount == 0)
        await h.coordinator.shutdown()
    }

    @Test("Text progress renews the deadline without pretending audio has started")
    func textProgress() async throws {
        let h = Harness()
        try await h.submit()
        h.session.simulateEvent(.textTurn("Checking the request"))
        #expect(try await Self.until { h.clock.durations.last == .seconds(15) })
        #expect(h.coordinator.state == .thinking && !h.player.isPlaying)
        let previous = h.clock.durations.count
        h.session.simulateEvent(.outputTranscript("Here is the result"))
        #expect(try await Self.until { h.clock.durations.count > previous })
        h.session.simulateEvent(.turnComplete)
        #expect(try await Self.until { h.coordinator.state == .idle })
        #expect(h.clock.pendingCount == 0 && h.coordinator.activeTaskCount == 0)
        await h.coordinator.shutdown()
    }
}
