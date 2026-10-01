import Foundation
import Combine
import os

public enum ProactiveError: Error, LocalizedError, Equatable, Sendable {
    case disabled
    case tooMany
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .disabled:
            return "Proactive Ivy is turned off. The user has to turn it on in Ivy's settings first; Ivy cannot enable it."
        case .tooMany:
            return "There are already \(ProactiveEngine.maxTriggers) reminders and watches. Remove some first."
        case .unavailable:
            return "Reminders aren't available right now."
        }
    }
}

/// How a tool asks for a trigger to be added. The user has already approved it on a confirmation card.
public protocol ProactiveScheduling: Sendable {
    func schedule(_ trigger: ProactiveTrigger) async throws
    /// The engine's idea of "now" (so tools and tests agree on time).
    func currentDate() async -> Date
    /// False while Proactive Ivy is off. Read synchronously during argument validation, so a call that can't
    /// succeed is refused before the user is shown an approval card for it.
    var isAcceptingTriggers: Bool { get }
}

public extension ProactiveScheduling {
    var isAcceptingTriggers: Bool { true }
}

/// Lets tools built before the engine exists reach it afterwards.
public final class ProactiveRelay: ProactiveScheduling, Sendable {
    @MainActor public weak var engine: ProactiveEngine?
    private let accepting = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    /// Mirrors the "Proactive Ivy" master switch (set by the app environment).
    public func setAcceptingTriggers(_ on: Bool) {
        accepting.withLock { $0 = on }
    }

    public var isAcceptingTriggers: Bool {
        accepting.withLock { $0 }
    }

    public func schedule(_ trigger: ProactiveTrigger) async throws {
        guard let engine = await engine else { throw ProactiveError.unavailable }
        try await engine.add(trigger)
    }

    public func currentDate() async -> Date {
        await engine?.currentDate ?? Date()
    }
}

/// Ivy speaking first. Everything here ends in a notification or a suggested prompt; nothing here can run a
/// tool. All of it is off until the user turns on "Proactive Ivy".
@MainActor
public final class ProactiveEngine: ObservableObject {
    public static let maxPerHour = 6
    public static let dedupeWindow: TimeInterval = 3600
    public static let snoozeInterval: TimeInterval = 600
    public nonisolated static let maxTriggers = 100
    /// A reminder this late when Ivy starts (it was closed or the Mac was asleep) goes into the catch-up digest.
    static let lateAfter: TimeInterval = 120

    @Published public private(set) var triggers: [ProactiveTrigger] = []
    @Published public private(set) var activity: [ProactiveActivity] = []
    /// Set when the user opens a notification that carries a suggested prompt. The UI puts it in the input
    /// field; it is never sent for them.
    @Published public var pendingPrompt: String?
    @Published public private(set) var notice: String?

    /// "Stop these" on a notification that isn't backed by a trigger (calendar heads-ups, briefings).
    public var onStopKind: ((ProactiveTrigger.Kind) -> Void)?
    /// "Read to me".
    public var onRead: ((String) -> Void)?
    /// A briefing was produced (for the conversation).
    public var onBriefing: ((String) -> Void)?
    /// Turns the day's local data into prose with one model call. Nil result (no key, quota gone) = use the plain list.
    public var composeBriefing: ((String) async -> String?)?

    private let store: ProactiveStore
    private let deliverer: ProactiveDelivering
    private let signals: ProactiveSignals
    private let settings: () -> IvySettings
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var state: ProactiveState
    private var conditionWasTrue: [UUID: Bool] = [:]
    private var folderItems: [UUID: Set<String>] = [:]
    private var isFirstTick = true
    private var loop: Task<Void, Never>?
    private var isTicking = false

    public init(
        store: ProactiveStore,
        deliverer: ProactiveDelivering,
        signals: ProactiveSignals,
        settings: @escaping () -> IvySettings,
        now: @escaping () -> Date = { Date() },
        calendar: @escaping () -> Calendar = { .current }
    ) {
        self.store = store
        self.deliverer = deliverer
        self.signals = signals
        self.settings = settings
        self.now = now
        self.calendar = calendar
        self.state = store.load()
        self.triggers = state.triggers
        self.activity = state.log
        let notices = store.drainRecoveryNotices()
        self.notice = notices.isEmpty ? nil : notices.joined(separator: " ")
    }

    public var currentDate: Date { now() }

