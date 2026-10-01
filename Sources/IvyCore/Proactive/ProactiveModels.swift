import Foundation
import os

/// Something Ivy will tell the user about later. A trigger can only ever produce a notification (and a
/// suggested prompt the user may choose to send): it never runs a tool.
public struct ProactiveTrigger: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case reminder, followUp, calendarHeadsUp, briefing, watch
        /// An agent task finished, failed or was stopped (Phase 15).
        case taskUpdate
    }

    public enum Schedule: Codable, Equatable, Sendable {
        /// Once, at this moment.
        case at(Date)
        /// Every day at this local wall-clock time. `weekdays` uses Calendar numbering (1 = Sunday); empty = every day.
        case daily(hour: Int, minute: Int, weekdays: Set<Int>)
        /// No time of its own: fires when `condition` becomes true.
        case whenCondition
    }

    /// Local, cheap, observable signals only. No screen watching, no network polling.
    public enum Condition: Codable, Equatable, Sendable {
        case appLaunched(String)
        case appQuit(String)
        case batteryBelow(Int)
        /// A new item appears in a folder the user picked.
        case fileAppeared(folder: String)
    }

    public enum Creator: String, Codable, Sendable {
        case user
        /// Proposed by Ivy and approved by the user on a confirmation card.
        case ivyWithConfirmation
    }

    public let id: UUID
    public var kind: Kind
    public var schedule: Schedule
    public var condition: Condition?
    /// What the user is told. Redacted, at most 500 characters.
    public var message: String
    /// Pre-fills Ivy's input when the user opens the notification. Never sent automatically.
    public var suggestedPrompt: String?
    public var createdBy: Creator
    public var createdAt: Date
    public var lastFiredAt: Date?
    public var isEnabled: Bool

    public static let maxMessageLength = 500

    public init(
        id: UUID = UUID(), kind: Kind, schedule: Schedule, condition: Condition? = nil, message: String,
        suggestedPrompt: String? = nil, createdBy: Creator, createdAt: Date, lastFiredAt: Date? = nil, isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.schedule = schedule
        self.condition = condition
        self.message = String(SecretRedactor.redact(message).prefix(Self.maxMessageLength))
        self.suggestedPrompt = suggestedPrompt.map { String(SecretRedactor.redact($0).prefix(Self.maxMessageLength)) }
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.lastFiredAt = lastFiredAt
        self.isEnabled = isEnabled
    }

    /// The first moment after `reference` this trigger's schedule calls for, in `calendar`'s time zone.
    /// Daily times follow the wall clock: a time that doesn't exist on a DST change day moves to the next
    /// valid moment, and a changed time zone means the new zone's local time.
    public func nextFire(after reference: Date, calendar: Calendar) -> Date? {
        switch schedule {
        case .at(let date):
            return lastFiredAt == nil ? date : nil
        case .whenCondition:
            return nil
        case .daily(let hour, let minute, let weekdays):
            var from = reference
            for _ in 0..<8 {
                guard let next = calendar.nextDate(after: from, matching: DateComponents(hour: hour, minute: minute, second: 0),
                                                   matchingPolicy: .nextTime) else { return nil }
                if weekdays.isEmpty || weekdays.contains(calendar.component(.weekday, from: next)) { return next }
                from = next
            }
            return nil
        }
    }

    /// Why the user is seeing this, shown with every notification.
    public func reason(calendar: Calendar) -> String {
        let day = createdAt.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone))
        switch (kind, createdBy) {
        case (.watch, _): return "You asked me on \(day) to watch for this."
        case (_, .ivyWithConfirmation): return "You approved this on \(day) when I offered."
        case (_, .user): return "You set this up on \(day)."
        }
    }
}

/// One line of the "Proactive activity" list: everything Ivy did on its own initiative, and why.
public struct ProactiveActivity: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case delivered
        /// Held back (quiet hours or the hourly limit) and included in the next digest.
        case deferred
        /// The same message was already shown within the hour.
        case duplicate
        /// Its kind is switched off in settings.
        case disabled
    }

    public let id: UUID
    public let date: Date
    public let kind: ProactiveTrigger.Kind
    public let message: String
    public let reason: String
    public let outcome: Outcome
    public let triggerID: UUID?

    public init(id: UUID = UUID(), date: Date, kind: ProactiveTrigger.Kind, message: String, reason: String, outcome: Outcome, triggerID: UUID?) {
        self.id = id
        self.date = date
        self.kind = kind
        self.message = message
        self.reason = reason
        self.outcome = outcome
        self.triggerID = triggerID
    }
}

