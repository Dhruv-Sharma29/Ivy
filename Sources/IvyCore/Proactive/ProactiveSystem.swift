import Foundation
import AppKit
import EventKit
import IOKit.ps
import ServiceManagement
import UserNotifications

/// Delivers proactive notifications through Notification Center, with Open / Snooze / Done / Stop buttons.
public final class SystemProactiveDeliverer: NSObject, ProactiveDelivering, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let category = "ivy.proactive"
    static let briefingCategory = "ivy.proactive.briefing"

    /// Set once at launch, before any notification can arrive.
    public var onAction: (@MainActor @Sendable (ProactiveAction, UUID?, ProactiveTrigger.Kind, String) -> Void)?

    /// The notification centre traps in a process without a bundle (`swift run`, tests).
    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    public override init() {
        super.init()
    }

    /// Registers the buttons and starts receiving taps. Does not ask for permission.
    public func activate() {
        guard isBundled else { return }
        func action(_ action: ProactiveAction, _ title: String, foreground: Bool = false) -> UNNotificationAction {
            UNNotificationAction(identifier: action.rawValue, title: title, options: foreground ? [.foreground] : [])
        }
        let standard = [action(.open, "Open in Ivy", foreground: true), action(.snooze, "Snooze 10 min"), action(.done, "Done"), action(.stop, "Stop these")]
        let briefing = [action(.read, "Read to me"), action(.open, "Open in Ivy", foreground: true), action(.stop, "Stop these")]
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: standard, intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.briefingCategory, actions: briefing, intentIdentifiers: []),
        ])
        center.delegate = self
    }

    /// Asks for notification permission. Called when the user turns Proactive Ivy on, never at launch.
    @discardableResult
    public func requestAuthorization() async -> Bool {
        guard isBundled else { return false }
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            print("[PROACTIVE] notification permission request failed: \(error.localizedDescription)")
            return false
        }
    }

    public func deliver(_ notification: ProactiveNotification) async throws {
        guard isBundled else {
            throw ToolError.executionFailed("notifications need Ivy.app (scripts/run-ivy-app.sh), not `swift run`.")
        }
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        // "Why am I seeing this" travels with every notification.
        content.subtitle = notification.reason
        content.sound = .default
        content.categoryIdentifier = notification.kind == .briefing ? Self.briefingCategory : Self.category
        content.userInfo = ["trigger": notification.triggerID?.uuidString ?? "", "kind": notification.kind.rawValue, "body": notification.body]
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        // Clicking the notification itself is "open"; dismissing it is nothing.
        let action: ProactiveAction
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            action = .open
        } else if let chosen = ProactiveAction(rawValue: response.actionIdentifier) {
            action = chosen
        } else {
            return
        }
        let trigger = (info["trigger"] as? String).flatMap(UUID.init(uuidString:))
        let kind = (info["kind"] as? String).flatMap(ProactiveTrigger.Kind.init(rawValue:)) ?? .reminder
        let body = info["body"] as? String ?? ""
        let handler = onAction
        await MainActor.run { handler?(action, trigger, kind, body) }
    }
}

/// Reads local state only. Nothing here prompts: without Calendar access there are simply no events.
public struct SystemProactiveSignals: ProactiveSignals {
    public init() {}

    public func runningApps() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
    }

    public func batteryPercent() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return current * 100 / max
        }
        return nil
    }

    public func items(in folder: String) -> Set<String>? {
        do {
            return Set(try FileManager.default.contentsOfDirectory(atPath: folder).filter { !$0.hasPrefix(".") })
        } catch {
            return nil // folder gone or unreadable: nothing to report, and nothing to compare against
        }
    }

    public func events(from start: Date, to end: Date) -> [UpcomingEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = EKEventStore()
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: nil))
            .filter { !$0.isAllDay && $0.startDate >= start }
            .map { UpcomingEvent(id: "\($0.eventIdentifier ?? $0.title ?? "")@\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "Event", start: $0.startDate, calendar: $0.calendar.title) }
    }
}

public protocol LoginItemManaging: Sendable {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// Opens Ivy at login through the system's login-item service (the user can also remove it in System Settings).
public struct SystemLoginItem: LoginItemManaging {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
