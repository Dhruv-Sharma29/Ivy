import Foundation
import os
import IvyCore
#if os(macOS)
import AppKit
#endif

/// Production implementation of PhysicalTakeoverMonitoring that observes physical macOS mouse and keyboard events.
public final class SystemPhysicalTakeoverMonitor: PhysicalTakeoverMonitoring, @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var isMonitoring: Bool = false
        var onTakeover: (@Sendable (ComputerControlPauseReason) -> Void)? = nil
        var lastSyntheticEventTime: Date = .distantPast
        #if os(macOS)
        var monitorTokens: [Any] = []
        #endif
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Grace window (in seconds) after a synthetic event where incoming events are assumed to be our own.
    private let syntheticGraceInterval: TimeInterval = 0.35

    public init() {}

    deinit {
        stopMonitoring()
    }

    public var isMonitoring: Bool {
        state.withLock { $0.isMonitoring }
    }

    public func notifySyntheticEvent() {
        state.withLock { s in
            s.lastSyntheticEventTime = Date()
        }
    }

    public func startMonitoring(onTakeover: @escaping @Sendable (ComputerControlPauseReason) -> Void) {
        state.withLock { s in
            guard !s.isMonitoring else { return }
            s.isMonitoring = true
            s.onTakeover = onTakeover

            #if os(macOS)
            let mouseMask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown]
            let keyMask: NSEvent.EventTypeMask = [.keyDown]

            if let mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] _ in
                self?.handlePhysicalEvent()
            }) {
                s.monitorTokens.append(mouseMonitor)
            }

            if let keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: keyMask, handler: { [weak self] _ in
                self?.handlePhysicalEvent()
            }) {
                s.monitorTokens.append(keyMonitor)
            }
            #endif
        }
    }

    public func stopMonitoring() {
        state.withLock { s in
            s.isMonitoring = false
            s.onTakeover = nil
            #if os(macOS)
            for token in s.monitorTokens {
                NSEvent.removeMonitor(token)
            }
            s.monitorTokens.removeAll()
            #endif
        }
    }

    private func handlePhysicalEvent() {
        let (callback, isMon, lastTime) = state.withLock { s -> ((@Sendable (ComputerControlPauseReason) -> Void)?, Bool, Date) in
            return (s.onTakeover, s.isMonitoring, s.lastSyntheticEventTime)
        }

        guard isMon, let callback else { return }
        let elapsed = Date().timeIntervalSince(lastTime)
        if elapsed > syntheticGraceInterval {
            callback(.userTakeover)
        }
    }
}