/// Everything the proactive engine keeps between launches.
public struct ProactiveState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maxLogEntries = 200

    public var schemaVersion = ProactiveState.currentSchemaVersion
    public var triggers: [ProactiveTrigger] = []
    public var log: [ProactiveActivity] = []
    /// Messages held back for the next digest.
    public var deferred: [String] = []
    /// Day (yyyy-MM-dd, local) the briefing was last produced, so it runs once a day.
    public var lastBriefingDay: String?
    /// Calendar events already announced.
    public var announcedEvents: [String] = []

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, triggers, log, deferred, lastBriefingDay, announcedEvents
    }

    /// Missing fields take their defaults, so a file written before a field existed migrates instead of being
    /// set aside. Unknown or malformed values still fail (and the store quarantines the file).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        triggers = try c.decodeIfPresent([ProactiveTrigger].self, forKey: .triggers) ?? []
        log = try c.decodeIfPresent([ProactiveActivity].self, forKey: .log) ?? []
        deferred = try c.decodeIfPresent([String].self, forKey: .deferred) ?? []
        lastBriefingDay = try c.decodeIfPresent(String.self, forKey: .lastBriefingDay)
        announcedEvents = try c.decodeIfPresent([String].self, forKey: .announcedEvents) ?? []
    }
}

public protocol ProactiveStore: Sendable {
    /// Never throws: a missing file is an empty state; an unreadable one is set aside and reported.
    func load() -> ProactiveState
    func save(_ state: ProactiveState) throws
    func drainRecoveryNotices() -> [String]
}

/// One private JSON file under Application Support/Ivy/Proactive.
public struct FileProactiveStore: ProactiveStore {
    public let directory: URL
    private let notices = NoticeBox()

    public static var defaultDirectory: URL {
        FileConversationStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("Proactive", isDirectory: true)
    }

    public init(directory: URL = FileProactiveStore.defaultDirectory) {
        self.directory = directory
    }

    private var fileURL: URL { directory.appendingPathComponent("state.json") }

    public func load() -> ProactiveState {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return ProactiveState() }
        do {
            let state = try JSONDecoder().decode(ProactiveState.self, from: data)
            guard state.schemaVersion <= ProactiveState.currentSchemaVersion else {
                throw ConversationStoreError.newerSchema(state.schemaVersion)
            }
            return state
        } catch {
            quarantine()
            return ProactiveState()
        }
    }

    public func save(_ state: ProactiveState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func drainRecoveryNotices() -> [String] {
        notices.drain()
    }

    /// An unreadable (or newer-format) file is moved aside, never deleted, so it can be recovered by hand.
    private func quarantine() {
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let folder = directory.deletingLastPathComponent().appendingPathComponent("Quarantine/\(day)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.moveItem(at: fileURL, to: folder.appendingPathComponent("proactive-\(UUID().uuidString).json"))
            notices.add("Ivy's saved reminders couldn't be read and were set aside in \(folder.path).")
        } catch {
            print("[PROACTIVE] state file is unreadable and could not be quarantined: \(error.localizedDescription)")
            notices.add("Ivy's saved reminders couldn't be read.")
        }
    }
}

/// What the user sees.
public struct ProactiveNotification: Equatable, Sendable {
    public let title: String
    public let body: String
    /// Why it appeared.
    public let reason: String
    /// The trigger behind it, if any (digests and briefings have none).
    public let triggerID: UUID?
    public let kind: ProactiveTrigger.Kind

    public init(title: String, body: String, reason: String, triggerID: UUID?, kind: ProactiveTrigger.Kind) {
        self.title = title
        self.body = body
        self.reason = reason
        self.triggerID = triggerID
        self.kind = kind
    }
}

/// What the user can do from a notification. None of these runs a tool.
public enum ProactiveAction: String, CaseIterable, Sendable {
    case open, snooze, done, stop, read
}

public protocol ProactiveDelivering: Sendable {
    func deliver(_ notification: ProactiveNotification) async throws
}

public struct UpcomingEvent: Equatable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let calendar: String

    public init(id: String, title: String, start: Date, calendar: String) {
        self.id = id
        self.title = title
        self.start = start
        self.calendar = calendar
    }
}

/// Local signals the engine may look at. Implementations must never prompt for a permission.
public protocol ProactiveSignals: Sendable {
    func runningApps() -> Set<String>
    /// Nil on a Mac without a battery.
    func batteryPercent() -> Int?
    /// Names of the items in a folder; nil if it can't be read.
    func items(in folder: String) -> Set<String>?
    /// Calendar events starting in the range; empty when Calendar access hasn't been granted.
    func events(from start: Date, to end: Date) -> [UpcomingEvent]
}

/// Keeps proactive state for the life of the process only (tests, and graphs built without a disk store).
public final class InMemoryProactiveStore: ProactiveStore, Sendable {
    private let state: OSAllocatedUnfairLock<ProactiveState>

    public init(_ initial: ProactiveState = ProactiveState()) {
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    public func load() -> ProactiveState { state.withLock { $0 } }
    public func save(_ new: ProactiveState) throws { state.withLock { $0 = new } }
    public func drainRecoveryNotices() -> [String] { [] }
}

/// Stands in where there is no notification centre: everything stays in the digest queue.
public struct UnavailableProactiveDeliverer: ProactiveDelivering {
    public init() {}

    public func deliver(_ notification: ProactiveNotification) async throws {
        throw ProactiveError.unavailable
    }
}

/// Signals that report nothing (no apps, no battery, no events).
public struct NoProactiveSignals: ProactiveSignals {
    public init() {}

    public func runningApps() -> Set<String> { [] }
    public func batteryPercent() -> Int? { nil }
    public func items(in folder: String) -> Set<String>? { nil }
    public func events(from start: Date, to end: Date) -> [UpcomingEvent] { [] }
}
