import Testing
import Foundation
import CoreGraphics
@testable import IvyCore

@Suite("Phase 19.1 - Computer Control Session Lifecycle Tests")
struct ComputerControlSessionTests {

    private final class MockClock: @unchecked Sendable {
        private var current: Date
        init(initial: Date = Date()) { self.current = initial }
        func now() -> Date { current }
        func advance(by seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
    }

    @Test("Unauthorized scope cannot start control session")
    func unauthorizedScopeCannotStart() {
        let session = ComputerControlSession()
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: false)
        let result = session.start(goal: "Write a note", scope: scope)

        #expect(result == .failure(.unauthorizedScope))
        #expect(session.state == .idle)
    }

    @Test("Prohibited sensitive application cannot be controlled")
    func prohibitedAppCannotStart() {
        let sensitive = [
            "com.apple.Keychain-Access",
            "com.apple.SecurityAgent",
            "com.apple.Passwords",
            "com.apple.SystemSettings"
        ]

        for app in sensitive {
            let session = ComputerControlSession()
            let scope = ComputerControlScope(bundleIdentifier: app, isAuthorized: true)
            let result = session.start(goal: "Inspect passwords", scope: scope)
            #expect(result == .failure(.prohibitedApplication(app)))
            #expect(session.state == .idle)
        }
    }

    @Test("Authorized scope starts session and issues valid token")
    func validStartYieldsToken() {
        let clock = MockClock()
        let session = ComputerControlSession(clock: { clock.now() })
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.calculator", isAuthorized: true)

        let result = session.start(goal: "Calculate 2+2", scope: scope)
        guard case .success(let token) = result else {
            Issue.record("Expected successful session start")
            return
        }

        #expect(token.sessionID == session.id)
        #expect(token.revision == 1)
        #expect(token.isValid(for: session.id, at: clock.now()))
        #expect(session.state.isActive)
    }

    @Test("Actions require an active session")
    func actionRequiresActiveSession() {
        let session = ComputerControlSession()
        let action = ComputerControlAction(kind: .click, target: .elementID("button_1"))
        let validation = session.validateAction(action)

        guard case .failure(let err) = validation else {
            Issue.record("Expected failure when session is not active")
            return
        }
        #expect(err == .sessionNotActive)
    }

    @Test("Expired or stale observation token is rejected")
    func expiredTokenIsRejected() {
        let clock = MockClock()
        let session = ComputerControlSession(clock: { clock.now() })
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)

        let start = session.start(goal: "Type text", scope: scope)
        guard case .success(let token) = start else {
            Issue.record("Failed to start session")
            return
        }

        // Advance beyond 5s TTL
        clock.advance(by: 6.0)

        let action = ComputerControlAction(kind: .click, target: .elementID("doc"), token: token)
        let validation = session.validateAction(action)

