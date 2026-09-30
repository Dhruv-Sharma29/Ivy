import Foundation
import Network
import os

/// Tells the Live reconnect loop whether retrying can work at all, so it waits for the network
/// instead of burning its attempts while the Mac is offline.
public protocol NetworkPathChecking: Sendable {
    /// Returns true as soon as the network is reachable, or false if it still isn't after `timeout`.
    func waitUntilOnline(timeout: Duration) async -> Bool
}

/// For injected sessions and tests: the network is always considered reachable.
public struct AlwaysOnlineNetworkPath: NetworkPathChecking {
    public init() {}
    public func waitUntilOnline(timeout: Duration) async -> Bool { true }
}

/// Reachability from `NWPathMonitor`.
public final class SystemNetworkPath: NetworkPathChecking, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let online = OSAllocatedUnfairLock(initialState: true)

    public init() {
        monitor.pathUpdateHandler = { [online] path in
            online.withLock { $0 = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "com.ivy.assistant.network-path"))
    }

    deinit {
        monitor.cancel()
    }

    public func waitUntilOnline(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !online.withLock({ $0 }) {
            if ContinuousClock.now >= deadline { return false }
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return false // cancelled: the session ended while waiting
            }
        }
        return true
    }
}
