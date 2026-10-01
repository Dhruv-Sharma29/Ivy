import Testing
import Foundation
import os
@testable import IvyCore

// MARK: - Fakes (virtual clock, recording deliverer, scripted signals; nothing here touches macOS)

/// The engine's "now". Moved by hand, so weeks of schedule run in milliseconds.
private final class VirtualClock: @unchecked Sendable {
    private let date: OSAllocatedUnfairLock<Date>
    init(_ start: Date) { date = OSAllocatedUnfairLock(initialState: start) }
    var now: Date { date.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { date.withLock { $0 = $0.addingTimeInterval(seconds) } }
    func set(_ new: Date) { date.withLock { $0 = new } }
}

private final class RecordingDeliverer: ProactiveDelivering, @unchecked Sendable {
    private let sent = OSAllocatedUnfairLock(initialState: [(ProactiveNotification, Date)]())
    private let clock: VirtualClock
    var fails = false
    init(clock: VirtualClock) { self.clock = clock }
    func deliver(_ notification: ProactiveNotification) async throws {
        if fails { throw ProactiveError.unavailable }
        let at = clock.now
        sent.withLock { $0.append((notification, at)) }
    }
    var notifications: [ProactiveNotification] { sent.withLock { $0.map(\.0) } }
    var times: [Date] { sent.withLock { $0.map(\.1) } }
}

private final class ScriptedSignals: ProactiveSignals, @unchecked Sendable {
    private struct State {
        var apps: Set<String> = []
        var battery: Int? = nil
        var folders: [String: Set<String>] = [:]
        var events: [UpcomingEvent] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    func setApps(_ apps: Set<String>) { state.withLock { $0.apps = apps } }
    func setBattery(_ level: Int?) { state.withLock { $0.battery = level } }
    func setFolder(_ path: String, _ items: Set<String>) { state.withLock { $0.folders[path] = items } }
    func setEvents(_ events: [UpcomingEvent]) { state.withLock { $0.events = events } }

    func runningApps() -> Set<String> { state.withLock { $0.apps } }
    func batteryPercent() -> Int? { state.withLock { $0.battery } }
    func items(in folder: String) -> Set<String>? { state.withLock { $0.folders[folder] } }
    func events(from start: Date, to end: Date) -> [UpcomingEvent] {
        state.withLock { $0.events.filter { $0.start >= start && $0.start <= end } }
    }
}

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 2026-10-01 at the given UTC time.
private func oct1(_ hour: Int, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: hour, minute: minute))!
}

/// One engine wired to fakes, with Proactive Ivy switched on (quiet hours 22:00–08:00 as by default).
@MainActor
private final class Harness {
    let clock: VirtualClock
    let deliverer: RecordingDeliverer
    let signals = ScriptedSignals()
    let store: ProactiveStore
    var settings: IvySettings
    var calendar = utc
    private(set) var engine: ProactiveEngine!

    init(at start: Date = oct1(12), store: ProactiveStore = InMemoryProactiveStore(), configure: (inout IvySettings) -> Void = { _ in }) {
        clock = VirtualClock(start)
        deliverer = RecordingDeliverer(clock: clock)
        self.store = store
        var s = IvySettings.defaults
        s.proactiveEnabled = true
        configure(&s)
        settings = s
        engine = ProactiveEngine(store: store, deliverer: deliverer, signals: signals,
                                 settings: { [unowned self] in self.settings }, now: { [clock] in clock.now },
                                 calendar: { [unowned self] in self.calendar })
    }

    @discardableResult
    func remind(_ message: String, at date: Date, kind: ProactiveTrigger.Kind = .reminder, prompt: String? = nil) throws -> ProactiveTrigger {
        let trigger = ProactiveTrigger(kind: kind, schedule: .at(date), message: message, suggestedPrompt: prompt,
                                       createdBy: .ivyWithConfirmation, createdAt: clock.now)
        try engine.add(trigger)
        return trigger
    }

    @discardableResult
    func watch(_ condition: ProactiveTrigger.Condition, _ message: String = "Heads up") throws -> ProactiveTrigger {
        let trigger = ProactiveTrigger(kind: .watch, schedule: .whenCondition, condition: condition, message: message,
                                       createdBy: .user, createdAt: clock.now)
        try engine.add(trigger)
        return trigger
    }

