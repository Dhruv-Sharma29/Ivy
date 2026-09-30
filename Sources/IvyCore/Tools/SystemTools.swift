import Foundation
import os

// MARK: - notify

public protocol NotificationPosting: Sendable {
    func post(title: String, body: String?) async throws
}

/// Posts a local notification. Safe: it only shows text the user asked for; rate-limited so a looping model can't spam.
public final class NotifyTool: IvyTool, Sendable {
    public static let maxTitle = 80
    public static let maxBody = 250

    public let name = "notify"
    public let description = "Shows a macOS notification with a title and an optional body."
    public let group = ToolGroup.system
    public let safetyClassification = ToolSafetyClassification.safe
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "title": ToolProperty(type: "STRING", description: "Notification title, at most \(Self.maxTitle) characters."),
                "body": ToolProperty(type: "STRING", description: "Optional text under the title, at most \(Self.maxBody) characters."),
            ],
            required: ["title"]))
    }

    private let poster: NotificationPosting
    private let limiter: ToolRateLimiter

    public init(poster: NotificationPosting = SystemNotificationPoster(), limiter: ToolRateLimiter = ToolRateLimiter(limit: 5)) {
        self.poster = poster
        self.limiter = limiter
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> (title: String, body: String?) {
        let args = ToolArguments(arguments)
        try args.allow(["title", "body"])
        return (try args.string("title", max: Self.maxTitle), try args.optionalString("body", max: Self.maxBody, multiline: true))
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType] { [.notifications] }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        guard limiter.allow() else {
            return .failure("Too many notifications: at most 5 per minute. Try again shortly.")
        }
        do {
            try await poster.post(title: request.title, body: request.body)
            return .success("Notification shown: \(request.title)")
        } catch {
            return .failure("Couldn't show the notification: \(error.localizedDescription)")
        }
    }
}

// MARK: - clipboard

public protocol ClipboardAccessing: Sendable {
    /// The clipboard's text, or nil when it holds no text.
    func readText() async -> String?
    func writeText(_ text: String) async -> Bool
}

/// Reads or replaces the clipboard text. Both are risky: the clipboard routinely holds passwords and keys
/// (reading sends its contents to Gemini), and writing destroys what was there.
public final class ClipboardTool: IvyTool, Sendable {
    public static let maxWriteBytes = 100 * 1024

    enum Action: String, CaseIterable { case read, write }

    public let name = "clipboard"
    public let description = "Reads the text on the macOS clipboard, or replaces it with new text. Text only."
    public let group = ToolGroup.system
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "action": ToolProperty(type: "STRING", description: "'read' or 'write'."),
                "text": ToolProperty(type: "STRING", description: "For write: the text to put on the clipboard (at most 100 KB)."),
            ],
            required: ["action"]))
    }

    private let clipboard: ClipboardAccessing

    public init(clipboard: ClipboardAccessing = SystemClipboard()) {
        self.clipboard = clipboard
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> (action: Action, text: String?) {
        let args = ToolArguments(arguments)
        let action = try args.choice("action", Action.self)
        guard action == .write else {
            try args.allow(["action"])
            return (action, nil)
        }
        try args.allow(["action", "text"])
        let text = try args.string("text", max: Self.maxWriteBytes, multiline: true)
        guard text.utf8.count <= Self.maxWriteBytes else {
            throw ToolError.invalidArgument("Argument 'text' exceeds 100 KB.")
        }
        return (action, text)
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        guard let request = try? parse(arguments) else { return nil }
        if let text = request.text {
            let shown = text.count > 300 ? String(text.prefix(300)) + "… [truncated]" : text
            return ToolConfirmation(
                title: "Replace Clipboard",
                prompt: "You're about to let me overwrite your clipboard. Whatever you copied last is gone after this. Do it or chicken out?",
                detail: "Action: Replace clipboard text (\(text.count) characters)\nNew text:\n\(shown)")
        }
        return ToolConfirmation(
            title: "Read Clipboard",
            prompt: "You're about to show me your clipboard. If there's a password on it, that's on you. Do it or chicken out?",
            detail: "Action: Read clipboard text\nThe text is sent to Gemini to answer you. Anything that looks like an API key or token is masked first.")
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        if let text = request.text {
            guard await clipboard.writeText(text) else { return .failure("The clipboard couldn't be changed.") }
            return .success("Clipboard replaced (\(text.count) characters).", summary: "replaced the clipboard text")
        }
        guard let text = await clipboard.readText(), !text.isEmpty else {
            return .success("The clipboard has no text on it.", summary: "read the clipboard (no text)")
        }
        return .success(SecretRedactor.redact(text), summary: "read the clipboard (\(text.count) characters)")
    }
}

