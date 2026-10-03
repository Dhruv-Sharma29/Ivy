import AppKit
import SwiftUI
import IvyCore

/// The professional app icon plus its swept, pointed monochrome mark for menu-bar sizes.
/// macOS tints the template automatically for light and dark menu bars.
enum IvyLogoImage {
    @MainActor static let appIcon: NSImage? = Bundle.module.url(forResource: "IvyAppIcon", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }
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

/// The app identity stays compact; the workspace contains no decorative character artwork.
struct IvyAppIconView: View {
    var body: some View {
        if let image = IvyLogoImage.appIcon {
            Image(nsImage: image).resizable().scaledToFit().accessibilityHidden(true)
        } else {
            Image(nsImage: IvyLogoImage.template).resizable().scaledToFit()
                .foregroundStyle(IvyTheme.moss).accessibilityHidden(true)
        }
    }
}