    /// Checks twice a minute. Times are compared against the wall clock on every check rather than slept
    /// towards, so sleep, a changed clock, a new time zone or a DST shift can't make a timer drift.
    public func start(interval: Duration = .seconds(30)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return // stopped
                }
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    public func dismissNotice() {
        notice = nil
    }

    // MARK: - Triggers

    public func add(_ trigger: ProactiveTrigger) throws {
        guard settings().proactiveEnabled else { throw ProactiveError.disabled }
        guard state.triggers.filter(\.isEnabled).count < Self.maxTriggers else { throw ProactiveError.tooMany }
        state.triggers.append(trigger)
        persist()
    }

    public func remove(_ id: UUID) {
        state.triggers.removeAll { $0.id == id }
        conditionWasTrue[id] = nil
        folderItems[id] = nil
        persist()
    }

    /// Notification buttons. None of these can run a tool.
    public func handle(_ action: ProactiveAction, triggerID: UUID?, kind: ProactiveTrigger.Kind, body: String) {
        let index = triggerID.flatMap { id in state.triggers.firstIndex { $0.id == id } }
        switch action {
        case .open:
            pendingPrompt = index.flatMap { state.triggers[$0].suggestedPrompt }
        case .read:
            onRead?(body)
        case .done:
            if let index, state.triggers[index].schedule != .whenCondition, case .at = state.triggers[index].schedule {
                state.triggers[index].isEnabled = false
            }
        case .snooze:
            // A fresh one-shot, so a daily reminder keeps its own schedule.
            state.triggers.append(ProactiveTrigger(
                kind: .reminder, schedule: .at(now().addingTimeInterval(Self.snoozeInterval)), message: body,
                suggestedPrompt: index.flatMap { state.triggers[$0].suggestedPrompt }, createdBy: .user, createdAt: now()))
        case .stop:
            if let index {
                let id = state.triggers[index].id
                state.triggers.remove(at: index)
                conditionWasTrue[id] = nil
                folderItems[id] = nil
            } else {
                onStopKind?(kind)
            }
        }
        persist()
    }

    // MARK: - Tick

