import Testing
import Foundation
@testable import IvyCore

@Suite("Phase 4B - WakePhraseMatcher & WakeWordDetector Tests")
struct WakePhraseMatcherTests {

    @Test("Exact match 'Hey Ivy' triggers detection")
    func testExactMatch() {
        #expect(WakePhraseMatcher.containsWakePhrase("Hey Ivy"))
        #expect(WakePhraseMatcher.containsWakePhrase("hey ivy"))
        #expect(WakePhraseMatcher.containsWakePhrase("HEY IVY"))
        #expect(WakePhraseMatcher.containsWakePhrase("hEy IvY"))
    }

    @Test("Punctuation variations are stripped and recognized")
    func testPunctuationVariations() {
        #expect(WakePhraseMatcher.containsWakePhrase("Hey, Ivy!"))
        #expect(WakePhraseMatcher.containsWakePhrase("Hey, Ivy?"))
        #expect(WakePhraseMatcher.containsWakePhrase("Hey... Ivy."))
        #expect(WakePhraseMatcher.containsWakePhrase("Hey-Ivy!"))
        #expect(WakePhraseMatcher.containsWakePhrase("\"Hey Ivy\""))
        #expect(WakePhraseMatcher.containsWakePhrase("(Hey Ivy)"))
    }

    @Test("Whitespace, tabs, and newlines are normalized")
    func testWhitespaceNormalization() {
        #expect(WakePhraseMatcher.containsWakePhrase("   Hey    Ivy   "))
        #expect(WakePhraseMatcher.containsWakePhrase("Hey\tIvy"))
        #expect(WakePhraseMatcher.containsWakePhrase("Hey\nIvy"))
        #expect(WakePhraseMatcher.containsWakePhrase("Hey \n\t Ivy"))
    }

    @Test("Wake phrase embedded within a sentence is detected")
    func testEmbeddedWakePhrase() {
        #expect(WakePhraseMatcher.containsWakePhrase("Actually, Hey Ivy, could you stop?"))
        #expect(WakePhraseMatcher.containsWakePhrase("Wait a second, hey ivy."))
        #expect(WakePhraseMatcher.containsWakePhrase("Excuse me, hey ivy! What time is it?"))
    }

    @Test("Negative cases: non-wake phrases are rejected")
    func testNegativePhrases() {
        #expect(!WakePhraseMatcher.containsWakePhrase(""))
        #expect(!WakePhraseMatcher.containsWakePhrase("   "))
        #expect(!WakePhraseMatcher.containsWakePhrase("Hey"))
        #expect(!WakePhraseMatcher.containsWakePhrase("Ivy"))
        #expect(!WakePhraseMatcher.containsWakePhrase("Hey there"))
        #expect(!WakePhraseMatcher.containsWakePhrase("Hey everyone"))
        #expect(!WakePhraseMatcher.containsWakePhrase("Wait Ivy"))
        #expect(!WakePhraseMatcher.containsWakePhrase("No Ivy"))
        #expect(!WakePhraseMatcher.containsWakePhrase("Hello Ivy"))
        #expect(!WakePhraseMatcher.containsWakePhrase("Hi Ivy"))
        #expect(!WakePhraseMatcher.containsWakePhrase("Ivy, hey"))
        #expect(!WakePhraseMatcher.containsWakePhrase("Yeah, I understand."))
        #expect(!WakePhraseMatcher.containsWakePhrase("Wait, that's not what I meant."))
        #expect(!WakePhraseMatcher.containsWakePhrase("Machine learning is cool."))
    }

    @Test("Sub-token boundaries: words starting with hey or ivy are rejected")
    func testSubTokenBoundaries() {
        #expect(!WakePhraseMatcher.containsWakePhrase("Heyday Ivy"))
        #expect(!WakePhraseMatcher.containsWakePhrase("Hey Ivyberry"))
        #expect(!WakePhraseMatcher.containsWakePhrase("They ivy"))
    }

    @Test("MockWakeWordDetector processes chunks, text, and handles reset")
    func testMockWakeWordDetector() async {
        let detector = MockWakeWordDetector(shouldTrigger: false)
        #expect(!detector.isReset)
        #expect(detector.processedChunksCount == 0)

        let chunk = Data([0x01, 0x02, 0x03, 0x04])
        let detected1 = await detector.processAudioChunk(chunk)
        #expect(!detected1)
        #expect(detector.processedChunksCount == 1)

        // Text checking without forced trigger
        let textResult1 = await detector.processText("Hello world")
        #expect(!textResult1)
        let textResult2 = await detector.processText("Hey, Ivy!")
        #expect(textResult2)

        // When forced trigger is enabled
        detector.setShouldTrigger(true)
        let detected2 = await detector.processAudioChunk(chunk)
        #expect(detected2)
        #expect(detector.processedChunksCount == 2)

        // Reset
        await detector.reset()
        #expect(detector.isReset)
        let detected3 = await detector.processAudioChunk(chunk)
        #expect(!detected3) // shouldTrigger was reset to false
    }
}