    var titles: [String] { deliverer.notifications.map(\.title) }
    var bodies: [String] { deliverer.notifications.map(\.body) }
}

/// Deterministic pseudo-random numbers for the rate-limit property test.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

// MARK: - Opt-in and gatekeeper

@MainActor
@Suite("Phase 12 - Opt-in and gatekeeper")
struct Phase12GatekeeperTests {
    @Test("off by default: nothing can be added and nothing fires")
    func offByDefault() async throws {
        #expect(IvySettings.defaults.proactiveEnabled == false)
        let h = Harness { $0.proactiveEnabled = false }
        #expect(throws: ProactiveError.disabled) {
            try h.engine.add(ProactiveTrigger(kind: .reminder, schedule: .at(oct1(11)), message: "x", createdBy: .user, createdAt: oct1(11)))
        }
        await h.engine.tick()
        #expect(h.deliverer.notifications.isEmpty)
    }

    @Test("a reminder fires once at its time, not before, and says why it appeared")
    func reminderFiresOnTime() async throws {
        let h = Harness()
        let trigger = try h.remind("Stretch", at: oct1(12, 20))
        await h.engine.tick()
        #expect(h.deliverer.notifications.isEmpty)

        h.clock.set(oct1(12, 20))
        await h.engine.tick()
        #expect(h.bodies == ["Stretch"])
        #expect(h.deliverer.notifications.first?.triggerID == trigger.id)
        #expect(h.deliverer.notifications.first?.reason.contains("approved") == true)

        h.clock.advance(3600)
        await h.engine.tick()
        #expect(h.bodies == ["Stretch"], "a one-shot never fires twice")
        #expect(h.engine.triggers.first?.isEnabled == false)
    }

    @Test("quiet hours hold notifications for one digest afterwards; nothing is dropped")
    func quietHoursDefer() async throws {
        let h = Harness(at: oct1(22, 30))
        try h.remind("Bins", at: oct1(22, 40))
        try h.remind("Plants", at: oct1(23, 0))
        h.clock.set(oct1(23, 1))
        await h.engine.tick()
        #expect(h.deliverer.notifications.isEmpty)
        #expect(h.engine.activity.filter { $0.outcome == .deferred }.count == 2)

        h.clock.set(oct1(8, 1).addingTimeInterval(86400))
        await h.engine.tick()
        #expect(h.titles == ["While you were away (2)"])
        #expect(h.bodies.first?.contains("Bins") == true && h.bodies.first?.contains("Plants") == true)
    }

    @Test("at most 6 notifications an hour; the rest wait for a digest")
    func hourlyRateLimit() async throws {
        let h = Harness()
        for i in 1...8 { try h.remind("Reminder \(i)", at: oct1(12, 5)) }
        h.clock.set(oct1(12, 5))
        await h.engine.tick()
        #expect(h.deliverer.notifications.count == 6)

        h.clock.advance(61 * 60)
        await h.engine.tick()
        #expect(h.deliverer.notifications.count == 7)
        #expect(h.titles.last == "While you were away (2)")
    }

    @Test("an identical message within the hour is skipped as a duplicate")
    func dedupe() async throws {
        let h = Harness()
        try h.remind("Drink water", at: oct1(12, 5))
        try h.remind("Drink water", at: oct1(12, 6))
        await h.engine.tick() // past the launch catch-up
        h.clock.set(oct1(12, 7))
        await h.engine.tick()
        #expect(h.bodies == ["Drink water"])
        #expect(h.engine.activity.contains { $0.outcome == .duplicate })
    }

    @Test("reminders missed while Ivy was closed arrive as one catch-up digest, not a burst")
    func catchUpDigest() async throws {
        let h = Harness()
        try h.remind("Call the bank", at: oct1(11, 0))
        try h.remind("Pay rent", at: oct1(11, 30))
        await h.engine.tick() // the first check after launch
        #expect(h.titles == ["While you were away (2)"])
    }

    @Test("a kind switched off is recorded but never shown")
    func kindSwitchedOff() async throws {
        let h = Harness { $0.proactiveReminders = false }
        try h.remind("Hidden", at: oct1(12, 1))
        h.clock.set(oct1(12, 2))
        await h.engine.tick()
        #expect(h.deliverer.notifications.isEmpty)
        #expect(h.engine.activity.last?.outcome == .disabled)
    }

    @Test("a failed delivery is not lost: it goes out with the next digest")
    func failedDeliveryIsDeferred() async throws {
        let h = Harness()
        try h.remind("Retry me", at: oct1(12, 1))
        h.clock.set(oct1(12, 2))
        h.deliverer.fails = true
        await h.engine.tick()
        h.deliverer.fails = false
        h.clock.advance(30)
        await h.engine.tick()
        #expect(h.bodies.count == 1)
        #expect(h.bodies.first?.contains("Retry me") == true)
    }

    @Test("property: no mix of schedules ever shows more than 6 notifications in any hour")
    func neverExceedsRateLimit() async throws {
        var rng = SeededGenerator(state: 42)
        let h = Harness { $0.quietHoursEnabled = false }
        for i in 0..<60 {
            let offset = TimeInterval(Int.random(in: 60...(3 * 3600), using: &rng))
            try h.remind("Reminder \(i)", at: oct1(12).addingTimeInterval(offset))
        }
        await h.engine.tick()
        for _ in 0..<(5 * 120) { // 5 hours of 30-second checks
            h.clock.advance(30)
            await h.engine.tick()
        }
        let times = h.deliverer.times
        for (i, start) in times.enumerated() {
            let inWindow = times[i...].prefix { $0.timeIntervalSince(start) < 3600 }.count
            #expect(inWindow <= ProactiveEngine.maxPerHour)
        }
        #expect(!times.isEmpty)
    }
}

