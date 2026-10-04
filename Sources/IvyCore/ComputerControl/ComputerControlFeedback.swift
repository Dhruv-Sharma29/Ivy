import Foundation
import CoreGraphics
import os

/// State representation for the computer control status panel and target highlight overlay.
public struct ComputerControlFeedbackState: Equatable, Sendable {
    public var statusText: String
    public var targetAppName: String
    public var targetFrame: CGRect?
    public var targetPoint: CGPoint?
    public var stepCount: Int
    public var maxSteps: Int
    public var isPaused: Bool
    public var pauseReason: ComputerControlPauseReason?

    public init(
        statusText: String = "Ready",
        targetAppName: String = "Desktop",
        targetFrame: CGRect? = nil,
        targetPoint: CGPoint? = nil,
        stepCount: Int = 0,
        maxSteps: Int = 20,
        isPaused: Bool = false,
        pauseReason: ComputerControlPauseReason? = nil
    ) {
        self.statusText = statusText
        self.targetAppName = targetAppName
        self.targetFrame = targetFrame
        self.targetPoint = targetPoint
        self.stepCount = stepCount
        self.maxSteps = maxSteps
        self.isPaused = isPaused
        self.pauseReason = pauseReason
    }
}

/// Protocol for detecting real physical mouse and keyboard inputs to pause autonomous control immediately.
public protocol PhysicalTakeoverMonitoring: Sendable {
    /// Indicates whether global event monitoring is currently active.
    var isMonitoring: Bool { get }

    /// Starts monitoring for physical inputs and triggers `onTakeover` when real user activity is detected.
    func startMonitoring(onTakeover: @escaping @Sendable (ComputerControlPauseReason) -> Void)

    /// Stops monitoring.
    func stopMonitoring()

    /// Notifies the monitor that a synthetic event was produced by Ivy, preventing false-positive takeover pauses.
    func notifySyntheticEvent()
}

/// Offline mock for PhysicalTakeoverMonitoring for hermetic testing.
public final class MockPhysicalTakeoverMonitor: PhysicalTakeoverMonitoring, @unchecked Sendable {
    private struct State {
        var isMonitoring: Bool = false
        var onTakeover: (@Sendable (ComputerControlPauseReason) -> Void)? = nil
        var syntheticEventsCount: Int = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public var isMonitoring: Bool {
        state.withLock { $0.isMonitoring }
    }

    public var syntheticEventsCount: Int {
        state.withLock { $0.syntheticEventsCount }
    }

    public func startMonitoring(onTakeover: @escaping @Sendable (ComputerControlPauseReason) -> Void) {
        state.withLock { s in
            s.isMonitoring = true
            s.onTakeover = onTakeover
        }
    }

    public func stopMonitoring() {
        state.withLock { s in
            s.isMonitoring = false
            s.onTakeover = nil
        }
    }

    public func notifySyntheticEvent() {
        state.withLock { s in
            s.syntheticEventsCount += 1
        }
    }

    public func simulatePhysicalTakeover(reason: ComputerControlPauseReason = .userTakeover) {
        let callback = state.withLock { $0.onTakeover }
        callback?(reason)
    }
}