    /// One pass over everything that might be due. Safe to call at any time (wake from sleep, clock change).
    public func tick() async {
        guard !isTicking else { return }
        isTicking = true
        defer { isTicking = false }

        let settings = settings()
        let catchingUp = isFirstTick
        isFirstTick = false
        guard settings.proactiveEnabled else { return }
        let now = now()
        let calendar = calendar()

        // 1. Time-based triggers.
        for trigger in state.triggers where trigger.isEnabled && trigger.condition == nil {
            guard let due = trigger.nextFire(after: trigger.lastFiredAt ?? trigger.createdAt, calendar: calendar), due <= now else { continue }
            markFired(trigger.id, at: now, disable: { if case .at = trigger.schedule { return true } else { return false } }())
            await announce(trigger.message, title: title(for: trigger.kind), reason: trigger.reason(calendar: calendar), kind: trigger.kind,
                           triggerID: trigger.id, digestOnly: catchingUp && now.timeIntervalSince(due) > Self.lateAfter, settings: settings)
        }

        // 2. Conditions: fire when one becomes true, not while it stays true.
        if settings.proactiveReminders {
            for trigger in state.triggers where trigger.isEnabled {
                guard let condition = trigger.condition, let message = newlyTrue(condition, for: trigger) else { continue }
                // A folder watch keeps watching; the others are one-shot.
                let keeps: Bool = { if case .fileAppeared = condition { return true } else { return false } }()
                markFired(trigger.id, at: now, disable: !keeps)
                await announce(message, title: title(for: trigger.kind), reason: trigger.reason(calendar: calendar), kind: trigger.kind,
                               triggerID: trigger.id, digestOnly: false, settings: settings)
            }
        }

        // 3. Calendar heads-up: title and start time only, and only for calendars the user named.
        if settings.proactiveCalendar, !settings.headsUpCalendars.isEmpty {
            let allowed = Set(settings.headsUpCalendars.map { $0.lowercased() })
            let soon = signals.events(from: now, to: now.addingTimeInterval(TimeInterval(settings.headsUpMinutes * 60)))
            for event in soon where allowed.contains(event.calendar.lowercased()) && !state.announcedEvents.contains(event.id) {
                state.announcedEvents = Array((state.announcedEvents + [event.id]).suffix(200))
                let time = event.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))
                await announce("\(event.title) starts at \(time).", title: "Coming up",
                               reason: "You turned on calendar heads-ups for \(event.calendar).", kind: .calendarHeadsUp,
                               triggerID: nil, digestOnly: false, settings: settings)
            }
        }

        // 4. Daily briefing: once a day, at the chosen time or the first check after it (and after quiet hours).
        let today = dayKey(now, calendar)
        if settings.proactiveBriefing, state.lastBriefingDay != today, !isQuiet(now, calendar, settings),
           minutesIntoDay(now, calendar) >= settings.briefingMinutes {
            state.lastBriefingDay = today
            let data = briefingData(now: now, calendar: calendar, settings: settings)
            let text = await composeBriefing?(data) ?? data
            onBriefing?(text)
            await announce(text, title: "Your day", reason: "You turned on the daily briefing.", kind: .briefing,
                           triggerID: nil, digestOnly: false, settings: settings)
        }

        // 5. One digest for everything that was held back.
        if !state.deferred.isEmpty, !isQuiet(now, calendar, settings), deliveredInLastHour(now) < Self.maxPerHour {
            let held = state.deferred
            let lines = held.prefix(8).map { "• \($0)" } + (held.count > 8 ? ["…and \(held.count - 8) more"] : [])
            do {
                try await deliverer.deliver(ProactiveNotification(
                    title: held.count == 1 ? "While you were away" : "While you were away (\(held.count))",
                    body: lines.joined(separator: "\n"), reason: "These were held back during quiet hours, or while Ivy was closed or busy.",
                    triggerID: nil, kind: .reminder))
                state.deferred = []
                record(.reminder, "Digest of \(held.count) held notification(s)", "Held notifications are delivered together.", .delivered, nil, now)
            } catch {
                print("[PROACTIVE] digest not delivered: \(error.localizedDescription)")
            }
        }

        // Finished one-shots are forgotten after a week.
        state.triggers.removeAll { !$0.isEnabled && now.timeIntervalSince($0.lastFiredAt ?? $0.createdAt) > 7 * 86400 }
        persist()
    }

    // MARK: - Gatekeeper

    private func announce(
        _ body: String, title: String, reason: String, kind: ProactiveTrigger.Kind, triggerID: UUID?, digestOnly: Bool, settings: IvySettings
    ) async {
        let now = now()
        let body = String(SecretRedactor.redact(body).prefix(ProactiveTrigger.maxMessageLength))
        guard isKindEnabled(kind, settings) else {
            record(kind, body, reason, .disabled, triggerID, now)
            return
        }
        let recently = state.log.contains {
            $0.message == body && ($0.outcome == .delivered || $0.outcome == .deferred) && now.timeIntervalSince($0.date) < Self.dedupeWindow
        }
        guard !recently else {
            record(kind, body, reason, .duplicate, triggerID, now)
            return
        }
        guard !digestOnly, !isQuiet(now, calendar(), settings), deliveredInLastHour(now) < Self.maxPerHour else {
            state.deferred.append(body)
            record(kind, body, reason, .deferred, triggerID, now)
            return
        }
        do {
            try await deliverer.deliver(ProactiveNotification(title: title, body: body, reason: reason, triggerID: triggerID, kind: kind))
            record(kind, body, reason, .delivered, triggerID, now)
        } catch {
            // Not lost: it goes out with the next digest.
            print("[PROACTIVE] notification not delivered: \(error.localizedDescription)")
            state.deferred.append(body)
            record(kind, body, reason, .deferred, triggerID, now)
        }
    }

    private func isKindEnabled(_ kind: ProactiveTrigger.Kind, _ settings: IvySettings) -> Bool {
        switch kind {
        case .reminder, .followUp, .watch: return settings.proactiveReminders
        case .calendarHeadsUp: return settings.proactiveCalendar
        case .briefing: return settings.proactiveBriefing
        }
    }

    private func deliveredInLastHour(_ now: Date) -> Int {
        state.log.filter { $0.outcome == .delivered && now.timeIntervalSince($0.date) < 3600 && now.timeIntervalSince($0.date) >= 0 }.count
    }

    func isQuiet(_ date: Date, _ calendar: Calendar, _ settings: IvySettings) -> Bool {
        guard settings.quietHoursEnabled, settings.quietStartMinutes != settings.quietEndMinutes else { return false }
        let minute = minutesIntoDay(date, calendar)
        let (start, end) = (settings.quietStartMinutes, settings.quietEndMinutes)
        return start < end ? (start..<end).contains(minute) : (minute >= start || minute < end)
    }

    private func minutesIntoDay(_ date: Date, _ calendar: Calendar) -> Int {
        calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    }

    private func dayKey(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: - Conditions

    /// The message to show if `condition` has just become true; nil otherwise. The first look only records
    /// the starting point, so "tell me when Xcode opens" doesn't fire because Xcode is already open.
    private func newlyTrue(_ condition: ProactiveTrigger.Condition, for trigger: ProactiveTrigger) -> String? {
        if case .fileAppeared(let folder) = condition {
            guard let current = signals.items(in: folder) else { return nil }
            defer { folderItems[trigger.id] = current }
            guard let before = folderItems[trigger.id] else { return nil }
            let added = current.subtracting(before).sorted()
            guard !added.isEmpty else { return nil }
            return "\(trigger.message): \(added.prefix(3).joined(separator: ", "))" + (added.count > 3 ? " and \(added.count - 3) more" : "")
        }
        let isTrue: Bool
        switch condition {
        case .appLaunched(let app): isTrue = isRunning(app)
        case .appQuit(let app): isTrue = !isRunning(app)
        case .batteryBelow(let percent):
            guard let level = signals.batteryPercent() else { return nil }
            isTrue = level < percent
        case .fileAppeared: return nil
        }
        defer { conditionWasTrue[trigger.id] = isTrue }
        guard let before = conditionWasTrue[trigger.id] else { return nil }
        return !before && isTrue ? trigger.message : nil
    }

    private func isRunning(_ app: String) -> Bool {
        signals.runningApps().contains { $0.caseInsensitiveCompare(app) == .orderedSame }
    }

    // MARK: - Briefing

    /// Built from what is on this Mac only: allow-listed calendar events, and Ivy's own reminders due today.
    private func briefingData(now: Date, calendar: Calendar, settings: IvySettings) -> String {
        var lines: [String] = []
        let endOfDay = calendar.startOfDay(for: now).addingTimeInterval(86400)
        if settings.proactiveCalendar, !settings.headsUpCalendars.isEmpty {
            let allowed = Set(settings.headsUpCalendars.map { $0.lowercased() })
            for event in signals.events(from: now, to: endOfDay).filter({ allowed.contains($0.calendar.lowercased()) }).prefix(10) {
                let time = event.start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))
                lines.append("\(time) — \(event.title)")
            }
        }
        for trigger in state.triggers where trigger.isEnabled && trigger.condition == nil {
            if let due = trigger.nextFire(after: trigger.lastFiredAt ?? trigger.createdAt, calendar: calendar), due < endOfDay {
                let time = due.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone))
                lines.append("\(time) — reminder: \(trigger.message)")
            }
        }
        if !state.deferred.isEmpty { lines.append("\(state.deferred.count) notification(s) were held for you.") }
        return lines.isEmpty ? "Nothing scheduled for today." : lines.joined(separator: "\n")
    }

    // MARK: - Bookkeeping

    private func title(for kind: ProactiveTrigger.Kind) -> String {
        switch kind {
        case .reminder: return "Reminder"
        case .followUp: return "Following up"
        case .watch: return "You asked me to tell you"
        case .calendarHeadsUp: return "Coming up"
        case .briefing: return "Your day"
        }
    }

    private func markFired(_ id: UUID, at date: Date, disable: Bool) {
        guard let index = state.triggers.firstIndex(where: { $0.id == id }) else { return }
        state.triggers[index].lastFiredAt = date
        if disable { state.triggers[index].isEnabled = false }
    }

    private func record(_ kind: ProactiveTrigger.Kind, _ message: String, _ reason: String, _ outcome: ProactiveActivity.Outcome, _ triggerID: UUID?, _ date: Date) {
        state.log.append(ProactiveActivity(date: date, kind: kind, message: message, reason: reason, outcome: outcome, triggerID: triggerID))
        if state.log.count > ProactiveState.maxLogEntries {
            state.log.removeFirst(state.log.count - ProactiveState.maxLogEntries)
        }
    }

    private func persist() {
        if triggers != state.triggers { triggers = state.triggers }
        if activity != state.log { activity = state.log }
        do {
            try store.save(state)
        } catch {
            print("[PROACTIVE] failed to save state: \(error.localizedDescription)")
            notice = "Ivy's reminders couldn't be saved: \(error.localizedDescription)"
        }
    }
}
