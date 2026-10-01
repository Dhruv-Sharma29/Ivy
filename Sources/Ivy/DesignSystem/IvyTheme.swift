import SwiftUI

/// Ivy's design tokens (Phase 17a). Colours come from the logo (`IvyLogo`); the system accent is not used for
/// Ivy's identity. Each colour has a light and a dark value.
enum IvyTheme {
    /// Primary green (#3BBE6E in light; lifted for contrast on dark backgrounds).
    static let leaf = adaptive(light: (0.231, 0.745, 0.431), dark: (0.36, 0.82, 0.53))
    /// Deep green for text on light tints (#0C5A36).
    static let moss = adaptive(light: (0.047, 0.353, 0.212), dark: (0.55, 0.87, 0.66))
    /// Light accent behind Ivy's own messages.
    static let sprout = adaptive(light: (0.90, 0.96, 0.91), dark: (0.13, 0.22, 0.16))
    static let riskAmber = Color.orange
    static let dangerRed = Color.red

    static let cardRadius: CGFloat = 12
    static let bubbleRadius: CGFloat = 16
    static let codeRadius: CGFloat = 8

    static let codeFont = Font.system(size: 12, design: .monospaced)
    static let bodyFont = Font.system(size: 13)
    /// Ivy's own voice: empty states, onboarding, the companion.
    static let voiceFont = Font.system(size: 15, weight: .semibold, design: .rounded)

    private static func adaptive(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}