// MARK: - Scheduling

@Suite("Phase 12 - Scheduling across clocks and time zones")
struct Phase12ScheduleTests {
    private func daily(_ hour: Int, _ minute: Int, weekdays: Set<Int> = [], created: Date) -> ProactiveTrigger {
        ProactiveTrigger(kind: .reminder, schedule: .daily(hour: hour, minute: minute, weekdays: weekdays), message: "Daily",
                         createdBy: .user, createdAt: created)
    }

    @Test("daily times follow the local wall clock")
    func dailyWallClock() {
        let next = daily(9, 15, created: oct1(12)).nextFire(after: oct1(12), calendar: utc)
        #expect(next == oct1(9, 15).addingTimeInterval(86400))
    }

    @Test("weekday filters skip the other days")
    func weekdays() throws {
        // 2026-10-01 is a Thursday; Monday is weekday 2.
        let next = try #require(daily(9, 0, weekdays: [2], created: oct1(12)).nextFire(after: oct1(12), calendar: utc))
        #expect(utc.component(.weekday, from: next) == 2)
        #expect(utc.component(.day, from: next) == 5)
    }

    @Test("a changed time zone means the new zone's local time")
    func timeZoneChange() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let next = try #require(daily(9, 0, created: oct1(12)).nextFire(after: oct1(12), calendar: tokyo))
        #expect(tokyo.component(.hour, from: next) == 9)
        #expect(utc.component(.hour, from: next) == 0)
    }

    @Test("DST: a time that doesn't exist that day still fires that day; the next day is back on time")
    func daylightSaving() throws {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // US spring-forward 2026: Sunday 8 March, 02:00 → 03:00, so 02:30 doesn't exist.
        let saturdayNoon = try #require(la.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12)))
        let trigger = daily(2, 30, created: saturdayNoon)
        let onTheDay = try #require(trigger.nextFire(after: saturdayNoon, calendar: la))
        #expect(la.component(.day, from: onTheDay) == 8)
        let after = try #require(trigger.nextFire(after: onTheDay, calendar: la))
        #expect(la.component(.day, from: after) == 9)
        #expect(la.component(.hour, from: after) == 2 && la.component(.minute, from: after) == 30)
    }

    @MainActor
    @Test("a daily reminder fires once a day, and a week asleep produces one catch-up, not seven")
    func dailyAcrossSleep() async throws {
        let h = Harness { $0.quietHoursEnabled = false }
        try h.engine.add(daily(13, 0, created: oct1(12)))
        h.clock.set(oct1(13, 0))
        await h.engine.tick()
        h.clock.advance(30)
        await h.engine.tick()
        #expect(h.deliverer.notifications.count == 1)

        h.clock.advance(7 * 86400) // the Mac slept for a week
        await h.engine.tick()
        #expect(h.deliverer.notifications.count == 2)
    }
}

