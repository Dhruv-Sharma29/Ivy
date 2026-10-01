import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Decoding, downscaling, masking and JPEG encoding. Everything happens in memory; encoding through ImageIO
/// with no properties drops EXIF/GPS and every other piece of metadata.
public enum ImageProcessing {
    public static let maxLongEdge = 2048
    public static let maxBytes = 4 * 1024 * 1024
    public static let jpegQuality = 0.8

    /// PNG, JPEG, HEIC, WebP, TIFF, GIF… whatever ImageIO reads. Orientation is applied.
    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize(source),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The source's own long edge, so decode() never upscales and never downscales by itself.
    private static func maxPixelSize(_ source: CGImageSource) -> Int {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return 16_384 }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        return max(1, max(w, h))
    }

    /// Scaled so the long edge is at most `maxLongEdge` (never upscaled).
    public static func downscaled(_ image: CGImage, maxLongEdge: Int = maxLongEdge) -> CGImage {
        let longEdge = max(image.width, image.height)
        guard longEdge > maxLongEdge else { return image }
        let scale = Double(maxLongEdge) / Double(longEdge)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard let context = rgbContext(width: width, height: height) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// Fills `regions` (normalized 0…1, origin bottom-left as Vision reports them) with black, slightly padded.
    public static func masked(_ image: CGImage, regions: [CGRect]) -> CGImage {
        guard !regions.isEmpty, let context = rgbContext(width: image.width, height: image.height) else { return image }
        let size = CGSize(width: image.width, height: image.height)
        context.draw(image, in: CGRect(origin: .zero, size: size))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        for region in regions {
            let rect = CGRect(x: region.minX * size.width, y: region.minY * size.height,
                              width: region.width * size.width, height: region.height * size.height)
            context.fill(rect.insetBy(dx: -4, dy: -4))
        }
        return context.makeImage() ?? image
    }

    /// JPEG at `jpegQuality`, lowering quality (then size) until it fits `maxBytes`. No metadata is written.
    public static func jpeg(_ image: CGImage) throws -> Data {
        var current = downscaled(image)
        var quality = jpegQuality
        for _ in 0..<8 {
            if let data = encode(current, quality: quality), data.count <= maxBytes { return data }
            if quality > 0.5 {
                quality -= 0.15
            } else {
                current = downscaled(current, maxLongEdge: max(256, Int(Double(max(current.width, current.height)) * 0.75)))
            }
        }
        throw VisionError.tooLarge("The image")
    }

    static func encode(_ image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    static func rgbContext(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
