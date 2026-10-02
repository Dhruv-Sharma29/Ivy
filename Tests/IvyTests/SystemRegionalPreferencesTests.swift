import Foundation
import Testing
@testable import IvyCore

@Suite("Automatic system regional preferences")
struct SystemRegionalPreferencesTests {
    @Test("measurement systems and time zones come from the supplied system context")
    func regions() throws {
        let cases = [("en_US", "America/New_York", "US customary"),
                     ("en_GB", "Europe/London", "UK (miles and metric)"),
                     ("en_IN", "Asia/Kolkata", "Metric"),
                     ("fr_FR", "Europe/Paris", "Metric")]
        for (identifier, zone, units) in cases {
            let region = SystemRegionalPreferences(locale: Locale(identifier: identifier),
                timeZone: try #require(TimeZone(identifier: zone)))
            #expect(region.timeZone == zone)
            #expect(region.units == units)
            #expect(!region.language.isEmpty)
            #expect(region.aboutFields == ["timezone": zone, "units": units, "language": region.language])
        }
        let preferred = SystemRegionalPreferences(locale: Locale(identifier: "en_US"), timeZone: .gmt,
                                                 preferredLanguage: "fr")
        #expect(preferred.language == "French")
        let unknown = SystemRegionalPreferences(locale: Locale(identifier: "en_US"), timeZone: .gmt,
                                               preferredLanguage: "unknown-language")
        #expect(!unknown.language.isEmpty)
        #expect(SystemRegionalPreferences.current.timeZone == TimeZone.autoupdatingCurrent.identifier)
        #expect(PersonalizationProfile.AboutField.editableCases == [.name, .pronouns, .profession])
    }

    @Test("system preferences replace stale region fields without modifying saved profiles or safety rules")
    func promptContext() throws {
        var profile = PersonalizationProfile()
        profile.aboutMe = ["name": "Sam", "timezone": "Stale zone", "units": "Stale units", "language": "Stale language"]
        let region = SystemRegionalPreferences(locale: Locale(identifier: "en_US"), timeZone: .gmt,
                                              preferredLanguage: "en")
        let prompt = SystemPromptBuilder.build(profile: profile, region: region)
        #expect(prompt.hasPrefix(IvyPersona.systemPrompt))
        #expect(prompt.contains("Time zone: GMT"))
        #expect(prompt.contains("US customary"))
        #expect(prompt.contains("Language: English"))
        #expect(prompt.contains("What Ivy calls you: Sam"))
        #expect(!prompt.contains("Stale"))
        #expect(profile.aboutMe["timezone"] == "Stale zone")
        #expect(prompt.contains(SystemPromptBuilder.fenceOpen) && prompt.contains(SystemPromptBuilder.fenceClose))
        let defaults = SystemPromptBuilder.build(profile: PersonalizationProfile(), region: region)
        #expect(defaults.contains("Time zone: GMT"))
        // The context-free builder remains deterministic for exported profiles and persona tests.
        #expect(SystemPromptBuilder.build(profile: PersonalizationProfile()) == IvyPersona.systemPrompt)
    }
}
