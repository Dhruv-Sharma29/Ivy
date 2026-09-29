import CoreGraphics
import Foundation

/// Ivy's logo: a three-lobed ivy leaf with a sparkle, drawn from code so the app icon, the menu-bar glyph and any
/// in-app artwork share one geometry. Self-contained (CoreGraphics only) so `scripts/make-app-icon.sh` can compile
/// it standalone to render `AppIcon.icns`.
public enum IvyLogo {
    // Brand colours (sRGB).
    static let leafLight = CGColor(srgbRed: 0.231, green: 0.745, blue: 0.431, alpha: 1)   // #3BBE6E
    static let leafDeep = CGColor(srgbRed: 0.047, green: 0.353, blue: 0.212, alpha: 1)    // #0C5A36
    static let cream = CGColor(srgbRed: 0.965, green: 0.953, blue: 0.890, alpha: 1)       // #F6F3E3
    static let vein = CGColor(srgbRed: 0.110, green: 0.525, blue: 0.314, alpha: 1)        // #1C8650
    static let spark = CGColor(srgbRed: 1.000, green: 0.855, blue: 0.431, alpha: 1)       // #FFDA6E

    /// Maps a point in the unit design space (0...1, y up) into `rect`.
    private static func p(_ x: CGFloat, _ y: CGFloat, _ r: CGRect) -> CGPoint {
        CGPoint(x: r.minX + x * r.width, y: r.minY + y * r.height)
    }

    /// Leaf silhouette: pointed top lobe, two side lobes, a notch at the base.
    public static func leafPath(in r: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: p(0.50, 0.25, r))                                                   // base notch
        path.addCurve(to: p(0.05, 0.53, r), control1: p(0.34, 0.12, r), control2: p(0.10, 0.30, r))   // lower left → pointed left tip
        path.addCurve(to: p(0.35, 0.61, r), control1: p(0.16, 0.60, r), control2: p(0.28, 0.62, r))   // left tip → notch
        path.addCurve(to: p(0.50, 0.95, r), control1: p(0.30, 0.77, r), control2: p(0.43, 0.88, r))   // up to top tip
        path.addCurve(to: p(0.65, 0.61, r), control1: p(0.57, 0.88, r), control2: p(0.70, 0.77, r))   // top tip → notch
        path.addCurve(to: p(0.95, 0.53, r), control1: p(0.72, 0.62, r), control2: p(0.84, 0.60, r))   // notch → pointed right tip
        path.addCurve(to: p(0.50, 0.25, r), control1: p(0.90, 0.30, r), control2: p(0.66, 0.12, r))   // lower right
        path.closeSubpath()
        return path
    }

    /// Central vein plus one vein into each side lobe (stroked).
    public static func veinsPath(in r: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: p(0.50, 0.27, r))
        path.addQuadCurve(to: p(0.50, 0.80, r), control: p(0.49, 0.55, r))
        path.move(to: p(0.50, 0.36, r))
        path.addQuadCurve(to: p(0.17, 0.51, r), control: p(0.34, 0.40, r))
        path.move(to: p(0.50, 0.36, r))
        path.addQuadCurve(to: p(0.83, 0.51, r), control: p(0.66, 0.40, r))
        return path
    }

    /// Curling stem below the leaf (stroked).
    public static func stemPath(in r: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: p(0.50, 0.26, r))
        path.addCurve(to: p(0.40, 0.06, r), control1: p(0.51, 0.15, r), control2: p(0.46, 0.08, r))
        return path
    }

    /// Four-point sparkle centred at `c`.
    public static func sparklePath(center c: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let w = radius * 0.28
        path.move(to: CGPoint(x: c.x, y: c.y + radius))
        path.addQuadCurve(to: CGPoint(x: c.x + radius, y: c.y), control: CGPoint(x: c.x + w, y: c.y + w))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y - radius), control: CGPoint(x: c.x + w, y: c.y - w))
        path.addQuadCurve(to: CGPoint(x: c.x - radius, y: c.y), control: CGPoint(x: c.x - w, y: c.y - w))
        path.addQuadCurve(to: CGPoint(x: c.x, y: c.y + radius), control: CGPoint(x: c.x - w, y: c.y + w))
        path.closeSubpath()
        return path
    }

    /// Full-colour macOS app icon on a `size`×`size` canvas (y up), following Apple's icon grid:
    /// 824/1024 rounded-square plate with transparent margin and a soft drop shadow.
    public static func drawAppIcon(in ctx: CGContext, size: CGFloat) {
        let s = size / 1024
        let plate = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let platePath = CGPath(roundedRect: plate, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)

        // Plate with shadow and vertical gradient.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 24 * s, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(platePath)
        ctx.setFillColor(leafDeep)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(platePath)
        ctx.clip()
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        if let gradient = CGGradient(colorsSpace: space, colors: [leafLight, leafDeep] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plate.maxY), end: CGPoint(x: 0, y: plate.minY), options: [])
        }
        // Soft highlight in the upper half for depth.
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.06))
        ctx.fillEllipse(in: CGRect(x: plate.minX - 120 * s, y: plate.midY, width: plate.width + 240 * s, height: plate.height))
        ctx.restoreGState()

        // Leaf, stem and veins.
        let art = plate.insetBy(dx: 120 * s, dy: 110 * s).offsetBy(dx: -8 * s, dy: -6 * s)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * s), blur: 14 * s, color: CGColor(gray: 0, alpha: 0.25))
        ctx.addPath(stemPath(in: art))
        ctx.setStrokeColor(cream)
        ctx.setLineWidth(26 * s)
        ctx.setLineCap(.round)
        ctx.strokePath()
        ctx.addPath(leafPath(in: art))
        ctx.setFillColor(cream)
        ctx.fillPath()
        ctx.restoreGState()

        ctx.addPath(veinsPath(in: art))
        ctx.setStrokeColor(vein)
        ctx.setLineWidth(14 * s)
        ctx.setLineCap(.round)
        ctx.strokePath()

        // Sparkle: Ivy's AI spark, top right.
        ctx.addPath(sparklePath(center: CGPoint(x: plate.maxX - 190 * s, y: plate.maxY - 180 * s), radius: 78 * s))
        ctx.setFillColor(spark)
        ctx.fillPath()
        ctx.addPath(sparklePath(center: CGPoint(x: plate.maxX - 110 * s, y: plate.maxY - 285 * s), radius: 34 * s))
        ctx.fillPath()
    }

    /// Monochrome glyph for the menu bar (template image: black + alpha; macOS tints it for light/dark).
    public static func drawTemplateGlyph(in ctx: CGContext, size: CGFloat) {
        let art = CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.02, dy: size * 0.02)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(leafPath(in: art))
        ctx.fillPath()
        ctx.addPath(stemPath(in: art))
        ctx.setLineWidth(max(1, size * 0.07))
        ctx.setLineCap(.round)
        ctx.strokePath()
        // Veins knocked out of the silhouette so the leaf reads at 18 pt.
        ctx.setBlendMode(.clear)
        ctx.addPath(veinsPath(in: art))
        ctx.setLineWidth(max(1, size * 0.055))
        ctx.strokePath()
        ctx.setBlendMode(.normal)
    }
}