        guard case .failure(let err) = validation else {
            Issue.record("Expected failure for expired token")
            return
        }
        #expect(err == .staleOrExpiredToken)
    }

    @Test("Token from another session or superseded revision is rejected")
    func tokenMismatchRejected() {
        let clock = MockClock()
        let session = ComputerControlSession(clock: { clock.now() })
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)

        _ = session.start(goal: "Type text", scope: scope)

        // Issue a second token (revision 2)
        guard case .success(let freshToken) = session.issueToken() else {
            Issue.record("Failed to issue fresh token")
            return
        }

        let foreignToken = ObservationToken(sessionID: UUID(), revision: 1, now: clock.now())
        let staleRevisionToken = ObservationToken(sessionID: session.id, revision: 1, now: clock.now())

        let action1 = ComputerControlAction(kind: .click, target: .elementID("doc"), token: foreignToken)
        guard case .failure(let err1) = session.validateAction(action1) else {
            Issue.record("Expected failure for foreign token")
            return
        }
        #expect(err1 == .staleOrExpiredToken)

        let action2 = ComputerControlAction(kind: .click, target: .elementID("doc"), token: staleRevisionToken)
        guard case .failure(let err2) = session.validateAction(action2) else {
            Issue.record("Expected failure for stale token")
            return
        }
        #expect(err2 == .tokenMismatch)

        let validAction = ComputerControlAction(kind: .click, target: .elementID("doc"), token: freshToken)
        guard case .success = session.validateAction(validAction) else {
            Issue.record("Expected success for valid action")
            return
        }
    }

    @Test("Invalid target location is rejected")
    func invalidTargetLocationRejected() {
        let clock = MockClock()
        let session = ComputerControlSession(clock: { clock.now() })
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)

        guard case .success(let token) = session.start(goal: "Click target", scope: scope) else {
            Issue.record("Failed to start")
            return
        }

        let emptyElement = ComputerControlAction(kind: .click, target: .elementID("   "), token: token)
        guard case .failure(let err1) = session.validateAction(emptyElement) else {
            Issue.record("Expected failure for empty target ID")
            return
        }
        #expect(err1 == .invalidTargetLocation)

        let nonfinitePoint = ComputerControlAction(kind: .click, target: .point(x: .nan, y: 100, displayID: nil), token: token)
        guard case .failure(let err2) = session.validateAction(nonfinitePoint) else {
            Issue.record("Expected failure for NaN point")
            return
        }
        #expect(err2 == .invalidTargetLocation)

        let negativePoint = ComputerControlAction(kind: .click, target: .point(x: -10, y: 50, displayID: nil), token: token)
        guard case .failure(let err3) = session.validateAction(negativePoint) else {
            Issue.record("Expected failure for negative point")
            return
        }
        #expect(err3 == .invalidTargetLocation)

        let outOfBoundsPoint = ComputerControlAction(kind: .click, target: .point(x: 25000, y: 50, displayID: nil), token: token)
        guard case .failure(let err4) = session.validateAction(outOfBoundsPoint) else {
            Issue.record("Expected failure for out of bounds point")
            return
        }
        #expect(err4 == .invalidTargetLocation)
    }

    @Test("Pause invalidates active token and rejects actions until resumed")
    func pauseAndResumeLifecycle() {
        let clock = MockClock()
        let session = ComputerControlSession(clock: { clock.now() })
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)

        guard case .success(let token1) = session.start(goal: "Edit doc", scope: scope) else {
            Issue.record("Failed to start")
            return
        }

        session.pause(reason: .userTakeover)
        #expect(session.state == .paused(goal: "Edit doc", scope: scope, reason: .userTakeover))

        let actionDuringPause = ComputerControlAction(kind: .click, target: .elementID("button"), token: token1)
        guard case .failure(let err1) = session.validateAction(actionDuringPause) else {
            Issue.record("Expected failure during pause")
            return
        }
        #expect(err1 == .sessionPaused(.userTakeover))

        guard case .success(let token2) = session.resume() else {
            Issue.record("Failed to resume")
            return
        }

        #expect(token2.revision == 2)
        #expect(session.state.isActive)

        let actionAfterResume = ComputerControlAction(kind: .click, target: .elementID("button"), token: token2)
        guard case .success = session.validateAction(actionAfterResume) else {
            Issue.record("Expected success after resume")
            return
        }
    }

    @Test("Action limit enforces maximum actions per control run")
    func actionLimitEnforced() {
        let clock = MockClock()
        let session = ComputerControlSession(clock: { clock.now() })
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)

        guard case .success(let token) = session.start(goal: "Spam actions", scope: scope) else {
            Issue.record("Failed to start")
            return
        }

        let action = ComputerControlAction(kind: .click, target: .elementID("item"), token: token)
        for _ in 0..<40 {
            guard case .success = session.validateAction(action) else {
                Issue.record("Expected success within limit")
                return
            }
        }

        guard case .failure(let err) = session.validateAction(action) else {
            Issue.record("Expected failure when action limit reached")
            return
        }
        #expect(err == .actionLimitExceeded)
    }

    @Test("Stop and complete transition state cleanly")
    func stopAndCompleteTransitions() {
        let session = ComputerControlSession()
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", isAuthorized: true)

        _ = session.start(goal: "Task 1", scope: scope)
        session.stop(reason: "User cancelled")
        #expect(session.state == .cancelled(goal: "Task 1", reason: "User cancelled"))

        let session2 = ComputerControlSession()
        _ = session2.start(goal: "Task 2", scope: scope)
        session2.complete(summary: "Calculation done: 42")
        #expect(session2.state == .completed(goal: "Task 2", summary: "Calculation done: 42"))
    }
}
