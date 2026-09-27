import Foundation
import EventKit

/// Structured outcome of creating a calendar event.
public struct CalendarEventResult: Sendable, Equatable {
    public let eventTitle: String
    public let calendarName: String
    public let startDate: Date
    public let duration: TimeInterval
    public let message: String

    public init(
        eventTitle: String,
        calendarName: String,
        startDate: Date,
        duration: TimeInterval,
        message: String
    ) {
        self.eventTitle = eventTitle
        self.calendarName = calendarName
        self.startDate = startDate
        self.duration = duration
        self.message = message
    }
}

/// Errors occurring during calendar operations.
public enum CalendarError: Error, LocalizedError, Equatable, Sendable {
    case permissionDenied
    case defaultCalendarNotFound
    case invalidDate(String)
    case eventCreationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Calendar access denied. Enable calendar permissions in macOS System Settings > Privacy & Security > Calendars."
        case .defaultCalendarNotFound:
            return "No default calendar found for new events. Please configure a default calendar in the macOS Calendar app."
        case .invalidDate(let msg):
            return "Invalid date: \(msg)"
        case .eventCreationFailed(let msg):
            return "Failed to create calendar event: \(msg)"
        }
    }
}

/// Abstraction for creating calendar events.
/// Allows mock-based unit testing without interacting with macOS EventKit.
public protocol CalendarExecutorProtocol: Sendable {
    /// Creates a calendar event with the given title, start date, and duration.
    func createEvent(
        title: String,
        startDate: Date,
        duration: TimeInterval
    ) async throws -> CalendarEventResult
}

/// Production implementation of CalendarExecutorProtocol using EventKit.
public final class SystemCalendarExecutor: CalendarExecutorProtocol, Sendable {
    public init() {}

    public func createEvent(
        title: String,
        startDate: Date,
        duration: TimeInterval
    ) async throws -> CalendarEventResult {
        try await MainActorCalendarLauncher.createEvent(title: title, startDate: startDate, duration: duration)
    }
}

// MARK: - MainActor EventKit Execution

@MainActor
private enum MainActorCalendarLauncher {
    static func createEvent(
        title: String,
        startDate: Date,
        duration: TimeInterval
    ) async throws -> CalendarEventResult {
        let store = EKEventStore()
        let granted: Bool
        if #available(macOS 14.0, *) {
            do {
                granted = try await store.requestFullAccessToEvents()
            } catch {
                throw CalendarError.eventCreationFailed(error.localizedDescription)
            }
        } else {
            do {
                granted = try await store.requestAccess(to: .event)
            } catch {
                throw CalendarError.eventCreationFailed(error.localizedDescription)
            }
        }

        guard granted else {
            throw CalendarError.permissionDenied
        }

        store.reset()

        let calendar = store.defaultCalendarForNewEvents
            ?? store.calendars(for: .event).first(where: { $0.allowsContentModifications })
        guard let calendar else {
            throw CalendarError.defaultCalendarNotFound
        }

        let effectiveDuration = max(60, duration)
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = startDate
        event.endDate = startDate.addingTimeInterval(effectiveDuration)
        event.calendar = calendar

        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarError.eventCreationFailed(error.localizedDescription)
        }

        let formattedDate = startDate.formatted(date: .abbreviated, time: .shortened)
        let successMessage = "Created calendar event '\(title)' on '\(calendar.title)' for \(formattedDate)."
        return CalendarEventResult(
            eventTitle: title,
            calendarName: calendar.title,
            startDate: startDate,
            duration: duration,
            message: successMessage
        )
    }
}
