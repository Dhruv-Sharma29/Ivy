import Foundation

/// Single source of truth for Ivy's application and release metadata.
public enum IvyVersion: Sendable {
    /// Semantic marketing version of the application.
    public static let marketingVersion = "1.1.0"

    /// Sequential build number.
    public static let buildNumber = "2"

    /// Formal macOS bundle identifier matching code signing and entitlements.
    public static let bundleIdentifier = "com.ivy.assistant"

    /// Application display name.
    public static let appName = "Ivy"

    /// Formatted display string combining marketing version and build number.
    public static var displayVersion: String {
        "v\(marketingVersion) (\(buildNumber))"
    }

    /// Complete user-agent string for outbound network requests (Gemini, ElevenLabs).
    public static var userAgent: String {
        "Ivy/\(marketingVersion) (\(bundleIdentifier); build \(buildNumber)) macOS"
    }
}
