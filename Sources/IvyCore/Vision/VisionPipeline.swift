import Foundation
import CoreGraphics
import Vision
import PDFKit
import UniformTypeIdentifiers

/// One line of recognised text and where it is (normalized 0…1, origin bottom-left).
public struct RecognizedText: Equatable, Sendable {
    public let text: String
    public let box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// On-device text recognition. Implementations must never send the image anywhere.
public protocol TextRecognizing: Sendable {
    /// `image` is an encoded image (PNG/JPEG); passing bytes keeps CGImage off actor boundaries.
    func recognize(_ image: Data) async throws -> [RecognizedText]
}

/// Apple Vision, on-device (`VNRecognizeTextRequest` never uploads).
public struct SystemTextRecognizer: TextRecognizing {
    public init() {}

    public func recognize(_ image: Data) async throws -> [RecognizedText] {
        guard let cgImage = ImageProcessing.decode(image) else { throw VisionError.unreadableImage }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedText(text: candidate.string, box: observation.boundingBox)
        }
    }
}

/// Turns a capture, an image file or a PDF into an attachment that is safe to send: OCR on this Mac, key-like
/// text blacked out, downscaled JPEG without metadata (or text only, if the user chose that).
public struct VisionPipeline: Sendable {
    public static let maxPDFPages = 50
    public static let maxPDFTextBytes = 200 * 1024
    public static let maxScannedPagesRendered = 10
    /// A page with less text than this is treated as a scan and rendered as an image.
    static let scannedPageThreshold = 40

    private let recognizer: TextRecognizing

    public init(recognizer: TextRecognizing = SystemTextRecognizer()) {
        self.recognizer = recognizer
    }

    /// A screenshot or image file.
    public func prepareImage(_ data: Data, source: ImageAttachment.Source, policy: VisionPolicy, frame: CGRect? = nil) async throws -> ImageAttachment {
        guard let image = ImageProcessing.decode(data) else { throw VisionError.unreadableImage }
        let scaled = ImageProcessing.downscaled(image)
        // OCR on the downscaled image: what Gemini would see, and much faster.
        let sample = try ImageProcessing.jpeg(scaled)
        let lines = (try? await recognizer.recognize(sample)) ?? []
        let secretBoxes = lines.filter { SecretRedactor.redact($0.text) != $0.text || SensitiveDataDetector.reason($0.text) != nil }.map(\.box)
        let text = lines.map(\.text).joined(separator: "\n")

        if policy.textOnly {
            guard !text.isEmpty else { throw VisionError.nothingToSend }
            return ImageAttachment(source: source, jpeg: [], text: text, maskedRegions: 0, keepTextInHistory: policy.keepTextInHistory)
        }
        let boxes = policy.maskSecrets ? secretBoxes : []
        let jpeg = boxes.isEmpty ? sample : try ImageProcessing.jpeg(ImageProcessing.masked(scaled, regions: boxes))
        let geometry = frame.map { CaptureGeometry(frame: $0, imageSize: CGSize(width: scaled.width, height: scaled.height)) }
        return ImageAttachment(source: source, jpeg: [jpeg], text: text.isEmpty ? nil : text,
                               maskedRegions: boxes.count, keepTextInHistory: policy.keepTextInHistory, geometry: geometry)
    }

    /// Text from every page (up to the limits); pages with almost no text are scans and are rendered as images
    /// (up to `maxScannedPagesRendered`, and never in text-only mode).
    public func preparePDF(_ data: Data, filename: String, policy: VisionPolicy) async throws -> ImageAttachment {
        guard let document = PDFDocument(data: data) else { throw VisionError.pdfUnreadable }
        let pageCount = document.pageCount
        var text = ""
        var scans: [Data] = []
        var truncated = false
        for index in 0..<min(pageCount, Self.maxPDFPages) {
            guard let page = document.page(at: index) else { continue }
            let pageText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if pageText.count < Self.scannedPageThreshold {
                if !policy.textOnly, scans.count < Self.maxScannedPagesRendered, let png = Self.render(page) {
                    scans.append(try await prepareImage(png, source: .pdf(filename: filename, pages: pageCount), policy: policy).jpeg.first ?? Data())
                }
                continue
            }
            let addition = "--- Page \(index + 1) ---\n\(pageText)\n"
            if text.utf8.count + addition.utf8.count > Self.maxPDFTextBytes {
                truncated = true
                break
            }
            text += addition
        }
        if pageCount > Self.maxPDFPages || truncated {
            text += "\n[Only part of this PDF was included: at most \(Self.maxPDFPages) pages and \(Self.maxPDFTextBytes / 1024) KB of text.]"
        }
        scans.removeAll { $0.isEmpty }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !scans.isEmpty else { throw VisionError.nothingToSend }
        return ImageAttachment(source: .pdf(filename: filename, pages: pageCount), jpeg: scans,
                               text: text.isEmpty ? nil : text, keepTextInHistory: policy.keepTextInHistory)
    }

    /// A page as JPEG at about 150 dpi (long edge capped later by `prepareImage`).
    static func render(_ page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 150.0 / 72.0
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0, let context = ImageProcessing.rgbContext(width: width, height: height) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { return nil }
        return try? ImageProcessing.jpeg(image)
    }

    /// Files the user dropped or picked: images and PDFs only.
    public func prepareFile(_ url: URL, policy: VisionPolicy) async throws -> ImageAttachment {
        let name = url.lastPathComponent
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        if let size = values?.fileSize, size > 50 * 1024 * 1024 { throw VisionError.tooLarge(name) }
        let data = try Data(contentsOf: url)
        if values?.contentType?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            return try await preparePDF(data, filename: name, policy: policy)
        }
        if values?.contentType?.conforms(to: .image) == true || ImageProcessing.decode(data) != nil {
            return try await prepareImage(data, source: .image(filename: name), policy: policy)
        }
        throw VisionError.unsupportedFile(name)
    }
}