// MARK: - Conditions, calendar heads-up, briefing

@MainActor
@Suite("Phase 12 - Conditions, heads-ups and the briefing")
struct Phase12SourcesTests {
    @Test("app launched: fires when it opens, not because it was already open, and only once")
    func appLaunched() async throws {
        let h = Harness()
        h.signals.setApps(["Xcode"])
        try h.watch(.appLaunched("xcode"), "Xcode is up")
        await h.engine.tick()
        #expect(h.deliverer.notifications.isEmpty, "already running at the first look")

        h.signals.setApps([])
        h.clock.advance(30)
        await h.engine.tick()
        h.signals.setApps(["Xcode"])
        h.clock.advance(30)
        await h.engine.tick()
        h.signals.setApps([])
        h.clock.advance(30)
        await h.engine.tick()
        h.signals.setApps(["Xcode"])
        h.clock.advance(30)
        await h.engine.tick()
        #expect(h.bodies == ["Xcode is up"])
    }

    @Test("app quit and battery below fire on the transition")
    func quitAndBattery() async throws {
        let h = Harness()
        h.signals.setApps(["Music"])
        h.signals.setBattery(50)
        try h.watch(.appQuit("Music"), "Music closed")
        try h.watch(.batteryBelow(20), "Battery low")
        await h.engine.tick()
        h.signals.setApps([])
        h.signals.setBattery(15)
        h.clock.advance(30)
        await h.engine.tick()
        #expect(Set(h.bodies) == ["Music closed", "Battery low"])
    }

    @Test("folder watch: reports new items and keeps watching")
    func folderWatch() async throws {
        let h = Harness()
        h.signals.setFolder("/Users/me/Downloads", ["a.pdf"])
        let trigger = try h.watch(.fileAppeared(folder: "/Users/me/Downloads"), "New in Downloads")
        await h.engine.tick()
        #expect(h.deliverer.notifications.isEmpty)

        h.signals.setFolder("/Users/me/Downloads", ["a.pdf", "b.zip"])
        h.clock.advance(30)
        await h.engine.tick()
        #expect(h.bodies == ["New in Downloads: b.zip"])
        #expect(h.engine.triggers.first { $0.id == trigger.id }?.isEnabled == true)
    }

    @Test("calendar heads-up: only named calendars, title and time only, once per event")
    func calendarHeadsUp() async throws {
        let h = Harness {
            $0.proactiveCalendar = true
            $0.headsUpCalendars = ["Work"]
        }
        h.signals.setEvents([
            UpcomingEvent(id: "1", title: "Standup", start: oct1(12, 5), calendar: "work"),
            UpcomingEvent(id: "2", title: "Dentist", start: oct1(12, 6), calendar: "Home"),
        ])
        await h.engine.tick()
        h.clock.advance(30)
        await h.engine.tick()
        #expect(h.bodies.count == 1)
        #expect(h.bodies.first?.hasPrefix("Standup starts at") == true)
    }

    @Test("no calendars named means no heads-ups at all")
    func calendarHeadsUpNeedsAllowList() async throws {
        let h = Harness { $0.proactiveCalendar = true }
        h.signals.setEvents([UpcomingEvent(id: "1", title: "Standup", start: oct1(12, 5), calendar: "Work")])
        await h.engine.tick()
        #expect(h.deliverer.notifications.isEmpty)
    }

    @Test("briefing: once a day after its time, worded by one model call, plain list when that fails")
    func briefing() async throws {
        let h = Harness { $0.proactiveBriefing = true }
        var inputs: [String] = []
        var added: [String] = []
        h.engine.composeBriefing = { data in inputs.append(data); return inputs.count == 1 ? "Quiet day, for once." : nil }
        h.engine.onBriefing = { added.append($0) }
        try h.remind("Dentist", at: oct1(17))

        await h.engine.tick()
        h.clock.advance(30)
        await h.engine.tick()
        #expect(inputs.count == 1, "once a day")
        #expect(inputs.first?.contains("reminder: Dentist") == true, "built from local data")
        #expect(added == ["Quiet day, for once."])
        #expect(h.titles.contains("Your day"))

        h.clock.advance(86400)
        await h.engine.tick()
        #expect(inputs.count == 2)
        #expect(added.last == inputs.last, "without a model the plain list is used")
    }

