import Foundation
import AppKit
import ApplicationServices
import Contacts
import CoreWLAN
import EventKit
import ScreenCaptureKit
import UserNotifications

/// Runs a fixed executable with an argument list (no shell, so nothing is interpreted) and returns its output.
enum ProcessRunner {
    static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            // Drain the pipe while the process runs: a full pipe would block it forever.
            DispatchQueue.global().async {
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: ToolError.executionFailed("\(URL(fileURLWithPath: executable).lastPathComponent) exited with status \(process.terminationStatus)."))
                }
            }
        }
    }
}

public struct SystemNotificationPoster: NotificationPosting {
    public init() {}

    public func post(title: String, body: String?) async throws {
        // The notification centre traps in a process without a bundle.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            throw ToolError.executionFailed("notifications need Ivy.app (scripts/run-ivy-app.sh), not `swift run`.")
        }
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

public struct SystemClipboard: ClipboardAccessing {
    public init() {}

    @MainActor
    public func readText() async -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    @MainActor
    public func writeText(_ text: String) async -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

public struct SystemURLOpener: URLOpening {
    public init() {}

    @MainActor
    public func open(_ url: URL) async -> Bool {
        NSWorkspace.shared.open(url)
    }
}

public struct SystemNetworkController: NetworkControlling {
    public init() {}

    private func interface() throws -> CWInterface {
        guard let interface = CWWiFiClient.shared().interface() else {
            throw ToolError.executionFailed("this Mac has no Wi-Fi interface.")
        }
        return interface
    }

    public func wifiStatus() async throws -> String {
        let wifi = try interface()
        guard wifi.powerOn() else { return "Wi-Fi is off." }
        // The network name needs Location Services, which Ivy doesn't ask for; it is nil without it.
        if let name = wifi.ssid() { return "Wi-Fi is on, connected to \(name)." }
        return "Wi-Fi is on."
    }

    public func setWiFi(on: Bool) async throws {
        guard let name = try interface().interfaceName else {
            throw ToolError.executionFailed("the Wi-Fi interface has no name.")
        }
        _ = try await ProcessRunner.run("/usr/sbin/networksetup", ["-setairportpower", name, on ? "on" : "off"])
    }

    public func bluetoothStatus() async throws -> String {
        // ponytail: system_profiler is slow (~1 s) but needs no Bluetooth permission; switch to IOBluetooth
        // (and its usage string) if this gets used often.
        let report = try await ProcessRunner.run("/usr/sbin/system_profiler", ["SPBluetoothDataType"])
        guard let line = report.split(whereSeparator: \.isNewline).first(where: { $0.contains("State:") }) else {
            throw ToolError.executionFailed("Bluetooth state isn't reported on this Mac.")
        }
        return "Bluetooth is \(line.contains("On") ? "on" : "off")."
    }
}

public struct SystemWindowController: WindowControlling {
    public init() {}

    @MainActor
    public func list() async throws -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return windows.compactMap { window in
            // Layer 0 is ordinary app windows (not the menu bar, Dock or overlays).
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let app = window[kCGWindowOwnerName as String] as? String,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = bounds["Width"], let height = bounds["Height"], width > 40, height > 40 else { return nil }
            return WindowInfo(app: app, x: Int(bounds["X"] ?? 0), y: Int(bounds["Y"] ?? 0), width: Int(width), height: Int(height))
        }
    }

    @MainActor
    private func running(_ app: String) throws -> NSRunningApplication {
        guard let found = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && $0.localizedName?.caseInsensitiveCompare(app) == .orderedSame
        }) else {
            throw ToolError.executionFailed("\(app) isn't running.")
        }
        return found
    }

    @MainActor
    public func focus(app: String) async throws {
        guard try running(app).activate() else {
            throw ToolError.executionFailed("\(app) couldn't be brought to the front.")
        }
    }

    @MainActor
    public func setFrame(app: String, x: Int, y: Int, width: Int, height: Int) async throws {
        let element = AXUIElementCreateApplication(try running(app).processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
              let window = (value as? [AXUIElement])?.first else {
            throw ToolError.executionFailed("\(app) has no window Ivy can move (or Accessibility access is off).")
        }
        var origin = CGPoint(x: x, y: y)
        var size = CGSize(width: width, height: height)
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size),
              AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, position) == .success,
              AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, extent) == .success else {
            throw ToolError.executionFailed("\(app)'s window refused to move or resize.")
        }
    }

    @MainActor
    public func tile(app: String, _ position: WindowTile) async throws {
        guard let screen = NSScreen.main else { throw ToolError.executionFailed("no display is available.") }
        // AppKit measures from the bottom-left; Accessibility from the top-left.
        let visible = screen.visibleFrame
        let top = screen.frame.maxY - visible.maxY
        let half = visible.width / 2
        let (x, width): (CGFloat, CGFloat) = switch position {
        case .left: (visible.minX, half)
        case .right: (visible.minX + half, half)
        case .full: (visible.minX, visible.width)
        }
        try await setFrame(app: app, x: Int(x), y: Int(top), width: Int(width), height: Int(visible.height))
    }
}

