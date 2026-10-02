import Testing
import Foundation
import CoreGraphics
@testable import IvyCore

@Suite("Branding - Ivy logo and app icon")
struct BrandingTests {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Renders into an RGBA buffer and returns (r, g, b, a) at a point given in unit coordinates (y up).
    private func render(size: Int, _ draw: (CGContext, CGFloat) -> Void) -> (Double, Double) -> (Int, Int, Int, Int) {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let ctx = CGContext(data: &pixels, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        draw(ctx, CGFloat(size))
        let snapshot = pixels
        return { x, y in
            let px = min(size - 1, Int(x * Double(size)))
            let row = size - 1 - min(size - 1, Int(y * Double(size)))  // buffer row 0 is the top
            let i = (row * size + px) * 4
            return (Int(snapshot[i]), Int(snapshot[i + 1]), Int(snapshot[i + 2]), Int(snapshot[i + 3]))
        }
    }

    @Test("app icon: transparent margin, opaque green plate, cream leaf")
    func appIconRendering() {
        let at = render(size: 256) { IvyLogo.drawAppIcon(in: $0, size: $1) }
        #expect(at(0.02, 0.5).3 == 0)                         // margin outside the plate
        let plate = at(0.15, 0.2)                               // plate corner area, away from the art
        #expect(plate.3 == 255 && plate.1 > plate.0 && plate.1 > plate.2)   // green-dominant
        let leaf = at(0.40, 0.55)                               // inside the left of the leaf body
        #expect(leaf.0 > 200 && leaf.1 > 200 && leaf.2 > 180)  // cream
    }

    @Test("menu-bar glyph: both leaves read clearly with transparent corners and separation")
    func templateGlyph() {
        // The menu mark now follows the two-leaf app identity, rather than the legacy veined leaf.
        for size in [18, 36, 72] {
            let at = render(size: size) { IvyLogo.drawTemplateGlyph(in: $0, size: $1) }
            #expect(at(0.45, 0.70).3 > 200)
            #expect(at(0.70, 0.35).3 > 200)
            #expect(at(0.02, 0.98).3 == 0)
            #expect(at(0.80, 0.65).3 < 100)
        }
    }

    @Test("leaf geometry stays inside its frame")
    func geometryBounds() {
        let frame = CGRect(x: 10, y: 20, width: 100, height: 100)
        let box = IvyLogo.leafPath(in: frame).boundingBoxOfPath
        #expect(frame.contains(box))
        #expect(box.width > 80 && box.height > 60)
        let sprig = IvyLogo.sprigPath(in: frame).boundingBoxOfPath
        #expect(frame.contains(sprig))
        #expect(sprig.width > 60 && sprig.height > 60)
    }

    @Test("bundle is configured to ship the icon")
    func bundleConfiguration() throws {
        let plistData = try Data(contentsOf: Self.repo.appendingPathComponent("Sources/Ivy/Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        #expect(plist["CFBundleIconFile"] as? String == "AppIcon")

        let icns = try Data(contentsOf: Self.repo.appendingPathComponent("Sources/Ivy/Resources/AppIcon.icns"))
        #expect(icns.prefix(4) == Data("icns".utf8))
        #expect(icns.count > 50_000)

        for script in ["scripts/run-ivy-app.sh", "scripts/package-release.sh"] {
            let text = try String(contentsOf: Self.repo.appendingPathComponent(script), encoding: .utf8)
            #expect(text.contains("AppIcon.icns"), "\(script) must copy the app icon into Contents/Resources")
        }
    }
}
