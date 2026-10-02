import Foundation

/// Read on demand, never persisted in the profile. macOS owns these preferences.
public struct SystemRegionalPreferences: Equatable, Sendable {
    public let timeZone: String
    public let units: String
    public let language: String

    public init(locale: Locale, timeZone: TimeZone, preferredLanguage: String? = nil) {
        self.timeZone = timeZone.identifier
        switch locale.measurementSystem {
        case .us: units = "US customary"
        case .uk: units = "UK (miles and metric)"
        default: units = "Metric"
        }
        let identifier = preferredLanguage ?? locale.identifier
        language = locale.localizedString(forIdentifier: identifier) ?? identifier
    }

    public static var current: Self {
        Self(locale: .autoupdatingCurrent, timeZone: .autoupdatingCurrent,
             preferredLanguage: Locale.preferredLanguages.first)
    }

    public var aboutFields: [String: String] {
        ["timezone": timeZone, "units": units, "language": language]
    }
}
