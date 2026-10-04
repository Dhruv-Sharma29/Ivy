import Foundation
import os

/// Errors encountered during computer control session management and action validation.
public enum ComputerControlSessionError: Error, LocalizedError, Equatable, Sendable {
    case sessionNotActive
    case unauthorizedScope
    case prohibitedApplication(String)
    case staleOrExpiredToken
    case tokenMismatch
    case invalidTargetLocation
    case sessionPaused(ComputerControlPauseReason)
    case actionLimitExceeded

    public var errorDescription: String? {
        switch self {
        case .sessionNotActive:
            return "No computer control session is currently active."
        case .unauthorizedScope:
            return "The target application has not been authorized for computer control."
        case .prohibitedApplication(let id):
            return "Control of sensitive application '\(id)' is prohibited."
        case .staleOrExpiredToken:
            return "The observation token has expired. Fresh observation required."
        case .tokenMismatch:
            return "Action token does not match the active session revision."
        case .invalidTargetLocation:
            return "The requested click or move target is invalid or out of bounds."
        case .sessionPaused(let reason):
            return "Session is currently paused: \(reason.rawValue)"
        case .actionLimitExceeded:
            return "The maximum allowed actions for this control session was reached."
        }
    }
}

/// Thread-safe manager governing the lifecycle and action authorization of a computer control session.
public final class ComputerControlSession: @unchecked Sendable {
    public let id: UUID
    private let lock = OSAllocatedUnfairLock(initialState: SessionState())
    private let clock: @Sendable () -> Date

    private struct SessionState {
        var state: ComputerControlSessionState = .idle
        var revision: Int = 0
        var currentToken: ObservationToken? = nil
        var actionCount: Int = 0
        let maxActions: Int = 40
    }

    public init(id: UUID = UUID(), clock: @escaping @Sendable () -> Date = { Date() }) {
        self.id = id
        self.clock = clock
    }

    /// Current lifecycle state of the session.
    public var state: ComputerControlSessionState {
        lock.withLock { $0.state }
    }

    /// Currently authorized scope, if any.
    public var currentScope: ComputerControlScope? {
        lock.withLock { $0.state.currentScope }
    }

    /// Requests and activates a session with explicit user consent.
    public func start(goal: String, scope: ComputerControlScope) -> Result<ObservationToken, ComputerControlSessionError> {
        guard scope.isPermittedApp else {
            return .failure(.prohibitedApplication(scope.bundleIdentifier))
        }
        guard scope.isAuthorized else {
            return .failure(.unauthorizedScope)
        }

        return lock.withLock { state -> Result<ObservationToken, ComputerControlSessionError> in
            state.revision += 1
            state.actionCount = 0
            let token = ObservationToken(sessionID: self.id, revision: state.revision, now: self.clock())
            state.currentToken = token
            state.state = .active(goal: goal, scope: scope, token: token)
            return .success(token)
        }
    }

    /// Issues a fresh observation token for the active session (e.g. after a new observation).
    public func issueToken() -> Result<ObservationToken, ComputerControlSessionError> {
        lock.withLock { state -> Result<ObservationToken, ComputerControlSessionError> in
            guard case .active(let goal, let scope, _) = state.state else {
                return .failure(.sessionNotActive)
            }
            state.revision += 1
            let token = ObservationToken(sessionID: self.id, revision: state.revision, now: self.clock())
            state.currentToken = token
            state.state = .active(goal: goal, scope: scope, token: token)
            return .success(token)
        }
    }

    /// Validates an incoming action before it reaches the SafetyGate or executor.
    public func validateAction(_ action: ComputerControlAction) -> Result<Void, ComputerControlSessionError> {
        let now = clock()
        return lock.withLock { state -> Result<Void, ComputerControlSessionError> in
            switch state.state {
            case .paused(_, _, let reason):
                return .failure(.sessionPaused(reason))
            case .active(_, let scope, _):
                guard scope.isAuthorized else {
                    return .failure(.unauthorizedScope)
                }
                guard scope.isPermittedApp else {
                    return .failure(.prohibitedApplication(scope.bundleIdentifier))
                }
                if let target = action.target, !target.isValid {
                    return .failure(.invalidTargetLocation)
                }
                // Actions requiring observation must supply a valid matching token
                if action.kind != .observe {
                    guard let token = action.token else {
                        return .failure(.staleOrExpiredToken)
                    }
                    guard token.isValid(for: self.id, at: now) else {
                        return .failure(.staleOrExpiredToken)
                    }
                    guard let current = state.currentToken, current.id == token.id, current.revision == token.revision else {
                        return .failure(.tokenMismatch)
                    }
                }
                state.actionCount += 1
                if state.actionCount > state.maxActions {
                    return .failure(.actionLimitExceeded)
                }
                return .success(())
            default:
                return .failure(.sessionNotActive)
            }
        }
    }

    /// Pauses the session (e.g. user takeover or window focus loss).
    public func pause(reason: ComputerControlPauseReason) {
        lock.withLock { state in
            if case .active(let goal, let scope, _) = state.state {
                state.currentToken = nil
                state.state = .paused(goal: goal, scope: scope, reason: reason)
            }
        }
    }

    /// Resumes a paused session, issuing a fresh observation token.
    public func resume() -> Result<ObservationToken, ComputerControlSessionError> {
        lock.withLock { state -> Result<ObservationToken, ComputerControlSessionError> in
            guard case .paused(let goal, let scope, _) = state.state else {
                return .failure(.sessionNotActive)
            }
            guard scope.isAuthorized else {
                return .failure(.unauthorizedScope)
            }
            state.revision += 1
            let token = ObservationToken(sessionID: self.id, revision: state.revision, now: self.clock())
            state.currentToken = token
            state.state = .active(goal: goal, scope: scope, token: token)
            return .success(token)
        }
    }

    /// Stops or cancels the session.
    public func stop(reason: String = "User stopped session") {
        lock.withLock { state in
            let goal: String
            switch state.state {
            case .active(let g, _, _), .paused(let g, _, _), .requested(let g, _):
                goal = g
            case .idle, .completed, .cancelled, .failed:
                goal = ""
            }
            state.currentToken = nil
            state.state = .cancelled(goal: goal, reason: reason)
        }
    }

    /// Marks the session successfully completed.
    public func complete(summary: String) {
        lock.withLock { state in
            let goal: String
            switch state.state {
            case .active(let g, _, _), .paused(let g, _, _):
                goal = g
            default:
                goal = ""
            }
            state.currentToken = nil
            state.state = .completed(goal: goal, summary: summary)
        }
    }
}