public struct SystemScreenCapturer: ScreenCapturing {
    public init() {}

    public func captureMainDisplay() async throws -> ScreenCapture {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw ToolError.executionFailed("no display is available to capture.")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw ToolError.executionFailed("the capture couldn't be encoded.")
        }
        return ScreenCapture(png: png, width: image.width, height: image.height)
    }
}

public struct SystemFinder: FinderControlling {
    private let appleScript: AppleScriptExecutorProtocol

    public init(appleScript: AppleScriptExecutorProtocol = SystemAppleScriptExecutor()) {
        self.appleScript = appleScript
    }

    @MainActor
    public func reveal(path: String) async throws {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ToolError.executionFailed("nothing exists at \(path).")
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @MainActor
    public func openFolder(path: String) async throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ToolError.executionFailed("\(path) isn't a folder.")
        }
        guard NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true)) else {
            throw ToolError.executionFailed("\(path) couldn't be opened.")
        }
    }

    public func selection() async throws -> [String] {
        let script = """
        tell application "Finder"
            set out to ""
            repeat with anItem in (get selection)
                set out to out & POSIX path of (anItem as alias) & linefeed
            end repeat
            return out
        end tell
        """
        return try await appleScript.execute(script: script).split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.hasPrefix("/") }
    }
}

public struct SystemFileSearcher: FileSearching {
    public init() {}

    public func search(query: String, content: Bool, root: URL) async throws -> [String] {
        // ponytail: `mdfind` is the Spotlight index's own CLI; NSMetadataQuery would need a run loop for the
        // same results. The query reaches it as one argument (no shell), and the tool has already refused
        // the characters that mean something in Spotlight's query language.
        let arguments = content
            ? ["-onlyin", root.path, "kMDItemTextContent == \"\(query)\"cd"]
            : ["-onlyin", root.path, "-name", query]
        return try await ProcessRunner.run("/usr/bin/mdfind", arguments)
            .split(whereSeparator: \.isNewline).prefix(500).map(String.init)
    }
}

public struct SystemRemindersExecutor: RemindersExecuting {
    public init() {}

    /// Fetches incomplete reminders and hands them to `body` on EventKit's queue (they are not Sendable).
    private func withIncomplete<T: Sendable>(_ store: EKEventStore, _ body: @escaping @Sendable ([EKReminder]) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(with: Result { try body(reminders ?? []) })
            }
        }
    }

    public func incomplete() async throws -> [ReminderItem] {
        try await withIncomplete(EKEventStore()) { reminders in
            reminders.map { ReminderItem(title: $0.title ?? "", due: $0.dueDateComponents?.date, list: $0.calendar?.title ?? "Reminders") }
                .sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
        }
    }

    public func create(title: String, due: Date?) async throws -> String {
        let store = EKEventStore()
        guard let list = store.defaultCalendarForNewReminders() else {
            throw ToolError.executionFailed("there is no default Reminders list. Create one in the Reminders app.")
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = list
        if let due {
            var components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            components.calendar = Calendar.current
            reminder.dueDateComponents = components
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
        return list.title
    }

    public func complete(title: String) async throws -> Bool {
        let store = EKEventStore()
        // `store` is only touched on EventKit's own callback queue from here on.
        nonisolated(unsafe) let unsafeStore = store
        return try await withIncomplete(store) { reminders in
            guard let match = reminders.first(where: { $0.title?.caseInsensitiveCompare(title) == .orderedSame }) else { return false }
            match.isCompleted = true
            try unsafeStore.save(match, commit: true)
            return true
        }
    }
}

public struct SystemContactsSearcher: ContactsSearching {
    public init() {}

    public func find(name: String) async throws -> [ContactMatch] {
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let found = try CNContactStore().unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)
        return found.map { contact in
            ContactMatch(
                name: CNContactFormatter.string(from: contact, style: .fullName) ?? "(no name)",
                phones: contact.phoneNumbers.map(\.value.stringValue),
                emails: contact.emailAddresses.map { $0.value as String })
        }
    }
}
