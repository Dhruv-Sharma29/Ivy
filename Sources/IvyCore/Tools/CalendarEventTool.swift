import Foundation

/// Ivy tool for creating calendar events via CalendarExecutorProtocol.
public final class CalendarEventTool: IvyTool, Sendable {
    public let name: String = "calendar_event"
    public let description: String = "Creates a new event in the user's macOS calendar with a specified title and start date/time."

    public var safetyClassification: ToolSafetyClassification {
        .risky
    }

    public let declaration: FunctionDeclaration = FunctionDeclaration(
        name: "calendar_event",
        description: "Creates a new event in the user's macOS calendar with a specified title and start date/time.",
        parameters: ToolParameters(
            type: "OBJECT",
            properties: [
                "title": ToolProperty(
                    type: "STRING",
                    description: "The title or summary of the calendar event (e.g., 'Dentist Appointment', 'Project Kickoff')."
                ),
                "date": ToolProperty(
                    type: "STRING",
                    description: "The date and start time for the event in ISO 8601 format (e.g., '2026-10-01T14:00:00Z' or '2026-10-01 14:00')."
                )
            ],
            required: ["title", "date"]
        )
    )

    private let executor: CalendarExecutorProtocol
    public let defaultDuration: TimeInterval

    public init(
        executor: CalendarExecutorProtocol = SystemCalendarExecutor(),
        defaultDuration: TimeInterval = 3600
    ) {
        self.executor = executor
        self.defaultDuration = defaultDuration
    }

    public func validate(arguments: [String: AnyCodable]) throws {
        guard let titleValue = arguments["title"] else {
            throw ToolError.missingArgument("title")
        }
        guard let rawTitle = titleValue.stringValue else {
            throw ToolError.invalidArgument("Argument 'title' must be a string.")
        }
        _ = try ToolValidation.validateCalendarTitle(rawTitle)

        guard let dateValue = arguments["date"] else {
            throw ToolError.missingArgument("date")
        }
        guard let rawDate = dateValue.stringValue else {
            throw ToolError.invalidArgument("Argument 'date' must be a string.")
        }
        _ = try ToolValidation.parseCalendarDate(rawDate)
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        guard let titleValue = arguments["title"] else {
            throw ToolError.missingArgument("title")
        }
        guard let rawTitle = titleValue.stringValue else {
            throw ToolError.invalidArgument("Argument 'title' must be a string.")
        }
        let validatedTitle = try ToolValidation.validateCalendarTitle(rawTitle)

        guard let dateValue = arguments["date"] else {
            throw ToolError.missingArgument("date")
        }
        guard let rawDate = dateValue.stringValue else {
            throw ToolError.invalidArgument("Argument 'date' must be a string.")
        }
        let parsedDate = try ToolValidation.parseCalendarDate(rawDate)

        do {
            let result = try await executor.createEvent(
                title: validatedTitle,
                startDate: parsedDate,
                duration: defaultDuration
            )
            return ToolResult.success(result.message)
        } catch let calErr as CalendarError {
            return ToolResult.failure(calErr.localizedDescription)
        } catch let toolErr as ToolError {
            return ToolResult.failure(toolErr.localizedDescription)
        } catch {
            return ToolResult.failure("Calendar execution error: \(error.localizedDescription)")
        }
    }
}
