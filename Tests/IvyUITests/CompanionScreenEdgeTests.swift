import AppKit
import SwiftUI
import Testing
@testable import Ivy
@testable import IvyCore

@MainActor
@Suite("Companion native screen-edge placement", .serialized)
struct CompanionScreenEdgeTests {
    @Test("AppKit preserves a top-edge origin when only the transparent panel margin exceeds the screen")
    func topEdge() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let size = CompanionView.panelSize
        let content = CGRect(x: 164, y: 8, width: 108, height: 125)
        let placement = CompanionPlacement(origin: CGPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.maxY + 1000),
            panelSize: size, visibleFrame: screen.visibleFrame, displayID: 0, contentFrame: content)
        let origin = placement.origin(panelSize: size, visibleFrame: screen.visibleFrame, contentFrame: content)
        let requested = CGRect(origin: origin, size: size)
        let panel = CompanionPanel(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        #expect(requested.maxY > screen.visibleFrame.maxY, "Only the transparent top margin should exceed the usable screen")
        #expect(origin.y + content.maxY == screen.visibleFrame.maxY)
        #expect(panel.constrainFrameRect(requested, to: screen) == requested,
            "AppKit must not push visible Ivy down to keep empty panel space onscreen")
        panel.setFrameOrigin(origin)
        #expect(abs(panel.frame.minY - origin.y) < 0.5)
        #expect(!panel.canBecomeKey && !panel.canBecomeMain)
    }

    @Test("Caption and approval expansion stay inside usable bounds at every edge")
    func expandedContent() throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.main)
        let size = CompanionView.panelSize(hasApproval: true)
        let panel = CompanionPanel(contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        let idle = CGRect(x: 164, y: 8, width: 108, height: 125)
        let caption = CGRect(x: 8, y: 8, width: 264, height: 208)
        let approval = CGRect(x: 44, y: 8, width: 228, height: 192)
        for x in [screen.visibleFrame.minX - 1000, screen.visibleFrame.maxX + 1000] {
            for y in [screen.visibleFrame.minY - 1000, screen.visibleFrame.maxY + 1000] {
                let placement = CompanionPlacement(origin: CGPoint(x: x, y: y), panelSize: size,
                    visibleFrame: screen.visibleFrame, displayID: 0, contentFrame: idle)
                for content in [idle, caption, approval] {
                    let origin = placement.origin(panelSize: size, visibleFrame: screen.visibleFrame, contentFrame: content)
                    let frame = CGRect(origin: origin, size: size)
                    #expect(panel.constrainFrameRect(frame, to: screen) == frame)
                    #expect(panel.constrainFrameRect(frame, to: nil) == frame)
                    panel.setFrame(frame, display: false)
                    let visible = content.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY)
                    #expect(screen.visibleFrame.contains(visible), "All review controls and captions must remain onscreen")
                    #expect(abs(visible.minX - screen.visibleFrame.minX) < 0.5 ||
                            abs(visible.maxX - screen.visibleFrame.maxX) < 0.5)
                    #expect(abs(visible.minY - screen.visibleFrame.minY) < 0.5 ||
                            abs(visible.maxY - screen.visibleFrame.maxY) < 0.5)
                }
            }
        }
    }
}
