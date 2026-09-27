import Foundation

/// Defines retry behavior and backoff configuration for transient network and API failures.
public struct RetryPolicy: Sendable {
    public let maxRetries: Int
    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let jitterRange: Range<Double>
    public let sleeper: @Sendable (TimeInterval) async throws -> Void

    public init(
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 8.0,
        jitterRange: Range<Double> = 0.0..<0.25,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { duration in
            guard duration > 0 else { return }
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        }
    ) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = max(0, baseDelay)
        self.maxDelay = max(0, maxDelay)
        self.jitterRange = jitterRange
        self.sleeper = sleeper
    }

    /// Computes exponential backoff delay with bounded jitter for a given retry attempt (0-indexed).
    public func delay(forAttempt attempt: Int, jitter: Double? = nil) -> TimeInterval {
        guard attempt >= 0 else { return 0 }
        let exponentialMultiplier = pow(2.0, Double(attempt))
        let nominalDelay = min(maxDelay, baseDelay * exponentialMultiplier)
        let resolvedJitter: Double
        if let jitter = jitter {
            resolvedJitter = jitter
        } else if jitterRange.isEmpty || jitterRange.lowerBound >= jitterRange.upperBound {
            resolvedJitter = 0.0
        } else {
            resolvedJitter = Double.random(in: jitterRange)
        }
        return nominalDelay + resolvedJitter
    }

    /// Default production retry policy (up to 3 retries with 1s, 2s, 4s backoff + jitter).
    public static let `default` = RetryPolicy()

    /// Policy with zero retries.
    public static let none = RetryPolicy(maxRetries: 0)

    /// Predefined test policy that avoids real-time sleeping.
    public static let testing = RetryPolicy(
        maxRetries: 3,
        baseDelay: 0.0,
        maxDelay: 0.0,
        jitterRange: 0.0..<0.0,
        sleeper: { _ in }
    )

    /// Factory for test environments that customize maxRetries or sleeper while avoiding real-time sleeping.
    public static func testing(
        maxRetries: Int = 3,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { _ in }
    ) -> RetryPolicy {
        RetryPolicy(
            maxRetries: maxRetries,
            baseDelay: 0.0,
            maxDelay: 0.0,
            jitterRange: 0.0..<0.0,
            sleeper: sleeper
        )
    }

    /// Evaluates if an HTTP status code represents a transient error that should be retried.
    public static func isTransientStatusCode(_ statusCode: Int) -> Bool {
        switch statusCode {
        case 408, 429, 500, 502, 503, 504:
            return true
        default:
            return false
        }
    }

    /// Evaluates if an error represents a transient network or socket level failure that should be retried.
    public static func isTransientNetworkError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .networkConnectionLost,
                 .notConnectedToInternet,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .dnsLookupFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}
