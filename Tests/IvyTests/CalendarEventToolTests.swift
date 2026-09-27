import Testing
import Foundation
@testable import IvyCore

final class MockCalendarExecutor: CalendarExecutorProtocol, @unchecked Sendable {
    struct RecordedCall: Equatable {
        let title: String
        let startDate: Date
        let duration: TimeInterval
    }

    var recordedCalls: [RecordedCall] = []
    var errorToThrow: Error?
    var resultToReturn: CalendarEventResult?

    func createEvent(
        title: String,
        startDate: Date,
        duration: TimeInterval
    ) async throws -> CalendarEventResult {
        if let error = errorToThrow {
            throw error
        }
        let call = RecordedCall(title: title, startDate: startDate, duration: duration)
        recordedCalls.append(call)
        if let resultToReturn {
            return resultToReturn
        }
        return CalendarEventResult(
            eventTitle: title,
            calendarName: "Work",
            startDate: startDate,
            duration: duration,
            message: "Created calendar event '\(title)' on 'Work' for \(startDate)."
        )
    }
}

@Suite("CalendarEventTool Tests")
struct CalendarEventToolTests {

    @Test("Declaration metadata and risky safety classification")
    func testToolDeclaration() {
        let tool = CalendarEventTool(executor: MockCalendarExecutor())
        #expect(tool.name == "calendar_event")
        #expect(tool.safetyClassification == .risky)
        #expect(tool.declaration.name == "calendar_event")
        #expect(tool.declaration.parameters?.properties["title"]?.type == "STRING")
        #expect(tool.declaration.parameters?.properties["date"]?.type == "STRING")
        #expect(tool.declaration.parameters?.required == ["title", "date"])
    }

    @Test("Successful event creation returns success result and records call")
    func testSuccessfulEventCreation() async throws {
        let mock = MockCalendarExecutor()
        let tool = CalendarEventTool(executor: mock)

        let args: [String: AnyCodable] = [
            "title": AnyCodable("Team Standup"),
            "date": AnyCodable("2026-10-01T09:30:00Z")
        ]

        let result = try await tool.execute(arguments: args)
        #expect(result.isError == false)
        #expect(result.output.contains("Team Standup"))
        #expect(mock.recordedCalls.count == 1)
        #expect(mock.recordedCalls[0].title == "Team Standup")
        #expect(mock.recordedCalls[0].duration == 3600)
    }

    @Test("Date formats: parses ISO 8601 with offset, fractional seconds, and standard formats")
    func testDateFormats() throws {
        // ISO 8601 Z
        let dateZ = try ToolValidation.parseCalendarDate("2026-10-01T14:00:00Z")
        #expect(dateZ.timeIntervalSince1970 > 0)

        // ISO 8601 Z without seconds
        let dateZNoSec = try ToolValidation.parseCalendarDate("2026-10-01T14:00Z")
        #expect(dateZNoSec.timeIntervalSince1970 > 0)

        // ISO 8601 offset
        let dateOffset = try ToolValidation.parseCalendarDate("2026-10-01T14:00:00+02:00")
        #expect(dateOffset.timeIntervalSince1970 > 0)

        // ISO 8601 offset without seconds
        let dateOffsetNoSec = try ToolValidation.parseCalendarDate("2026-10-01T14:00+02:00")
        #expect(dateOffsetNoSec.timeIntervalSince1970 > 0)

        // ISO 8601 fractional seconds
        let dateFrac = try ToolValidation.parseCalendarDate("2026-10-01T14:00:00.123Z")
        #expect(dateFrac.timeIntervalSince1970 > 0)

        // Local date/time without T
        let dateLocal = try ToolValidation.parseCalendarDate("2026-10-01 14:00")
        #expect(dateLocal.timeIntervalSince1970 > 0)

        // Space separated date/time with Z
        let dateSpaceZ = try ToolValidation.parseCalendarDate("2026-10-01 14:00Z")
        #expect(dateSpaceZ.timeIntervalSince1970 > 0)
    }