    @Test("briefing waits for its time and for quiet hours to end")
    func briefingWaits() async throws {
        let h = Harness(at: oct1(7, 0)) { $0.proactiveBriefing = true }
        var calls = 0
        h.engine.composeBriefing = { _ in calls += 1; return nil }
        await h.engine.tick()
        #expect(calls == 0, "07:00 is inside quiet hours and before 08:30")
        h.clock.set(oct1(8, 31))
        await h.engine.tick()
        #expect(calls == 1)
    }
}

// MARK: - Notification actions

@MainActor
@Suite("Phase 12 - Notification actions")
struct Phase12ActionTests {
    @Test("open pre-fills the suggested prompt and sends nothing")
    func open() throws {
        let h = Harness()
        let trigger = try h.remind("Check the build", at: oct1(13), prompt: "Did the build pass?")
        h.engine.handle(.open, triggerID: trigger.id, kind: .reminder, body: "Check the build")
        #expect(h.engine.pendingPrompt == "Did the build pass?")
    }

    @Test("snooze schedules the same text 10 minutes out; done and stop retire the trigger")
    func snoozeDoneStop() throws {
        let h = Harness()
        let first = try h.remind("Stretch", at: oct1(12))
        h.engine.handle(.snooze, triggerID: first.id, kind: .reminder, body: "Stretch")
        let snoozed = try #require(h.engine.triggers.last)
        #expect(snoozed.schedule == .at(oct1(12, 10)))
        #expect(snoozed.message == "Stretch")

        h.engine.handle(.done, triggerID: first.id, kind: .reminder, body: "Stretch")
        #expect(h.engine.triggers.first { $0.id == first.id }?.isEnabled == false)

        h.engine.handle(.stop, triggerID: snoozed.id, kind: .reminder, body: "Stretch")
        #expect(!h.engine.triggers.contains { $0.id == snoozed.id })
    }

    @Test("stop on a heads-up or briefing switches that kind off; read hands the text to the voice")
    func stopKindAndRead() {
        let h = Harness()
        var stopped: [ProactiveTrigger.Kind] = []
        var read: [String] = []
        h.engine.onStopKind = { stopped.append($0) }
        h.engine.onRead = { read.append($0) }
        h.engine.handle(.stop, triggerID: nil, kind: .calendarHeadsUp, body: "")
        h.engine.handle(.read, triggerID: nil, kind: .briefing, body: "Your day")
        #expect(stopped == [.calendarHeadsUp])
        #expect(read == ["Your day"])
    }

    @Test("messages are redacted before they are stored or shown")
    func redaction() throws {
        let h = Harness()
        // Built at runtime so the source never holds a key-shaped literal.
        let fakeKey = "AIza" + String(repeating: "x", count: 35)
        let trigger = try h.remind("Rotate key \(fakeKey)", at: oct1(12, 1))
        #expect(!trigger.message.contains(fakeKey))
        #expect(trigger.message.contains(SecretRedactor.placeholder))
    }
}

// MARK: - schedule_followup and SafetyGate

@MainActor
@Suite("Phase 12 - schedule_followup")
struct Phase12ToolTests {
    private func setUp(accepting: Bool = true) -> (Harness, ProactiveRelay, ScheduleFollowUpTool) {
        let h = Harness()
        let relay = ProactiveRelay()
        relay.engine = h.engine
        relay.setAcceptingTriggers(accepting)
        return (h, relay, ScheduleFollowUpTool(scheduler: relay, calendar: { utc }))
    }

    private func call(_ args: [String: AnyCodable]) -> FunctionCall {
        FunctionCall(name: "schedule_followup", args: args, id: "call-1")
    }

    @Test("always risky, in the productivity group")
    func classification() {
        let (_, _, tool) = setUp()
        #expect(SafetyPolicy().classification(for: tool, call: call(["message": "x", "in_minutes": 5])) == .risky)
        #expect(tool.group == .productivity)
    }

