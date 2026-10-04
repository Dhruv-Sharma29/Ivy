import SwiftUI

/// Neutral workspace surfaces with a restrained indigo accent.
enum IvyTheme {
    static let leaf = adaptive(light: (0.22, 0.33, 0.66), dark: (0.55, 0.67, 0.96))
    static let moss = adaptive(light: (0.22, 0.31, 0.54), dark: (0.72, 0.78, 0.90))
    static let sprout = adaptive(light: (0.90, 0.93, 0.97), dark: (0.19, 0.23, 0.32))
    static let canvas = adaptive(light: (0.97, 0.97, 0.98), dark: (0.105, 0.115, 0.13))
    static let surface = adaptive(light: (1.0, 1.0, 1.0), dark: (0.15, 0.16, 0.18))
    static let sidebar = adaptive(light: (0.94, 0.95, 0.96), dark: (0.13, 0.14, 0.16))
    static let sectionAccent = moss
    static let riskAmber = Color.orange
    static let dangerRed = Color.red

    static let cardRadius: CGFloat = 20
    static let bubbleRadius: CGFloat = 16
    static let codeRadius: CGFloat = 8

    static let codeFont = Font.system(size: 12, design: .monospaced)
    static let bodyFont = Font.system(size: 13)
    /// Ivy's own voice: empty states, onboarding, the companion.
    static let voiceFont = Font.system(size: 15, weight: .semibold)

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