// MARK: - system_settings

public protocol URLOpening: Sendable {
    /// Hands the URL to macOS. False if nothing could open it.
    func open(_ url: URL) async -> Bool
}

/// Opens a pane of System Settings. It only navigates: nothing is changed.
public final class SystemSettingsTool: IvyTool, Sendable {
    /// The only panes Ivy opens. Identifiers are fixed here; the model never supplies a URL.
    public static let panes: [String: String] = [
        "general": "com.apple.systempreferences.GeneralSettings",
        "wifi": "com.apple.wifi-settings-extension",
        "bluetooth": "com.apple.BluetoothSettings",
        "network": "com.apple.Network-Settings.extension",
        "sound": "com.apple.Sound-Settings.extension",
        "displays": "com.apple.Displays-Settings.extension",
        "battery": "com.apple.Battery-Settings.extension",
        "notifications": "com.apple.Notifications-Settings.extension",
        "focus": "com.apple.Focus-Settings.extension",
        "appearance": "com.apple.Appearance-Settings.extension",
        "keyboard": "com.apple.Keyboard-Settings.extension",
        "trackpad": "com.apple.Trackpad-Settings.extension",
        "accessibility": "com.apple.Accessibility-Settings.extension",
        "privacy": "com.apple.settings.PrivacySecurity.extension",
        "software_update": "com.apple.Software-Update-Settings.extension",
        "storage": "com.apple.settings.Storage",
    ]

    public let name = "system_settings"
    public let description = "Opens a pane of macOS System Settings. It only opens the pane; it changes no setting."
    public let group = ToolGroup.system
    public let safetyClassification = ToolSafetyClassification.safe
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: ["pane": ToolProperty(type: "STRING", description: "One of: \(Self.panes.keys.sorted().joined(separator: ", ")).")],
            required: ["pane"]))
    }

    private let opener: URLOpening

    public init(opener: URLOpening = SystemURLOpener()) {
        self.opener = opener
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> (pane: String, url: URL) {
        let args = ToolArguments(arguments)
        try args.allow(["pane"])
        let pane = try args.string("pane", max: 40).lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
        guard let identifier = Self.panes[pane], let url = URL(string: "x-apple.systempreferences:\(identifier)") else {
            throw ToolError.invalidArgument("Unknown settings pane '\(pane)'. Supported: \(Self.panes.keys.sorted().joined(separator: ", ")).")
        }
        return (pane, url)
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        guard await opener.open(request.url) else { return .failure("System Settings couldn't open the \(request.pane) pane.") }
        return .success("Opened System Settings › \(request.pane).")
    }
}

// MARK: - volume_brightness

/// Output volume and mute (reversible, so safe). Display brightness has no public API Ivy may use: it reports
/// that instead of reaching for a private one.
public final class VolumeBrightnessTool: IvyTool, Sendable {
    enum Action: String, CaseIterable { case get_volume, set_volume, mute, unmute, get_brightness, set_brightness }