    @Test("Ambiguous date without time throws invalidArgument explaining missing time")
    func testAmbiguousDateWithoutTimeThrows() {
        #expect(throws: ToolError.self) {
            try ToolValidation.parseCalendarDate("2026-10-01")
        }
        do {
            _ = try ToolValidation.parseCalendarDate("2026-10-01")
        } catch let ToolError.invalidArgument(msg) {
            #expect(msg.contains("missing a time component"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("Timezone correctness: UTC Z and offset dates resolve to equivalent instant in time")
    func testTimezoneCorrectness() throws {
        let utcDate = try ToolValidation.parseCalendarDate("2026-10-01T12:00:00Z")
        let plusTwoDate = try ToolValidation.parseCalendarDate("2026-10-01T14:00:00+02:00")
        let plusTwoNoSec = try ToolValidation.parseCalendarDate("2026-10-01T14:00+02:00")
        #expect(utcDate == plusTwoDate)
        #expect(utcDate == plusTwoNoSec)
    }

    @Test("Missing argument validation throws missingArgument")
    func testMissingArguments() {
        let tool = CalendarEventTool(executor: MockCalendarExecutor())

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["date": AnyCodable("2026-10-01T10:00:00Z")])
        }

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["title": AnyCodable("Standup")])
        }
    }

    @Test("Empty title or date throws invalidArgument")
    func testEmptyArguments() {
        let tool = CalendarEventTool(executor: MockCalendarExecutor())

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "title": AnyCodable("   "),
                "date": AnyCodable("2026-10-01T10:00:00Z")
            ])
        }

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "title": AnyCodable("Standup"),
                "date": AnyCodable("   ")
            ])
        }
    }

    @Test("Ambiguous or unparseable date throws invalidArgument without guessing")
    func testAmbiguousDateThrows() {
        let tool = CalendarEventTool(executor: MockCalendarExecutor())

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "title": AnyCodable("Lunch"),
                "date": AnyCodable("tomorrow at lunch")
            ])
        }

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "title": AnyCodable("Meeting"),
                "date": AnyCodable("someday soon")
            ])
        }
    }

    @Test("Title exceeding maximum length throws invalidArgument")
    func testExcessiveTitleLength() {
        let tool = CalendarEventTool(executor: MockCalendarExecutor())
        let longTitle = String(repeating: "A", count: ToolValidation.maxCalendarTitleLength + 1)

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "title": AnyCodable(longTitle),
                "date": AnyCodable("2026-10-01T10:00:00Z")
            ])
        }
    }

    @Test("Null byte injection in title or date throws invalidArgument")
    func testNullByteInjection() {
        let tool = CalendarEventTool(executor: MockCalendarExecutor())

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "title": AnyCodable("Meeting\0Injection"),
                "date": AnyCodable("2026-10-01T10:00:00Z")
            ])
        }

        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "title": AnyCodable("Meeting"),
                "date": AnyCodable("2026-10-01T10:00:00Z\0")
            ])
        }
    }

    @Test("CalendarError.permissionDenied is returned as failure ToolResult")
    func testPermissionDeniedHandling() async throws {
        let mock = MockCalendarExecutor()
        mock.errorToThrow = CalendarError.permissionDenied
        let tool = CalendarEventTool(executor: mock)

        let result = try await tool.execute(arguments: [
            "title": AnyCodable("Review"),
            "date": AnyCodable("2026-10-01T10:00:00Z")
        ])

        #expect(result.isError == true)
        #expect(result.output.contains("Calendar access denied"))
    }

    @Test("CalendarError.defaultCalendarNotFound is returned as failure ToolResult")
    func testDefaultCalendarNotFoundHandling() async throws {
        let mock = MockCalendarExecutor()
        mock.errorToThrow = CalendarError.defaultCalendarNotFound
        let tool = CalendarEventTool(executor: mock)

        let result = try await tool.execute(arguments: [
            "title": AnyCodable("Review"),
            "date": AnyCodable("2026-10-01T10:00:00Z")
        ])

        #expect(result.isError == true)
        #expect(result.output.contains("No default calendar found"))
    }

    @Test("CalendarError.eventCreationFailed is returned as failure ToolResult")
    func testEventKitFailureHandling() async throws {
        let mock = MockCalendarExecutor()
        mock.errorToThrow = CalendarError.eventCreationFailed("EventKit database locked")
        let tool = CalendarEventTool(executor: mock)

        let result = try await tool.execute(arguments: [
            "title": AnyCodable("Review"),
            "date": AnyCodable("2026-10-01T10:00:00Z")
        ])

        #expect(result.isError == true)
        #expect(result.output.contains("EventKit database locked"))
    }

    @Test("Generic NSError from executor is converted into structured failure ToolResult without crashing")
    func testGenericNSErrorPropagation() async throws {
        let mock = MockCalendarExecutor()
        mock.errorToThrow = NSError(domain: "EKErrorDomain", code: 100, userInfo: [
            NSLocalizedDescriptionKey: "Internal EventKit failure"
        ])
        let tool = CalendarEventTool(executor: mock)

        let result = try await tool.execute(arguments: [
            "title": AnyCodable("Review"),
            "date": AnyCodable("2026-10-01T10:00:00Z")
        ])

        #expect(result.isError == true)
        #expect(result.output.contains("Internal EventKit failure"))
    }

    @Test("Non-string arguments throw invalidArgument")
    func testNonStringArgumentsValidation() {
        let tool = CalendarEventTool(executor: MockCalendarExecutor())

        // Integer title
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "title": AnyCodable(12345),
                "date": AnyCodable("2026-10-01T10:00:00Z")
            ])
        }

        // Boolean date
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [
                "title": AnyCodable("Meeting"),
                "date": AnyCodable(true)
            ])
        }
    }

    @Test("Structured ToolResult properties and CalendarEventResult shapes")
    func testStructuredToolResultShape() {
        let now = Date()
        let eventResult = CalendarEventResult(
            eventTitle: "Sprint Planning",
            calendarName: "Home",
            startDate: now,
            duration: 1800,
            message: "Created event 'Sprint Planning' on 'Home'."
        )

        #expect(eventResult.eventTitle == "Sprint Planning")
        #expect(eventResult.calendarName == "Home")
        #expect(eventResult.startDate == now)
        #expect(eventResult.duration == 1800)
        #expect(eventResult.message.contains("Sprint Planning"))

        let success = ToolResult.success("Event created")
        #expect(success.isError == false)
        #expect(success.output == "Event created")

        let failure = ToolResult.failure("Permission denied")
        #expect(failure.isError == true)
        #expect(failure.output == "Permission denied")
    }

    @Test("SystemCalendarExecutor conforms to CalendarExecutorProtocol")
    func testSystemExecutorProtocolConformance() {
        let executor: any CalendarExecutorProtocol = SystemCalendarExecutor()
        #expect(executor is SystemCalendarExecutor)
    }
}