    @Test("arguments: exactly one of in_minutes / at / when, and each option's limits")
    func validation() {
        let (_, _, tool) = setUp()
        let bad: [[String: AnyCodable]] = [
            ["message": "x"],
            ["message": "x", "in_minutes": 5, "at": "2026-10-02 10:00"],
            ["message": "x", "in_minutes": 0],
            ["message": "x", "in_minutes": 20_000],
            ["message": "x", "in_minutes": 5, "repeat_daily": true],
            ["message": "x", "when": "battery_below", "percent": 99],
            ["message": "x", "when": "battery_below", "percent": 20, "app": "Mail"],
            ["message": "x", "when": "app_launched"],
            ["message": "x", "when": "app_launched", "app": "../Xcode"],
            ["message": "x", "when": "screen_changed"],
            ["message": "", "in_minutes": 5],
            ["message": "x", "in_minutes": 5, "run": "rm -rf ~"],
        ]
        for args in bad {
            #expect(throws: ToolError.self) { try tool.validate(arguments: args) }
        }
        #expect(throws: Never.self) { try tool.validate(arguments: ["message": "Stretch", "in_minutes": 20]) }
        #expect(throws: Never.self) { try tool.validate(arguments: ["message": "x", "when": "app_launched", "app": "Xcode"]) }
    }

    @Test("an approved call becomes a trigger the engine holds; it only ever notifies")
    func schedules() async throws {
        let (h, _, tool) = setUp()
        let result = try await tool.execute(arguments: ["message": "Stretch", "in_minutes": 20, "suggested_prompt": "Stretched?"])
        #expect(!result.isError)
        let trigger = try #require(h.engine.triggers.first)
        #expect(trigger.schedule == .at(oct1(12, 20)))
        #expect(trigger.createdBy == .ivyWithConfirmation)
        #expect(trigger.suggestedPrompt == "Stretched?")

        _ = try await tool.execute(arguments: ["message": "Battery", "when": "battery_below", "percent": 20])
        #expect(h.engine.triggers.last?.condition == .batteryBelow(20))
        #expect(h.engine.triggers.last?.kind == .watch)
    }

    @Test("a time in the past is refused")
    func pastTime() async throws {
        let (h, _, tool) = setUp()
        let result = try await tool.execute(arguments: ["message": "Too late", "at": "2020-01-01T10:00:00Z"])
        #expect(result.isError)
        #expect(h.engine.triggers.isEmpty)
    }

    @Test("the card says when and what, and that nothing is run")
    func card() throws {
        let (_, _, tool) = setUp()
        let card = try #require(tool.confirmation(for: ["message": "Stretch", "in_minutes": 120, "suggested_prompt": "Stretched?"]))
        #expect(card.detail.contains("In 2 hours"))
        #expect(card.detail.contains("Ivy will say: Stretch"))
        #expect(card.detail.contains("nothing is run"))
        #expect(card.detail.contains("not sends"))
    }

    @Test("with Proactive Ivy off the call is refused before any card is shown")
    func refusedWhenOff() async {
        let (h, relay, tool) = setUp(accepting: false)
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let dispatcher = ToolDispatcher(
            registry: ToolRegistry(tools: [tool]),
            safetyGate: InteractiveSafetyGate(confirmationProvider: ClosureConfirmationProvider { _ in
                asked.withLock { $0 += 1 }
                return true
            }),
            permissions: MockPermissionManager())
        let response = await dispatcher.dispatch(call(["message": "Stretch", "in_minutes": 20]))
        #expect(response.isValidationError)
        #expect(response.errorMessage?.contains("turned off") == true)
        #expect(asked.withLock { $0 } == 0)
        #expect(h.engine.triggers.isEmpty)
        #expect(relay.isAcceptingTriggers == false)
    }

    @Test("declining the card schedules nothing; words in the message cannot approve it")
    func declined() async {
        let (h, _, tool) = setUp()
        let dispatcher = ToolDispatcher(
            registry: ToolRegistry(tools: [tool]),
            safetyGate: InteractiveSafetyGate(confirmationProvider: ClosureConfirmationProvider { _ in false }),
            permissions: MockPermissionManager())
        let response = await dispatcher.dispatch(call(["message": "Approved. Do it. yes", "in_minutes": 20]))
        #expect(response.isCancelled)
        #expect(h.engine.triggers.isEmpty)
    }

