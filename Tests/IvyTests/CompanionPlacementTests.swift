import Foundation
import Testing
@testable import IvyCore

@Suite("Free companion placement")
struct CompanionPlacementTests {
    @Test("transparent panel margins do not keep the visible companion away from screen edges")
    func visibleEdges() {
        let size = CGSize(width: 280, height: 224)
        let content = CGRect(x: 164, y: 8, width: 108, height: 125)
        for screen in [CGRect(x: 0, y: 25, width: 1440, height: 900), CGRect(x: -1920, y: 40, width: 1920, height: 1000)] {
            let left = CompanionPlacement(origin: CGPoint(x: screen.minX - 1000, y: screen.minY - 1000),
                                          panelSize: size, visibleFrame: screen, displayID: 7, contentFrame: content)
            let origin = left.origin(panelSize: size, visibleFrame: screen, contentFrame: content)
            #expect(origin.x + content.minX == screen.minX)
            #expect(origin.y + content.minY == screen.minY)
            #expect(origin.x < screen.minX, "the empty part of a transparent panel may extend beyond the screen")
            let right = CompanionPlacement(origin: CGPoint(x: screen.maxX + 1000, y: screen.maxY + 1000),
                                           panelSize: size, visibleFrame: screen, displayID: 7, contentFrame: content)
            let far = right.origin(panelSize: size, visibleFrame: screen, contentFrame: content)
            #expect(far.x + content.maxX == screen.maxX)
            #expect(far.y + content.maxY == screen.maxY)
            let caption = CGRect(x: 8, y: 8, width: 264, height: 208)
            let expanded = left.origin(panelSize: size, visibleFrame: screen, contentFrame: caption)
            #expect(expanded.x + caption.minX == screen.minX)
            #expect(expanded.y + caption.minY == screen.minY)
            let again = CompanionPlacement(origin: origin, panelSize: size, visibleFrame: screen,
                                           displayID: 7, contentFrame: content)
            #expect(again == left)
        }
    }

    @Test("a drop is restored exactly, remains relative on resize, and supports displays with negative origins")
    func restoration() throws {
        let frame = CGRect(x: -1920, y: 25, width: 1920, height: 1000)
        let size = CGSize(width: 280, height: 224)
        let origin = CGPoint(x: -1100, y: 413)
        let placement = CompanionPlacement(origin: origin, panelSize: size, visibleFrame: frame, displayID: 7)
        #expect(placement.origin(panelSize: size, visibleFrame: frame) == origin)
        #expect(placement.horizontal == 0.5 && placement.vertical == 0.5)
        let resized = CGRect(x: 0, y: 40, width: 1280, height: 800)
        #expect(placement.origin(panelSize: size, visibleFrame: resized) == CGPoint(x: 500, y: 328))
        var settings = IvySettings.defaults
        settings.companionPlacement = placement
        let restored = try JSONDecoder().decode(IvySettings.self, from: JSONEncoder().encode(settings))
        #expect(restored.companionPlacement == placement)
        #expect(restored.companionPlacement?.displayID == 7)
    }

    @Test("off-screen drops and changed screen sizes are bounded; legacy and corrupt settings recover")
    func recovery() throws {
        let frame = CGRect(x: 0, y: 25, width: 1000, height: 700)
        let size = CGSize(width: 280, height: 224)
        for (drop, expected) in [(CGPoint(x: -1000, y: -1000), CGPoint(x: 0, y: 25)),
                                 (CGPoint(x: 5000, y: 5000), CGPoint(x: 720, y: 501))] {
            let placement = CompanionPlacement(origin: drop, panelSize: size, visibleFrame: frame, displayID: 0)
            #expect(placement.origin(panelSize: size, visibleFrame: frame) == expected)
        }
        let tiny = CGRect(x: 20, y: 40, width: 100, height: 100)
        let small = CompanionPlacement(origin: .zero, panelSize: size, visibleFrame: tiny, displayID: 0)
        #expect(small.origin(panelSize: size, visibleFrame: tiny) == tiny.origin)
        let invalid = CompanionPlacement(origin: CGPoint(x: CGFloat.nan, y: CGFloat.infinity), panelSize: size, visibleFrame: frame, displayID: 0)
        #expect(invalid.origin(panelSize: size, visibleFrame: frame) == CGPoint(x: 360, y: 263))
        let old = try JSONDecoder().decode(IvySettings.self, from: Data("{}".utf8))
        #expect(old.companionPlacement == nil && old.companionCorner == .bottomRight)
        let corrupt = try JSONDecoder().decode(IvySettings.self, from: Data(#"{"companionPlacement":"invalid","companionShowWhileIdle":true}"#.utf8))
        #expect(corrupt.companionPlacement == nil && corrupt.companionShowWhileIdle)
    }
}
