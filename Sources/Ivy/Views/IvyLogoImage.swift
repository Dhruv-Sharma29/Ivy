import AppKit
import IvyCore

/// The ivy-leaf logo as a template image: macOS tints it for light/dark menu bars, and SwiftUI tints it with
/// `foregroundStyle` elsewhere. Drawn from `IvyLogo`, the same geometry as the app icon.
enum IvyLogoImage {
    @MainActor static let template: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            IvyLogo.drawTemplateGlyph(in: ctx, size: rect.width)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ivy"
        return image
    }()
}
