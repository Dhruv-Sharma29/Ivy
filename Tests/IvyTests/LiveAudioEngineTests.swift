import Testing
import Foundation
@testable import IvyCore

@Suite("Phase 4B - Live Audio Engine & Abstraction Tests")
struct LiveAudioEngineTests {

    @Test("MockAudioCapture starts capture when permission is granted and streams chunks")
    func testAudioCaptureStreaming() async throws {
        let mockCapture = MockAudioCapture(isPermissionGranted: true)
        #expect(!mockCapture.isCapturing)

        let stream = try await mockCapture.startCapture()
        #expect(mockCapture.isCapturing)

        let collectTask = Task { () -> [Data] in
            var collected: [Data] = []
            for try await chunk in stream {
                collected.append(chunk)
            }
            return collected
        }

        let chunk1 = Data([0x01, 0x02])
        let chunk2 = Data([0x03, 0x04])
        mockCapture.simulateAudioChunk(chunk1)
        mockCapture.simulateAudioChunk(chunk2)

        await mockCapture.stopCapture()
        #expect(!mockCapture.isCapturing)

        let chunks = try await collectTask.value
        #expect(chunks == [chunk1, chunk2])
        #expect(mockCapture.capturedChunksCount == 2)
    }

    @Test("MockAudioCapture throws permissionDenied when permission is not granted")
    func testAudioCapturePermissionDenied() async {
        let mockCapture = MockAudioCapture(isPermissionGranted: false)
        await #expect(throws: LiveError.microphonePermissionDenied) {
            _ = try await mockCapture.startCapture()
        }
        #expect(!mockCapture.isCapturing)
    }

    @Test("MockLiveAudioPlayer plays chunks and responds to stop")
    func testLiveAudioPlayerPlaybackAndStop() async throws {
        let mockPlayer = MockLiveAudioPlayer()
        #expect(!mockPlayer.isPlaying)
        #expect(!mockPlayer.isStopped)

        let chunk1 = Data([0xAA, 0xBB])
        let chunk2 = Data([0xCC, 0xDD])

        try await mockPlayer.playChunk(chunk1)
        try await mockPlayer.playChunk(chunk2)

        #expect(mockPlayer.playedChunks == [chunk1, chunk2])
        #expect(mockPlayer.isPlaying)
        #expect(!mockPlayer.isStopped)

        await mockPlayer.stop()
        #expect(!mockPlayer.isPlaying)
        #expect(mockPlayer.isStopped)
    }

    @Test("MockLiveAudioPlayer propagates playError cleanly")
    func testLiveAudioPlayerError() async {
        let mockPlayer = MockLiveAudioPlayer(playError: LiveError.serverError("Output failure"))
        await #expect(throws: LiveError.serverError("Output failure")) {
            try await mockPlayer.playChunk(Data([1, 2]))
        }
    }
}
