import CoreGraphics
import Foundation

/// Small monochrome branding uses a paired-leaf sprig. The old colour renderer is retained for compatibility;
/// the production app icon is generated from Resources/IvyAppIcon.png by scripts/make-app-icon.sh.
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

    /// Two bold pointed leaves reproduce the app icon's sprig at small sizes, without tiny veins or shading.
    public static func sprigPath(in r: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: p(0.56, 0.49, r))
        path.addCurve(to: p(0.30, 0.60, r), control1: p(0.44, 0.47, r), control2: p(0.43, 0.56, r))
        path.addQuadCurve(to: p(0.35, 0.70, r), control: p(0.40, 0.69, r))
        path.addCurve(to: p(0.27, 0.92, r), control1: p(0.35, 0.76, r), control2: p(0.29, 0.84, r))
        path.addCurve(to: p(0.58, 0.74, r), control1: p(0.35, 0.82, r), control2: p(0.58, 0.90, r))
        path.addCurve(to: p(0.56, 0.49, r), control1: p(0.65, 0.64, r), control2: p(0.57, 0.54, r))
        path.closeSubpath()
        path.move(to: p(0.48, 0.28, r))
        path.addCurve(to: p(0.67, 0.49, r), control1: p(0.54, 0.42, r), control2: p(0.54, 0.51, r))
        path.addCurve(to: p(0.92, 0.48, r), control1: p(0.75, 0.48, r), control2: p(0.81, 0.44, r))
        path.addQuadCurve(to: p(0.80, 0.35, r), control: p(0.84, 0.39, r))
        path.addQuadCurve(to: p(0.82, 0.18, r), control: p(0.77, 0.30, r))
        path.addCurve(to: p(0.48, 0.28, r), control1: p(0.67, 0.29, r), control2: p(0.66, 0.18, r))
        path.closeSubpath()
        return path
    }

    /// Monochrome template glyph: macOS supplies the foreground colour for any menu-bar appearance.
    public static func drawTemplateGlyph(in ctx: CGContext, size: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let art = CGRect(x: 0, y: 0, width: size, height: size)
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.addPath(sprigPath(in: art))
        ctx.fillPath()
        let stem = CGMutablePath()
        stem.move(to: p(0.18, 0.10, art))
        stem.addQuadCurve(to: p(0.52, 0.35, art), control: p(0.39, 0.13, art))
        stem.addCurve(to: p(0.57, 0.61, art), control1: p(0.64, 0.51, art), control2: p(0.62, 0.56, art))
        ctx.addPath(stem)
        ctx.setLineWidth(max(1, size * 0.06))
        ctx.setLineCap(.round)
        ctx.strokePath()
    }
}
