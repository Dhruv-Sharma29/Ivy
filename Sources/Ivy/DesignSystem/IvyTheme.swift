import SwiftUI

/// Neutral macOS surfaces and one system accent keep title bars, selection and content consistent.
enum IvyTheme {
    static let leaf = Color.accentColor
    static let moss = adaptive(light: (0.12, 0.28, 0.53), dark: (0.60, 0.73, 0.95))
    static let sprout = adaptive(light: (0.91, 0.94, 0.98), dark: (0.18, 0.21, 0.27))
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let sidebar = Color(nsColor: .windowBackgroundColor)
    static let sectionAccent = moss
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
            let match = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua])
            let isDark = match == .darkAqua || match == .accessibilityHighContrastDarkAqua
            var c = isDark ? dark : light
            if match == .accessibilityHighContrastAqua {
                c = c.0 + c.1 + c.2 > 2.4 ? (1, 1, 1) : (c.0 * 0.8, c.1 * 0.8, c.2 * 0.8)
            }
            if match == .accessibilityHighContrastDarkAqua {
                c = c.0 + c.1 + c.2 < 0.8 ? (0, 0, 0) : (sqrt(c.0), sqrt(c.1), sqrt(c.2))
            }
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}
