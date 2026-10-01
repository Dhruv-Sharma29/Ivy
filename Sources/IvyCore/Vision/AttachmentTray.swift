import Foundation
import Combine

/// What's attached to the message being written. Captures happen only here, only on a user action (a button,
/// a drop, a paste, the screen-help hotkey); nothing in this type runs on a timer or in the background.
@MainActor
public final class AttachmentTray: ObservableObject {
    public static let maxAttachments = 5
    public static let maxRequestBytes = 16 * 1024 * 1024

    @Published public private(set) var attachments: [ImageAttachment] = []
    @Published public private(set) var isWorking = false
    @Published public private(set) var lastError: String?
    /// Set by the screen-help hotkey: the question to pre-fill in the composer (never sent automatically).
    @Published public var suggestedPrompt: String?
    /// Bumped on every capture, for the "Ivy saw your screen" feedback.
    @Published public private(set) var captureCount = 0

    private let capturer: ScreenContextCapturing
    private let pipeline: VisionPipeline
    private let policy: () -> VisionPolicy
    /// Told which screenshot Ivy was actually shown (on send), for `point_at`.
    private let geometry: ScreenGeometryRelay?

    public init(capturer: ScreenContextCapturing = SystemScreenContext(), pipeline: VisionPipeline = VisionPipeline(),
                policy: @escaping () -> VisionPolicy = { VisionPolicy() }, geometry: ScreenGeometryRelay? = nil) {
        self.capturer = capturer
        self.pipeline = pipeline
        self.policy = policy
        self.geometry = geometry
    }

    /// The attachment was shown to Ivy (sent with a message, or as a Live frame).
    public func markShown(_ attachment: ImageAttachment) {
        if let shot = attachment.geometry { geometry?.record(shot) }
    }

    /// Captures the screen, a window or a region. Refuses while an excluded app (e.g. a password manager) is in front.
    @discardableResult
    public func capture(_ target: CaptureTarget) async -> ImageAttachment? {
        await work {
            let policy = self.policy()
            if let app = await self.capturer.frontmostOtherApp(), policy.isExcluded(app: app) {
                throw VisionError.excludedApp(app)
            }
            let shot = try await self.capturer.capture(target)
            // The capture may have been a window of an excluded app picked in the region selector.
            if policy.isExcluded(app: shot.app), target != .display {
                throw VisionError.excludedApp(shot.app ?? "")
            }
            self.captureCount += 1
            return try await self.pipeline.prepareImage(shot.png, source: .screenshot(app: shot.app), policy: policy, frame: shot.frame)
        }
    }

    @discardableResult
    public func addFile(_ url: URL) async -> ImageAttachment? {
        await work { try await self.pipeline.prepareFile(url, policy: self.policy()) }
    }

    /// Pasted or dropped image data with no file behind it.
    @discardableResult
    public func addImageData(_ data: Data, name: String = "pasted image") async -> ImageAttachment? {
        await work { try await self.pipeline.prepareImage(data, source: .image(filename: name), policy: self.policy()) }
    }

    public func remove(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Hands the attachments to the message being sent and empties the tray.
    public func take() -> [ImageAttachment] {
        defer { attachments = [] }
        attachments.forEach(markShown)
        return attachments
    }

    public func clear() {
        attachments = []
        lastError = nil
    }

    public func dismissError() {
        lastError = nil
    }

    /// What one request would carry, for the composer ("2 images · 1.4 MB").
    public var summary: String {
        let bytes = attachments.reduce(0) { $0 + $1.byteCount }
        let count = attachments.count
        return "\(count) attachment\(count == 1 ? "" : "s")" + (bytes > 0 ? " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) : "")
    }

    private func work(_ make: @escaping () async throws -> ImageAttachment) async -> ImageAttachment? {
        guard attachments.count < Self.maxAttachments else {
            lastError = "At most \(Self.maxAttachments) attachments per message."
            return nil
        }
        isWorking = true
        defer { isWorking = false }
        do {
            let attachment = try await make()
            let total = attachments.reduce(0) { $0 + $1.byteCount } + attachment.byteCount
            guard total <= Self.maxRequestBytes else { throw VisionError.tooLarge("Together, these attachments are") }
            attachments.append(attachment)
            lastError = nil
            return attachment
        } catch VisionError.cancelled {
            return nil
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