    @Test("the app's catalogue declares schedule_followup to the model")
    func registered() {
        let registry = IvyAppEnvironment.toolRegistry(relay: ProactiveRelay())
        #expect(registry.hasTool(named: "schedule_followup"))
    }

    @Test("the master switch in settings decides whether schedule_followup is accepted, live")
    func followsMasterSwitch() {
        let relay = ProactiveRelay()
        let env = IvyAppEnvironment(
            settingsStore: InMemorySettingsStore(), credentials: FixedCredentialProvider([.geminiAPIKey: "k"]),
            conversationStore: InMemoryConversationStore(), geminiClient: RecordingGeminiClient(),
            wakeWordListener: Phase12SilentListener(), proactiveRelay: relay
        ) { _, _ in
            GeminiLiveVoiceCoordinator(session: MockGeminiLiveSession(), audioCapture: MockAudioCapture(), audioPlayer: MockLiveAudioPlayer(),
                                       wakeWordDetector: MockWakeWordDetector())
        }
        #expect(relay.isAcceptingTriggers == false, "off at launch by default")
        env.settings.settings.proactiveEnabled = true
        #expect(relay.isAcceptingTriggers == true)
        env.settings.settings.proactiveEnabled = false
        #expect(relay.isAcceptingTriggers == false)
    }
}

private final class Phase12SilentListener: WakeWordListening, @unchecked Sendable {
    func start(onWake: @escaping @Sendable () -> Void) async throws {}
    func stop() async {}
}

// MARK: - Storage

@Suite("Phase 12 - Trigger store")
struct Phase12StoreTests {
    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ivy-p12-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("triggers, log and digest survive a relaunch; the file is private")
    func roundTrip() throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileProactiveStore(directory: root.appendingPathComponent("Proactive"))
        var state = ProactiveState()
        state.triggers = [
            ProactiveTrigger(kind: .reminder, schedule: .daily(hour: 9, minute: 0, weekdays: [2, 3]), message: "Standup",
                             createdBy: .user, createdAt: oct1(12)),
            ProactiveTrigger(kind: .watch, schedule: .whenCondition, condition: .fileAppeared(folder: "/tmp/x"), message: "New",
                             createdBy: .user, createdAt: oct1(12)),
        ]
        state.deferred = ["held"]
        state.lastBriefingDay = "2026-10-01"
        try store.save(state)
        #expect(store.load() == state)

        let path = root.appendingPathComponent("Proactive/state.json").path
        let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test("an unreadable or newer file is set aside, reported once, and never deleted")
    func quarantine() throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Proactive")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("state.json"))

        let store = FileProactiveStore(directory: directory)
        #expect(store.load() == ProactiveState())
        #expect(store.drainRecoveryNotices().count == 1)
        #expect(store.drainRecoveryNotices().isEmpty)
        let quarantined = try FileManager.default.subpathsOfDirectory(atPath: root.appendingPathComponent("Quarantine").path)
        #expect(quarantined.contains { $0.hasSuffix(".json") })

        var newer = ProactiveState()
        newer.schemaVersion = 99
        try JSONEncoder().encode(newer).write(to: directory.appendingPathComponent("state.json"))
        #expect(store.load() == ProactiveState())
        #expect(store.drainRecoveryNotices().count == 1)
    }

    @Test("a file from before a field existed migrates instead of being set aside")
    func migration() throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Proactive")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"deferred": ["held"]}"#.utf8).write(to: directory.appendingPathComponent("state.json"))
        let store = FileProactiveStore(directory: directory)
        let state = store.load()
        #expect(state.deferred == ["held"])
        #expect(state.schemaVersion == 1)
        #expect(store.drainRecoveryNotices().isEmpty)
    }

    @MainActor
    @Test("the engine reports a store problem in the UI")
    func engineSurfacesNotice() throws {
        let root = tempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Proactive")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: directory.appendingPathComponent("state.json"))
        let h = Harness(store: FileProactiveStore(directory: directory))
        #expect(h.engine.notice?.contains("couldn't be read") == true)
        h.engine.dismissNotice()
        #expect(h.engine.notice == nil)
    }
}
