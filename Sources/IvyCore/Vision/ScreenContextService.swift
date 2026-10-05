import Foundation
import AppKit
import CoreGraphics
import ScreenCaptureKit

public enum CaptureTarget: String, CaseIterable, Sendable {
    /// The main display, without Ivy's own windows.
    case display
    /// The frontmost window that isn't Ivy's.
    case frontWindow
    /// A region (or window) the user picks with the system selector; Esc cancels.
    case region
}

public struct CapturedScreen: Equatable, Sendable {
    public let png: Data
    /// The app that owns what was captured (front window), or the frontmost other app (display/region).
    public let app: String?
    /// Where it was on screen (global points, origin top-left), when known — lets `point_at` find it again.
    public let frame: CGRect?

    public init(png: Data, app: String?, frame: CGRect? = nil) {
        self.png = png
        self.app = app
        self.frame = frame
    }
}

public protocol ScreenContextCapturing: Sendable {
    /// The frontmost app other than Ivy (checked against the exclusion list before any capture).
    func frontmostOtherApp() async -> String?
    func capture(_ target: CaptureTarget) async throws -> CapturedScreen
}

/// ScreenCaptureKit for display and window; the system `screencapture -i` selector for regions.
public struct SystemScreenContext: ScreenContextCapturing, SelectedRegionCapturing {
    public init() {}

    private static var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    /// Front-to-back on-screen app windows (layer 0) not owned by Ivy: (window id, owner name).
    static func frontOtherWindow() -> (id: CGWindowID, app: String)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        for window in windows {
            guard window[kCGWindowLayer as String] as? Int == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let id = window[kCGWindowNumber as String] as? CGWindowID,
                  let app = window[kCGWindowOwnerName as String] as? String else { continue }
            return (id, app)
        }
        return nil
    }

    public func frontmostOtherApp() async -> String? {
        Self.frontOtherWindow()?.app
    }

    public func capture(_ target: CaptureTarget) async throws -> CapturedScreen {
        do {
            switch target {
            case .display: return try await captureDisplay()
            case .frontWindow: return try await captureFrontWindow()
            case .region: return try await captureRegion()
            }
        } catch {
            throw Self.userFacingError(error)
        }
    }

    /// Captures the reviewed bounds in memory; excluded apps are removed even when behind another window.
    public func capture(selection: ScreenRegionSelection, excludedApps: [String]) async throws -> CapturedScreen {
        do {
            let front = Self.frontOtherWindow()
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard front?.id == Self.frontOtherWindow()?.id,
                  let display = content.displays.first(where: { $0.displayID == selection.displayID }),
                  let frame = await MainActor.run(body: {
                      NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) == selection.displayID }?.frame
                  }), frame == selection.screen else {
                throw VisionError.captureFailed("the window or display changed. Select the area again.")
            }
            let policy = VisionPolicy(excludedApps: excludedApps)
            if policy.isExcluded(app: front?.app) { throw VisionError.excludedApp(front?.app ?? "") }
            let excluded = content.applications.filter { $0.processID == Self.ownPID || policy.isExcluded(app: $0.applicationName) }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.sourceRect = selection.sourceRect
            guard let size = selection.pixelSize(atScale: CGFloat(filter.pointPixelScale)) else {
                throw VisionError.captureFailed("the display scale is invalid. Select again.")
            }
            config.width = Int(size.width)
            config.height = Int(size.height)
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try Task.checkCancellation()
            guard front?.id == Self.frontOtherWindow()?.id else {
                throw VisionError.captureFailed("the front window changed. Select again.")
            }
            guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                throw VisionError.captureFailed("the selected area couldn't be encoded.")
            }
            let origin = CGDisplayBounds(display.displayID).origin
            let source = selection.sourceRect
            return CapturedScreen(png: png, app: front?.app,
                frame: CGRect(x: origin.x + source.minX, y: origin.y + source.minY, width: source.width, height: source.height))
        } catch { throw Self.userFacingError(error) }
    }

    /// Match the framework's error identity, not its localized technical wording.
    public static func userFacingError(_ error: Error) -> Error {
        let cocoa = error as NSError
        if cocoa.domain == SCStreamErrorDomain, cocoa.code == SCStreamError.Code.userDeclined.rawValue {
            return VisionError.screenPermissionDenied
        }
        return error
    }

    private func captureDisplay() async throws -> CapturedScreen {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw VisionError.captureFailed("no display is available.")
        }
        let ivy = content.applications.filter { $0.processID == Self.ownPID }
        let filter = SCContentFilter(display: display, excludingApplications: ivy, exceptingWindows: [])
        return CapturedScreen(png: try await shoot(filter), app: Self.frontOtherWindow()?.app, frame: CGDisplayBounds(display.displayID))
    }

    private func captureFrontWindow() async throws -> CapturedScreen {
        guard let front = Self.frontOtherWindow() else { throw VisionError.captureFailed("no other window is on screen.") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == front.id }) else {
            throw VisionError.captureFailed("the front window can't be captured.")
        }
        return CapturedScreen(png: try await shoot(SCContentFilter(desktopIndependentWindow: window)), app: front.app, frame: window.frame)
    }

    private func shoot(_ filter: SCContentFilter) async throws -> Data {
        let configuration = SCStreamConfiguration()
        configuration.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
        configuration.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw VisionError.captureFailed("the capture couldn't be encoded.")
        }
        return png
    }

    /// ponytail: the system selector writes its result to a file. It goes to a private (0700) folder and is
    /// deleted as soon as it's read; replace with an in-process overlay (Phase 14.2) to keep pixels off disk.
    private func captureRegion() async throws -> CapturedScreen {
        let app = Self.frontOtherWindow()?.app
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ivy-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("region.png")
        _ = try? await ProcessRunner.run("/usr/sbin/screencapture", ["-i", "-x", "-t", "png", file.path])
        guard let data = FileManager.default.contents(atPath: file.path), !data.isEmpty else { throw VisionError.cancelled }
        return CapturedScreen(png: data, app: app)
    }
}