    public let name = "volume_brightness"
    public let description = "Gets or sets the Mac's output volume (0–100) and mute. Display brightness is reported as unsupported."
    public let group = ToolGroup.system
    public let safetyClassification = ToolSafetyClassification.safe
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "action": ToolProperty(type: "STRING", description: "One of: get_volume, set_volume, mute, unmute, get_brightness, set_brightness."),
                "level": ToolProperty(type: "INTEGER", description: "For set_volume / set_brightness: 0 to 100."),
            ],
            required: ["action"]))
    }

    private let executor: AppleScriptExecutorProtocol

    public init(executor: AppleScriptExecutorProtocol = SystemAppleScriptExecutor()) {
        self.executor = executor
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> (action: Action, level: Int?) {
        let args = ToolArguments(arguments)
        let action = try args.choice("action", Action.self)
        guard action == .set_volume || action == .set_brightness else {
            try args.allow(["action"])
            return (action, nil)
        }
        try args.allow(["action", "level"])
        // Out-of-range levels are clamped rather than refused: "volume 150" plainly means "all the way up".
        return (action, min(100, max(0, try args.int("level"))))
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        let script: String
        switch request.action {
        case .get_brightness, .set_brightness:
            return .failure("Display brightness isn't supported: macOS has no public way for Ivy to read or change it. Use the brightness keys, or ask me to open Displays settings.")
        case .get_volume:
            script = "set s to get volume settings\nreturn \"Volume \" & (output volume of s) & \"%, muted: \" & (output muted of s)"
        case .set_volume:
            script = "set volume output volume \(request.level ?? 0)\nreturn \"Volume set to \(request.level ?? 0)%.\""
        case .mute:
            script = "set volume output muted true\nreturn \"Muted.\""
        case .unmute:
            script = "set volume output muted false\nreturn \"Unmuted.\""
        }
        do {
            return .success(try await executor.execute(script: script))
        } catch {
            return .failure("Couldn't change the volume: \(error.localizedDescription)")
        }
    }
}

// MARK: - network_bluetooth

public protocol NetworkControlling: Sendable {
    /// A one-line description of Wi-Fi power and, when macOS allows it, the network name.
    func wifiStatus() async throws -> String
    func setWiFi(on: Bool) async throws
    func bluetoothStatus() async throws -> String
}

/// Wi-Fi and Bluetooth status are safe. Switching Wi-Fi is risky: turning it off cuts Ivy off from Gemini.
public final class NetworkBluetoothTool: IvyTool, Sendable {
    enum Action: String, CaseIterable { case wifi_status, wifi_on, wifi_off, bluetooth_status }

