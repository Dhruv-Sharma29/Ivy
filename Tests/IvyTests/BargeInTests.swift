import Testing
import Foundation
@testable import IvyCore

@Suite("Hey Ivy barge-in")
struct BargeInMatcherTests {
    /// Recorded from a real barge-in attempt: echo suppression clipped "Hey" while Ivy was speaking.
    @Test("recognizer renderings captured over Ivy's own voice trigger", arguments: [
        "AI Ivy", "AI a Ivy", "Ivy a Ivy", "Hey Ivy"
    ])
    func capturedRenderings(_ text: String) {
        #expect(WakePhraseMatcher.containsWakePhrase(text))
    }

    @Test("common mishearings of \"hey\" and \"Ivy\" trigger", arguments: [
        "hey ivy", "Hey Ivey", "hey ivie", "Hey ivee", "Hey IV", "hey i v", "Hey ivory",
        "a ivy", "Eh, Ivy!", "hay ivy", "Aye Ivy", "Okay... ay IVY stop"
    ])
    func variants(_ text: String) {
        #expect(WakePhraseMatcher.containsWakePhrase(text))
    }

    @Test("normal speech, other greetings and name-only mentions do not trigger", arguments: [
        "Ivy", "Ivy AI", "Ivy Ivy", "Hi Ivy", "Hello Ivy", "Ivy is a helpful AI", "Hey, I've got a question",
        "Hey I", "They ivy", "a ivyberry", "AI is great", "Hey everyone", "Wait Ivy", "Ivy, hey", "Hey"
    ])
    func negatives(_ text: String) {
        #expect(!WakePhraseMatcher.containsWakePhrase(text))
    }
}

@Suite("Hey Ivy barge-in interrupt path")
@MainActor
struct BargeInInterruptTests {
    @Test("a clipped \"AI Ivy\" stops playback, drops the interrupted turn and returns to listening")
    func clippedWakePhraseInterrupts() async throws {
        let session = MockGeminiLiveSession()
        let player = MockLiveAudioPlayer(autoDrain: false)
        let detector = MockWakeWordDetector()
        let c = GeminiLiveVoiceCoordinator(session: session, audioCapture: MockAudioCapture(), audioPlayer: player, wakeWordDetector: detector)
        await c.startSession()

        let first = Data([0x01, 0x02])
        session.simulateEvent(.audioChunk(first))
        for _ in 0..<400 where c.state != .speaking { try await Task.sleep(nanoseconds: 5_000_000) }
        try #require(c.state == .speaking)

        detector.simulateTranscription("AI Ivy")
        for _ in 0..<400 where c.state != .listening { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(c.state == .listening)
        #expect(player.isStopped)

        // The server keeps streaming the interrupted answer; none of it may play.
        let leftover = Data([0x03, 0x04])
        session.simulateEvent(.audioChunk(leftover))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!player.playedChunks.contains(leftover))
        #expect(c.state == .listening)
        await c.stopSession()
    }

    @Test("a name-only mention while speaking does not interrupt")
    func nameOnlyDoesNotInterrupt() async throws {
        let session = MockGeminiLiveSession()
        let player = MockLiveAudioPlayer(autoDrain: false)
        let detector = MockWakeWordDetector()
        let c = GeminiLiveVoiceCoordinator(session: session, audioCapture: MockAudioCapture(), audioPlayer: player, wakeWordDetector: detector)
        await c.startSession()
        session.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        for _ in 0..<400 where c.state != .speaking { try await Task.sleep(nanoseconds: 5_000_000) }

        detector.simulateTranscription("Ivy AI")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(c.state == .speaking)
        #expect(!player.isStopped)
        await c.stopSession()
    }

    @Test("wake session ends after a single answered turn")
    func wakeSessionEndsAfterSingleTurn() async throws {
        let session = MockGeminiLiveSession()
        let player = MockLiveAudioPlayer(autoDrain: true)
        let detector = MockWakeWordDetector()
        let c = GeminiLiveVoiceCoordinator(session: session, audioCapture: MockAudioCapture(), audioPlayer: player, wakeWordDetector: detector)
        await c.startWakeSession()
        #expect(c.wasSessionStartedByWakeWord)
        #expect(c.state == .listening)

        // Incoming audio chunk puts Ivy into speaking
        session.simulateEvent(.audioChunk(Data([0x01, 0x02])))
        for _ in 0..<400 where c.state != .speaking { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(c.state == .speaking)

        // Server signals turnComplete
        session.simulateEvent(.turnComplete)
        for _ in 0..<400 where c.state != .idle { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(c.state == .idle)
    }

    @Test("wake session closes after silence timeout when no request is heard")
    func wakeSessionTimesOutOnSilence() async throws {
        let session = MockGeminiLiveSession()
        let c = GeminiLiveVoiceCoordinator(
            session: session,
            audioCapture: MockAudioCapture(),
            audioPlayer: MockLiveAudioPlayer(),
            wakeWordDetector: MockWakeWordDetector(),
            wakeSilenceTimeout: .milliseconds(50)
        )
        await c.startWakeSession()
        #expect(c.wasSessionStartedByWakeWord)
        #expect(c.state == .listening)

        // Silence timeout fires
        for _ in 0..<400 where c.state != .idle { try await Task.sleep(nanoseconds: 5_000_000) }
        #expect(c.state == .idle)
    }
}
