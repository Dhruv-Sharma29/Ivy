import Foundation

/// Lets Ivy propose telling the user something later: at a time, after a delay, or when a simple local
/// condition becomes true. Always risky: the approval card shows exactly when and what. The result is only
/// ever a notification; nothing is executed when it fires.
public final class ScheduleFollowUpTool: IvyTool, Sendable {
    public static let maxDelayMinutes = 7 * 24 * 60
    enum Condition: String, CaseIterable { case app_launched, app_quit, battery_below }

    public let name = "schedule_followup"
    public let description = "Schedules Ivy to notify the user later: a quick reminder ('in 20 minutes'), a follow-up at a date and time, a daily nudge, or a 'tell me when' for an app opening or quitting or the battery dropping below a level. It only shows a notification; it cannot run anything. For the Apple Reminders app use the reminders tool instead."
    public let group = ToolGroup.productivity
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "message": ToolProperty(type: "STRING", description: "What to tell the user when it fires (at most 500 characters)."),
                "in_minutes": ToolProperty(type: "INTEGER", description: "Fire this many minutes from now (1–10080). Use exactly one of in_minutes, at, when."),
                "at": ToolProperty(type: "STRING", description: "Fire at this date and time, ISO 8601 (e.g. '2026-10-01 18:00')."),
                "repeat_daily": ToolProperty(type: "BOOLEAN", description: "With 'at': repeat every day at that time."),
                "when": ToolProperty(type: "STRING", description: "Fire when a condition becomes true: app_launched, app_quit or battery_below."),
                "app": ToolProperty(type: "STRING", description: "For app_launched / app_quit: the app's name."),
                "percent": ToolProperty(type: "INTEGER", description: "For battery_below: the level, 5–95."),
                "suggested_prompt": ToolProperty(type: "STRING", description: "Optional: text to pre-fill in Ivy's input when the user opens the notification. It is never sent automatically."),
            ],
            required: ["message"]))
    }

    private let scheduler: ProactiveScheduling
    private let calendar: @Sendable () -> Calendar

    public init(scheduler: ProactiveScheduling, calendar: @escaping @Sendable () -> Calendar = { .current }) {
        self.scheduler = scheduler
        self.calendar = calendar
    }

    private enum Timing: Equatable {
        case delay(Int)
        case at(Date, daily: Bool, raw: String)
        case condition(ProactiveTrigger.Condition)
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> (message: String, timing: Timing, prompt: String?) {
        let args = ToolArguments(arguments)
        try args.allow(["message", "in_minutes", "at", "repeat_daily", "when", "app", "percent", "suggested_prompt"])
        let message = try args.string("message", max: ProactiveTrigger.maxMessageLength, multiline: true)
        let prompt = try args.optionalString("suggested_prompt", max: ProactiveTrigger.maxMessageLength, multiline: true)
        let given = ["in_minutes", "at", "when"].filter { args.raw[$0] != nil }
        guard given.count == 1 else {
            throw ToolError.invalidArgument("Provide exactly one of 'in_minutes', 'at' or 'when'.")
        }
        let daily = try args.optionalBool("repeat_daily") ?? false
        if given[0] != "at", args.raw["repeat_daily"] != nil {
            throw ToolError.invalidArgument("'repeat_daily' only applies with 'at'.")
        }
        if given[0] != "when", args.raw["app"] != nil || args.raw["percent"] != nil {
            throw ToolError.invalidArgument("'app' and 'percent' only apply with 'when'.")
        }
        switch given[0] {
        case "in_minutes":
            let minutes = try args.int("in_minutes")
            guard (1...Self.maxDelayMinutes).contains(minutes) else {
                throw ToolError.invalidArgument("Argument 'in_minutes' must be between 1 and \(Self.maxDelayMinutes).")
            }
            return (message, .delay(minutes), prompt)
        case "at":
            let raw = try args.string("at", max: 64)
            return (message, .at(try ToolValidation.parseCalendarDate(raw), daily: daily, raw: raw), prompt)
        default:
            switch try args.choice("when", Condition.self) {
            case .battery_below:
                guard args.raw["app"] == nil else { throw ToolError.invalidArgument("'app' doesn't apply to battery_below.") }
                let percent = try args.int("percent")
                guard (5...95).contains(percent) else { throw ToolError.invalidArgument("Argument 'percent' must be between 5 and 95.") }
                return (message, .condition(.batteryBelow(percent)), prompt)
            case .app_launched, .app_quit:
                guard args.raw["percent"] == nil else { throw ToolError.invalidArgument("'percent' only applies to battery_below.") }
                let app = try ToolValidation.validateAppName(try args.string("app", max: ToolValidation.maxAppNameLength))
                let launched = (try args.choice("when", Condition.self)) == .app_launched
                return (message, .condition(launched ? .appLaunched(app) : .appQuit(app)), prompt)
            }
        }
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    private func describe(_ timing: Timing) -> String {
        switch timing {
        case .delay(let minutes):
            return minutes == 1 ? "In 1 minute" : (minutes % 60 == 0 && minutes >= 60 ? "In \(minutes / 60) hour\(minutes == 60 ? "" : "s")" : "In \(minutes) minutes")
        case .at(_, let daily, let raw):
            return daily ? "Every day at the time of day in \(raw)" : "Once, at \(raw)"
        case .condition(.appLaunched(let app)): return "The next time \(app) opens"
        case .condition(.appQuit(let app)): return "The next time \(app) quits"
        case .condition(.batteryBelow(let percent)): return "When the battery drops below \(percent)%"
        case .condition(.fileAppeared(let folder)): return "When something new appears in \(folder)"
        }
    }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        guard let request = try? parse(arguments) else { return nil }
        var detail = "Action: Schedule a notification (nothing is run when it fires)\nWhen: \(describe(request.timing))\nIvy will say: \(request.message)"
        if let prompt = request.prompt {
            detail += "\nOpening it pre-fills (not sends): \(prompt)"
        }
        return ToolConfirmation(
            title: "Schedule Follow-Up",
            prompt: "You're about to let me pester you later. You asked for this, remember that when it goes off. Do it or chicken out?",
            detail: detail)
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        let now = await scheduler.currentDate()
        let schedule: ProactiveTrigger.Schedule
        var condition: ProactiveTrigger.Condition?
        var kind = ProactiveTrigger.Kind.reminder
        switch request.timing {
        case .delay(let minutes):
            schedule = .at(now.addingTimeInterval(TimeInterval(minutes * 60)))
        case .at(let date, let daily, _):
            if daily {
                let parts = calendar().dateComponents([.hour, .minute], from: date)
                schedule = .daily(hour: parts.hour ?? 9, minute: parts.minute ?? 0, weekdays: [])
            } else {
                guard date > now else { return .failure("That time has already passed. Give a date and time in the future.") }
                schedule = .at(date)
                kind = .followUp
            }
        case .condition(let when):
            schedule = .whenCondition
            condition = when
            kind = .watch
        }
        do {
            try await scheduler.schedule(ProactiveTrigger(
                kind: kind, schedule: schedule, condition: condition, message: request.message,
                suggestedPrompt: request.prompt, createdBy: .ivyWithConfirmation, createdAt: now))
            return .success("Scheduled. \(describe(request.timing)), Ivy will notify: \(request.message)")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
