import Foundation

/// Why Gemini is refusing requests right now, and when it's worth trying again. Shown in the UI; never a secret.
public struct QuotaStatus: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Short-lived rate limit (requests/tokens per minute).
        case perMinute
        /// The day's free-tier allowance is used up.
        case perDay
    }

    public let kind: Kind
    /// When requests should succeed again, if known.
    public let retryAfter: Date?

    public init(kind: Kind, retryAfter: Date?) {
        self.kind = kind
        self.retryAfter = retryAfter
    }

    /// True while waiting is still required.
    public func isActive(now: Date = Date()) -> Bool {
        guard let retryAfter else { return kind == .perDay }
        return retryAfter > now
    }

    public func message(now: Date = Date()) -> String {
        switch kind {
        case .perMinute:
            guard let retryAfter, retryAfter > now else { return "Gemini is rate limiting requests. Try again in a moment." }
            return "Gemini is rate limiting requests. Try again in \(Int(retryAfter.timeIntervalSince(now).rounded(.up))) s."
        case .perDay:
            guard let retryAfter else { return "Today's Gemini quota is used up. It resets at midnight Pacific time." }
            return "Today's Gemini quota is used up. It resets at \(retryAfter.formatted(date: .omitted, time: .shortened)), or use a key with billing enabled."
        }
    }

    /// Gemini daily quotas reset at midnight Pacific time.
    public static func nextDailyReset(after now: Date = Date()) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .gmt
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
    }

    /// Reads the quota kind and the server's `retryDelay` ("34s") out of a 429 response body.
    static func parse(responseBody data: Data) -> (isDaily: Bool, retryDelay: TimeInterval?) {
        let body = String(decoding: data, as: UTF8.self)
        var delay: TimeInterval? = nil
        if let match = body.range(of: #""retryDelay"\s*:\s*"[0-9.]+s""#, options: .regularExpression) {
            let digits = body[match].drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." }
            delay = TimeInterval(digits)
        }
        return (body.contains("PerDay"), delay)
    }
}
