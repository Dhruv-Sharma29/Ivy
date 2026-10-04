import Foundation
import Testing
@testable import IvyCore

@Suite("Floating pointer geometry and preferences")
struct FloatingPointerTests {
    @Test("following remains separated and bounded on negative-origin displays and all corners")
    func displayEdges() throws {
        for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: -1920, y: -1000, width: 1920, height: 1000)] {
            for point in [CGPoint(x: screen.midX, y: screen.midY),
                          CGPoint(x: screen.minX, y: screen.minY),
                          CGPoint(x: screen.maxX - 1, y: screen.minY),
                          CGPoint(x: screen.minX, y: screen.maxY - 1),
                          CGPoint(x: screen.maxX - 1, y: screen.maxY - 1)] {
                var placement = FloatingPointerPlacement()
                let result = placement.update(cursor: point, screens: [screen], reduceMotion: false)
                let frame = try #require(result)
                #expect(screen.contains(frame))
                #expect(!frame.contains(point))
                #expect(frame.size == CGSize(width: 32, height: 32))
            }
        }
    }

    @Test("smooth motion is bounded, teleports and display changes snap without crossing desktops")
    func interpolation() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        var placement = FloatingPointerPlacement()
        let firstResult = placement.update(cursor: CGPoint(x: 100, y: 200), screens: [screen], reduceMotion: false)
        let first = try #require(firstResult)
        let stationary = placement.update(cursor: CGPoint(x: 100, y: 200), screens: [screen], reduceMotion: false)
        #expect(stationary == first)
        let nextResult = placement.update(cursor: CGPoint(x: 200, y: 300), screens: [screen], reduceMotion: false)
        let next = try #require(nextResult)
        #expect(abs(hypot(next.minX - first.minX, next.minY - first.minY) - 24) < 0.001)
        #expect(next.minX > first.minX && next.minX < 224)
        let jumped = placement.update(cursor: CGPoint(x: 1000, y: 600), screens: [screen], reduceMotion: false)
        #expect(jumped?.origin == CGPoint(x: 1024, y: 544))
        let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let transitioned = placement.update(cursor: CGPoint(x: -500, y: 600), screens: [screen, left], reduceMotion: false)
        #expect(transitioned?.origin == CGPoint(x: -476, y: 544))
        placement.reset()
        #expect(placement.update(cursor: CGPoint(x: 200, y: 300), screens: [screen], reduceMotion: false)?.origin == CGPoint(x: 224, y: 244))
    }

    @Test("invalid geometry and Reduce Motion discard tracking state")
    func invalidInputs() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        var placement = FloatingPointerPlacement()
        #expect(placement.update(cursor: CGPoint(x: 100, y: 200), screens: [screen], reduceMotion: false) != nil)
        #expect(placement.update(cursor: CGPoint(x: 120, y: 220), screens: [screen], reduceMotion: true) == nil)
        #expect(placement.update(cursor: CGPoint(x: 120, y: 220), screens: [screen], reduceMotion: false)?.origin == CGPoint(x: 144, y: 164))
        for point in [CGPoint(x: CGFloat.nan, y: 50), CGPoint(x: 50, y: CGFloat.infinity), CGPoint(x: 2000, y: 2000)] {
            #expect(placement.update(cursor: point, screens: [screen], reduceMotion: false) == nil)
        }
        for invalid in [CGRect.zero, CGRect(x: 0, y: 0, width: 50, height: 50),
                        CGRect(x: CGFloat.nan, y: 0, width: 200, height: 200),
                        CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 200)] {
            #expect(placement.update(cursor: CGPoint(x: 20, y: 20), screens: [invalid], reduceMotion: false) == nil)
        }
        #expect(placement.update(cursor: .zero, screens: [], reduceMotion: false) == nil)
    }

    @Test("existing installations stay opted out; all colors round-trip and corrupt fields recover individually")
    func preferences() throws {
        let legacy = try JSONDecoder().decode(IvySettings.self, from: Data("{}".utf8))
        #expect(!legacy.floatingPointerEnabled && legacy.floatingPointerColor == .blue)
        for color in FloatingPointerColor.allCases {
            var settings = IvySettings.defaults
            settings.floatingPointerEnabled = true
            settings.floatingPointerColor = color
            let roundTrip = try JSONDecoder().decode(IvySettings.self, from: JSONEncoder().encode(settings))
            #expect(roundTrip == settings)
        }
        let malformed = try JSONDecoder().decode(IvySettings.self, from: Data(#"{"floatingPointerEnabled":"true","floatingPointerColor":"invalid","companionShowWhileIdle":true}"#.utf8))
        #expect(!malformed.floatingPointerEnabled && malformed.floatingPointerColor == .blue && malformed.companionShowWhileIdle)
    }
}
