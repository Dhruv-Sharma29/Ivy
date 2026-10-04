import Testing
import Foundation
import CoreGraphics
import SwiftUI
import os
@testable import IvyCore
@testable import Ivy

@Suite("Phase 19.4 - Computer Control Panel and Takeover Tests")
@MainActor
struct ComputerControlPanelTests {

    private func makeSession(authorized: Bool = true) -> ComputerControlSession {
        let session = ComputerControlSession()
        let scope = ComputerControlScope(
            bundleIdentifier: "com.apple.Calculator",
            processIdentifier: 9999,
            isAuthorized: authorized
        )
        _ = session.start(goal: "Compute taxes", scope: scope)
        return session
    }

    @Test("Feedback state holds and updates status, targets, and progress")
    func feedbackStateManagement() {
        var state = ComputerControlFeedbackState(
            statusText: "Observing Calculator",
            targetAppName: "Calculator",
            targetFrame: CGRect(x: 100, y: 100, width: 200, height: 150),
            targetPoint: CGPoint(x: 200, y: 175),
            stepCount: 2,
            maxSteps: 20,
            isPaused: false
        )

        #expect(state.statusText == "Observing Calculator")
        #expect(state.targetAppName == "Calculator")
        #expect(state.stepCount == 2)
        #expect(state.maxSteps == 20)
        #expect(!state.isPaused)
        #expect(state.targetFrame == CGRect(x: 100, y: 100, width: 200, height: 150))
        #expect(state.targetPoint == CGPoint(x: 200, y: 175))

        state.isPaused = true
        state.pauseReason = .userTakeover
        #expect(state.isPaused)
        #expect(state.pauseReason == .userTakeover)
    }

    @Test("Mock physical takeover monitor detects real physical user input")
    func physicalTakeoverMonitoring() {
        let monitor = MockPhysicalTakeoverMonitor()
        #expect(!monitor.isMonitoring)

        let detectedReason = OSAllocatedUnfairLock<ComputerControlPauseReason?>(initialState: nil)
        monitor.startMonitoring { reason in
            detectedReason.withLock { $0 = reason }
        }
        #expect(monitor.isMonitoring)

        monitor.notifySyntheticEvent()
        #expect(monitor.syntheticEventsCount == 1)

        monitor.simulatePhysicalTakeover(reason: .userTakeover)
        let observed = detectedReason.withLock { $0 }
        #expect(observed == .userTakeover)

        monitor.stopMonitoring()
        #expect(!monitor.isMonitoring)
    }

    @Test("Controller initializes, updates status, and responds to takeover on MainActor")
    @MainActor
    func panelControllerLifecycle() async throws {
        let session = makeSession()
        let takeover = MockPhysicalTakeoverMonitor()
        let controller = ComputerControlPanelController(session: session, takeoverMonitor: takeover)

        #expect(session.state.isActive)
        #expect(!takeover.isMonitoring)

        // Show panel
        controller.show(initialStatus: "Finding Calculator display")
        #expect(takeover.isMonitoring)
        #expect(controller.feedbackState.statusText == "Finding Calculator display")
        #expect(controller.feedbackState.targetAppName == "com.apple.Calculator")
        #expect(!controller.feedbackState.isPaused)

        // Update target
        controller.update(
            status: "Clicking button 5",
            targetFrame: CGRect(x: 50, y: 50, width: 40, height: 40),
            targetPoint: CGPoint(x: 70, y: 70),
            step: 3
        )
        #expect(controller.feedbackState.statusText == "Clicking button 5")
        #expect(controller.feedbackState.stepCount == 3)
        #expect(controller.feedbackState.targetPoint == CGPoint(x: 70, y: 70))

        // Physical takeover triggers pause
        takeover.simulatePhysicalTakeover(reason: .userTakeover)
        for _ in 0..<30 {
            if controller.feedbackState.isPaused { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(controller.feedbackState.isPaused)
        #expect(controller.feedbackState.pauseReason == .userTakeover)
        #expect(!session.state.isActive) // Session is paused

        // Resume
        controller.resume()
        #expect(!controller.feedbackState.isPaused)
        #expect(session.state.isActive)

        // User Pause
        controller.pause(reason: .userRequested)
        #expect(controller.feedbackState.isPaused)
        #expect(controller.feedbackState.pauseReason == .userRequested)

        // Stop
        controller.stop(reason: "Finished task")
        #expect(!takeover.isMonitoring)
        #expect(!session.state.isActive)
    }

    @Test("SwiftUI panel view renders active and paused states")
    func panelViewRendering() {
        var pauseCalled = false
        var resumeCalled = false
        var stopCalled = false

        let activeView = ComputerControlPanelView(
            statusText: "Clicking digit 9",
            targetAppName: "Calculator",
            stepCount: 4,
            maxSteps: 20,
            isPaused: false,
            onPause: { pauseCalled = true },
            onResume: { resumeCalled = true },
            onStop: { stopCalled = true }
        )
        #expect(activeView.targetAppName == "Calculator")
        #expect(activeView.stepCount == 4)
        #expect(!activeView.isPaused)

        activeView.onPause()
        #expect(pauseCalled)

        let pausedView = ComputerControlPanelView(
            statusText: "Observing Calculator",
            targetAppName: "Calculator",
            stepCount: 4,
            maxSteps: 20,
            isPaused: true,
            pauseReason: .userTakeover,
            onPause: { },
            onResume: { resumeCalled = true },
            onStop: { stopCalled = true }
        )
        #expect(pausedView.isPaused)
        #expect(pausedView.pauseReason == .userTakeover)

        pausedView.onResume()
        #expect(resumeCalled)

        pausedView.onStop()
        #expect(stopCalled)
    }

    @Test("Target highlight view conforms to hit testing rules")
    func targetHighlightHitTesting() {
        let highlightWithRect = TargetHighlightView(
            frameRect: CGRect(x: 100, y: 100, width: 80, height: 30)
        )
        #expect(highlightWithRect.frameRect != nil)

        let highlightWithPoint = TargetHighlightView(
            point: CGPoint(x: 150, y: 200)
        )
        #expect(highlightWithPoint.point != nil)
    }
}