    public let name = "network_bluetooth"
    public let description = "Reports Wi-Fi and Bluetooth status, and turns Wi-Fi on or off. Turning Wi-Fi off disconnects Ivy."
    public let group = ToolGroup.system
    /// With no call to inspect, assume the dangerous action.
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: ["action": ToolProperty(type: "STRING", description: "One of: wifi_status, wifi_on, wifi_off, bluetooth_status.")],
            required: ["action"]))
    }

    private let network: NetworkControlling
    private let limiter: ToolRateLimiter

    public init(network: NetworkControlling = SystemNetworkController(), limiter: ToolRateLimiter = ToolRateLimiter(limit: 2)) {
        self.network = network
        self.limiter = limiter
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> Action {
        let args = ToolArguments(arguments)
        try args.allow(["action"])
        return try args.choice("action", Action.self)
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func classification(for arguments: [String: AnyCodable]) -> ToolSafetyClassification {
        switch try? parse(arguments) {
        case .wifi_status, .bluetooth_status: return .safe
        default: return .risky
        }
    }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        switch try? parse(arguments) {
        case .wifi_off:
            return ToolConfirmation(
                title: "Turn Wi-Fi Off",
                prompt: "You're about to turn Wi-Fi off. That cuts me off too, so don't expect a reply until you turn it back on yourself. Do it or chicken out?",
                detail: "Action: Turn Wi-Fi off\nWarning: Ivy needs the network. After this, Ivy cannot answer or turn Wi-Fi back on for you unless another connection (Ethernet) is active.")
        case .wifi_on:
            return ToolConfirmation(
                title: "Turn Wi-Fi On",
                prompt: "You're about to turn Wi-Fi on. Riveting. Do it or chicken out?",
                detail: "Action: Turn Wi-Fi on")
        default:
            return nil
        }
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let action = try parse(arguments)
        do {
            switch action {
            case .wifi_status:
                return .success(try await network.wifiStatus())
            case .bluetooth_status:
                return .success(try await network.bluetoothStatus())
            case .wifi_on, .wifi_off:
                guard limiter.allow() else {
                    return .failure("Wi-Fi was just switched: at most 2 changes per minute.")
                }
                try await network.setWiFi(on: action == .wifi_on)
                return .success(action == .wifi_on ? "Wi-Fi turned on." : "Wi-Fi turned off.")
            }
        } catch {
            return .failure("Network control failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - window

public struct WindowInfo: Sendable, Equatable {
    public let app: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(app: String, x: Int, y: Int, width: Int, height: Int) {
        self.app = app
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum WindowTile: String, CaseIterable, Sendable { case left, right, full }

public protocol WindowControlling: Sendable {
    /// On-screen windows only (app name and frame; titles would need Screen Recording).
    func list() async throws -> [WindowInfo]
    func focus(app: String) async throws
    /// Moves the app's front window. Coordinates are from the top-left of the main display.
    func setFrame(app: String, x: Int, y: Int, width: Int, height: Int) async throws
    func tile(app: String, _ position: WindowTile) async throws
}

/// Lists and focuses windows (safe), and moves or tiles them (risky: it rearranges the user's desktop and
/// needs Accessibility, which is asked for only once such a call has been approved).
public final class WindowTool: IvyTool, Sendable {
    enum Action: String, CaseIterable { case list, focus, move, tile }

    public static let sizeRange = 100...10_000
    public static let originRange = -10_000...10_000

    public let name = "window"
    public let description = "Lists on-screen windows, brings an app's window to the front, moves/resizes it, or tiles it to the left half, right half or full screen."
    public let group = ToolGroup.system
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "action": ToolProperty(type: "STRING", description: "One of: list, focus, move, tile."),
                "app": ToolProperty(type: "STRING", description: "App name for focus, move and tile (e.g. Safari)."),
                "x": ToolProperty(type: "INTEGER", description: "For move: left edge in points from the left of the main display."),
                "y": ToolProperty(type: "INTEGER", description: "For move: top edge in points from the top of the main display."),
                "width": ToolProperty(type: "INTEGER", description: "For move: width in points (100–10000)."),
                "height": ToolProperty(type: "INTEGER", description: "For move: height in points (100–10000)."),
                "position": ToolProperty(type: "STRING", description: "For tile: left, right or full."),
            ],
            required: ["action"]))
    }

    private let windows: WindowControlling

    public init(windows: WindowControlling = SystemWindowController()) {
        self.windows = windows
    }

    private enum Request {
        case list
        case focus(String)
        case move(String, x: Int, y: Int, width: Int, height: Int)
        case tile(String, WindowTile)
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> Request {
        let args = ToolArguments(arguments)
        switch try args.choice("action", Action.self) {
        case .list:
            try args.allow(["action"])
            return .list
        case .focus:
            try args.allow(["action", "app"])
            return .focus(try ToolValidation.validateAppName(try args.string("app", max: ToolValidation.maxAppNameLength)))
        case .tile:
            try args.allow(["action", "app", "position"])
            return .tile(try ToolValidation.validateAppName(try args.string("app", max: ToolValidation.maxAppNameLength)),
                         try args.choice("position", WindowTile.self))
        case .move:
            try args.allow(["action", "app", "x", "y", "width", "height"])
            let app = try ToolValidation.validateAppName(try args.string("app", max: ToolValidation.maxAppNameLength))
            let (x, y, width, height) = (try args.int("x"), try args.int("y"), try args.int("width"), try args.int("height"))
            guard Self.originRange.contains(x), Self.originRange.contains(y) else {
                throw ToolError.invalidArgument("Window position is out of bounds (x and y must be within ±10000).")
            }
            guard Self.sizeRange.contains(width), Self.sizeRange.contains(height) else {
                throw ToolError.invalidArgument("Window size is out of bounds (width and height must be 100–10000).")
            }
            return .move(app, x: x, y: y, width: width, height: height)
        }
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func classification(for arguments: [String: AnyCodable]) -> ToolSafetyClassification {
        switch try? parse(arguments) {
        case .list, .focus: return .safe
        default: return .risky
        }
    }

    public func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType] {
        switch try? parse(arguments) {
        case .move, .tile: return [.accessibility]
        default: return []
        }
    }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        switch try? parse(arguments) {
        case .move(let app, let x, let y, let width, let height):
            return ToolConfirmation(
                title: "Move Window",
                prompt: "You're about to let me shove \(app)'s window around. If your layout ends up a mess, don't blame me. Do it or chicken out?",
                detail: "Action: Move and resize the front window of \(app)\nPosition: (\(x), \(y))\nSize: \(width) × \(height)")
        case .tile(let app, let position):
            return ToolConfirmation(
                title: "Tile Window",
                prompt: "You're about to let me tile \(app). Apparently dragging a window is too much work. Do it or chicken out?",
                detail: "Action: Resize the front window of \(app) to the \(position == .full ? "full screen area" : "\(position.rawValue) half of the screen")")
        default:
            return nil
        }
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let request = try parse(arguments)
        do {
            switch request {
            case .list:
                let found = try await windows.list()
                guard !found.isEmpty else { return .success("No windows are on screen.") }
                return .success(found.prefix(40).map { "\($0.app): \($0.width)×\($0.height) at (\($0.x), \($0.y))" }.joined(separator: "\n"))
            case .focus(let app):
                try await windows.focus(app: app)
                return .success("Brought \(app) to the front.")
            case .move(let app, let x, let y, let width, let height):
                try await windows.setFrame(app: app, x: x, y: y, width: width, height: height)
                return .success("Moved \(app)'s window to (\(x), \(y)), size \(width)×\(height).")
            case .tile(let app, let position):
                try await windows.tile(app: app, position)
                return .success("Tiled \(app) \(position.rawValue).")
            }
        } catch {
            return .failure("Window control failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - screenshot

public struct ScreenCapture: Sendable, Equatable {
    public let png: Data
    public let width: Int
    public let height: Int

    public init(png: Data, width: Int, height: Int) {
        self.png = png
        self.width = width
        self.height = height
    }
}

public protocol ScreenCapturing: Sendable {
    func captureMainDisplay() async throws -> ScreenCapture
}

/// Captures the main display. Risky: the screen can show anything. The image stays in memory unless the user
/// asked for it to be saved; nothing is sent to Gemini here (image analysis is a later phase).
public final class ScreenshotTool: IvyTool, Sendable {
    public let name = "screenshot"
    public let description = "Takes a screenshot of the main display. Set save to true only when the user asked to keep it as a file (saved to the Desktop). Ivy cannot yet describe what is in the image."
    public let group = ToolGroup.system
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: ["save": ToolProperty(type: "BOOLEAN", description: "true to save the screenshot as a PNG on the Desktop. Default false (kept in memory only).")],
            required: nil))
    }

    private let capturer: ScreenCapturing
    private let saveDirectory: URL
    private let now: @Sendable () -> Date
    /// The most recent capture, for a later phase to analyse. Memory only; replaced by the next capture.
    private let last = OSAllocatedUnfairLockBox<ScreenCapture?>(nil)

    public init(
        capturer: ScreenCapturing = SystemScreenCapturer(),
        saveDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop"),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.capturer = capturer
        self.saveDirectory = saveDirectory
        self.now = now
    }

    public var lastCapture: ScreenCapture? { last.value }

    private func parse(_ arguments: [String: AnyCodable]) throws -> Bool {
        let args = ToolArguments(arguments)
        try args.allow(["save"])
        return try args.optionalBool("save") ?? false
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func requiredPermissions(for arguments: [String: AnyCodable]) -> [PermissionType] { [.screenRecording] }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        let save = (try? parse(arguments)) ?? false
        return ToolConfirmation(
            title: "Take Screenshot",
            prompt: "You're about to let me photograph your screen, embarrassing tabs and all. Do it or chicken out?",
            detail: "Action: Capture the main display\n" + (save
                ? "The image is saved as a PNG in \(saveDirectory.path)."
                : "The image is kept in memory only. It is not saved and not sent anywhere."))
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let save = try parse(arguments)
        let capture: ScreenCapture
        do {
            capture = try await capturer.captureMainDisplay()
        } catch {
            return .failure("Couldn't capture the screen: \(error.localizedDescription)")
        }
        last.value = capture
        guard save else {
            return .success("Captured the main display (\(capture.width)×\(capture.height)). It is held in memory only and was not saved.",
                            summary: "took a screenshot (not saved)")
        }
        let stamp = now().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let url = saveDirectory.appendingPathComponent("Ivy Screenshot \(stamp).png")
        do {
            try capture.png.write(to: url, options: .atomic)
            return .success("Saved the screenshot (\(capture.width)×\(capture.height)) to \(url.path).", summary: "took a screenshot and saved it to \(url.path)")
        } catch {
            return .failure("Captured the screen but couldn't save it: \(error.localizedDescription)")
        }
    }
}

/// A lock-protected value with plain get/set.
final class OSAllocatedUnfairLockBox<Value: Sendable>: Sendable {
    private let storage: OSAllocatedUnfairLock<Value>

    init(_ value: Value) {
        storage = OSAllocatedUnfairLock(initialState: value)
    }

    var value: Value {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
