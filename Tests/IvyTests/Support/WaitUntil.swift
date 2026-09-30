import Foundation

/// Polls `condition` on the caller's actor (it inherits the caller's isolation, so main-actor state is safe to read) until it holds or `timeout` elapses, then returns its final value.
/// Use this instead of a fixed `Task.sleep` before an assertion: fixed sleeps race the main actor under full-suite
/// load, while polling returns as soon as the state is reached and only waits the full timeout on real failures.
@discardableResult
func waitUntil(
    timeout: Duration = .seconds(2),
    isolation: isolated (any Actor)? = #isolation,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return condition() }
        do {
            try await Task.sleep(for: .milliseconds(5))
        } catch {
            return condition() // test was cancelled
        }
    }
    return true
}
