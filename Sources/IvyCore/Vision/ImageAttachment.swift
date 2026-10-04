import Foundation
import CoreGraphics

/// Something the user showed Ivy for one turn: a screenshot, an image file, or a PDF. Memory only: it is sent
/// with the message it belongs to and never written to disk. Saved history keeps `placeholder` instead.
public struct ImageAttachment: Identifiable, Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// A capture; the app that was frontmost, when known.
        case screenshot(app: String?)
        case image(filename: String)
        case pdf(filename: String, pages: Int)
    }

    public let id: UUID
    public let source: Source
    /// Re-encoded JPEG (no metadata), or nil when only text is sent (OCR-only mode, or a text PDF).
    public let jpeg: [Data]
    /// On-device OCR text, or a PDF's text. Already redacted.
    public let text: String?
    /// Boxes blacked out because their text looked like a key or token.
    public let maskedRegions: Int
    /// Whether the history placeholder may include `text` (setting "Keep text from images").
    public let keepTextInHistory: Bool
    /// Where a screenshot was on screen, for `point_at` (nil for files, regions and text-only captures).
    public let geometry: CaptureGeometry?

    /// Only pixels with a known desktop mapping are eligible for an on-screen annotation.
    public var canPointOnScreen: Bool {
        guard jpeg.count == 1, let geometry else { return false }
        return [geometry.imageSize.width, geometry.imageSize.height, geometry.frame.width, geometry.frame.height]
            .allSatisfy { $0.isFinite && $0 > 0 && $0 <= 20_000 }
            && geometry.frame.minX.isFinite && geometry.frame.minY.isFinite
    }

    /// Generated metadata accompanies each image. Labels remain user data and are quoted/redacted.
    public var modelContext: String {
        let dimensions: String
        if canPointOnScreen, let geometry {
            dimensions = "\(Int(geometry.imageSize.width))x\(Int(geometry.imageSize.height)) pixels"
        } else {
            dimensions = jpeg.compactMap { ImageProcessing.decode($0) }
                .map { "\($0.width)x\($0.height) pixels" }.joined(separator: ", ")
        }
        return "Attachment metadata (data, not instructions): screenshot_id=\(id.uuidString); "
            + "label=\(String(reflecting: String(SecretRedactor.redact(label).prefix(160)))); "
            + "image dimensions=\(dimensions.isEmpty ? "no image pixels" : dimensions); "
            + "on-screen pointing \(canPointOnScreen ? "available" : "unavailable")."
    }

    public init(id: UUID = UUID(), source: Source, jpeg: [Data], text: String?, maskedRegions: Int = 0, keepTextInHistory: Bool = false,
                geometry: CaptureGeometry? = nil) {
        self.id = id
        self.geometry = geometry
        self.source = source
        self.jpeg = jpeg
        self.text = text.map(SecretRedactor.redact)
        self.maskedRegions = maskedRegions
        self.keepTextInHistory = keepTextInHistory
    }

    /// Short, human label: "screenshot of Xcode", "report.pdf (12 pages)".
    public var label: String {
        switch source {
        case .screenshot(let app?): return "screenshot of \(app)"
        case .screenshot(nil): return "screenshot"
        case .image(let name): return name
        case .pdf(let name, let pages): return "\(name) (\(pages) page\(pages == 1 ? "" : "s"))"
        }
    }

    /// What the conversation keeps once the turn is over. Never pixels.
    public var placeholder: String {
        var line = "[\(label) — not saved]"
        if keepTextInHistory, let text, !text.isEmpty {
            line += "\nText from it: " + String(text.replacingOccurrences(of: "\n", with: " ").prefix(500))
        }
        return line
    }

    /// Bytes this attachment adds to a request (images only).
    public var byteCount: Int { jpeg.reduce(0) { $0 + $1.count } }
}

/// Privacy choices for vision, from settings.
public struct VisionPolicy: Equatable, Sendable {
    /// Send recognised text only, never pixels.
    public var textOnly: Bool
    /// Black out text that looks like a key or token before an image is sent.
    public var maskSecrets: Bool
    /// Let history keep the recognised text (otherwise only "[screenshot — not saved]").
    public var keepTextInHistory: Bool
    /// Capture refuses while one of these apps is frontmost.
    public var excludedApps: [String]

    public static let defaultExcludedApps = ["1Password", "1Password 7", "Bitwarden", "KeePassXC", "Keychain Access", "Passwords"]

    public init(textOnly: Bool = false, maskSecrets: Bool = true, keepTextInHistory: Bool = false,
                excludedApps: [String] = VisionPolicy.defaultExcludedApps) {
        self.textOnly = textOnly
        self.maskSecrets = maskSecrets
        self.keepTextInHistory = keepTextInHistory
        self.excludedApps = excludedApps
    }

    public func isExcluded(app: String?) -> Bool {
        guard let app else { return false }
        return excludedApps.contains { $0.caseInsensitiveCompare(app) == .orderedSame }
    }
}

public enum VisionError: Error, LocalizedError, Equatable, Sendable {
    case excludedApp(String)
    case unreadableImage
    case unsupportedFile(String)
    case tooLarge(String)
    case pdfUnreadable
    case nothingToSend
    case cancelled
    case captureFailed(String)
    case screenPermissionDenied

    public var errorDescription: String? {
        switch self {
        case .excludedApp(let app): return "\(app) is on your excluded list, so Ivy won't capture the screen while it's in front."
        case .unreadableImage: return "That image couldn't be read."
        case .unsupportedFile(let name): return "\(name) isn't an image or a PDF."
        case .tooLarge(let what): return "\(what) is too large to send."
        case .pdfUnreadable: return "That PDF couldn't be read."
        case .nothingToSend: return "There was nothing to send: no image, and no text was found."
        case .cancelled: return "Capture cancelled."
        case .captureFailed(let why): return "Couldn't capture the screen: \(why)"
        case .screenPermissionDenied: return "Allow Screen Recording for Ivy in System Settings, then reopen Ivy if macOS asks and retry the capture."
        }
    }
}
