import Foundation

/// How Ivy talks to this user. Prompt data only: nothing here reaches SafetyGate, tool classification or
/// confirmation, and nothing sensitive (credentials, IDs, card numbers) may be stored in it.
public struct PersonalizationProfile: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let sassRange = 0...3
    /// Ivy's usual voice.
    public static let defaultSass = 2
    public static let maxCustomInstructions = 1_500
    public static let maxAboutValue = 80
    public static let maxPreferenceLength = 120
    public static let maxPreferences = 50
    public static let maxShortcuts = 30
    public static let maxShortcutPrompt = 1_000

    public enum ResponseLength: String, Codable, CaseIterable, Sendable {
        case brief, balanced, detailed
    }

    /// The only "about me" facts Ivy keeps.
    public enum AboutField: String, CaseIterable, Sendable {
        case name, pronouns, timezone, units, language, profession

        /// Regional fields remain decodable for older profiles; Settings follows macOS automatically.
        public static var editableCases: [Self] { [.name, .pronouns, .profession] }

        public var label: String {
            switch self {
            case .name: return "What Ivy calls you"
            case .pronouns: return "Pronouns"
            case .timezone: return "Time zone"
            case .units: return "Units (metric / imperial)"
            case .language: return "Language"
            case .profession: return "What you do"
            }
        }
    }

    /// Roles a favourite app can fill ("open my editor").
    public enum AppRole: String, CaseIterable, Sendable {
        case editor, browser, notes, terminal, music, mail
    }

    public var schemaVersion = PersonalizationProfile.currentSchemaVersion
    /// 0 = plain and polite, 2 = default Ivy, 3 = extra roast.
    public var sass = PersonalizationProfile.defaultSass
    public var responseLength = ResponseLength.balanced
    public var useEmoji = false
    public var customInstructions = ""
    /// Keys are `AboutField` raw values; anything else is dropped on load.
    public var aboutMe: [String: String] = [:]
    /// Keys are `AppRole` raw values, values app names.
    public var favoriteApps: [String: String] = [:]
    public var shortcuts: [UserShortcut] = []
    public var learnedPreferences: [LearnedPreference] = []

    public init() {}

    public var isDefault: Bool { self == PersonalizationProfile() }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, sass, responseLength, useEmoji, customInstructions, aboutMe, favoriteApps, shortcuts, learnedPreferences
    }

    /// Field by field: a missing or malformed field takes its default instead of throwing the profile away.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        schemaVersion = value(.schemaVersion, 1)
        sass = value(.sass, Self.defaultSass)
        responseLength = value(.responseLength, .balanced)
        useEmoji = value(.useEmoji, false)
        customInstructions = value(.customInstructions, "")
        aboutMe = value(.aboutMe, [:])
        favoriteApps = value(.favoriteApps, [:])
        shortcuts = value(.shortcuts, [])
        learnedPreferences = value(.learnedPreferences, [])
    }

    /// The profile with unknown keys dropped, lengths and ranges clamped, and sensitive-looking text removed.
    /// `problems` says what was changed, in words for the user.
    public func sanitized() -> (profile: PersonalizationProfile, problems: [String]) {
        var p = self
        var problems: [String] = []
        p.schemaVersion = Self.currentSchemaVersion
        p.sass = min(max(sass, Self.sassRange.lowerBound), Self.sassRange.upperBound)

        if let reason = SensitiveDataDetector.reason(customInstructions) {
            p.customInstructions = ""
            problems.append("Custom instructions were removed: they looked like \(reason).")
        } else {
            p.customInstructions = String(customInstructions.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxCustomInstructions))
        }

        let allowedAbout = Set(AboutField.allCases.map(\.rawValue))
        p.aboutMe = [:]
        for (key, raw) in aboutMe where allowedAbout.contains(key) {
            let text = Self.singleLine(raw, max: Self.maxAboutValue)
            guard !text.isEmpty else { continue }
            if let reason = SensitiveDataDetector.reason(text) {
                problems.append("\"\(key)\" was removed: it looked like \(reason).")
            } else {
                p.aboutMe[key] = text
            }
        }

        let allowedRoles = Set(AppRole.allCases.map(\.rawValue))
        p.favoriteApps = favoriteApps.filter { allowedRoles.contains($0.key) }
            .compactMapValues { (try? ToolValidation.validateAppName($0)) }

        var seenTriggers = Set<String>()
        p.shortcuts = shortcuts.compactMap { $0.sanitized() }.filter { seenTriggers.insert($0.trigger).inserted }
        p.shortcuts = Array(p.shortcuts.prefix(Self.maxShortcuts))

        p.learnedPreferences = learnedPreferences.compactMap { pref in
            let text = Self.singleLine(pref.text, max: Self.maxPreferenceLength)
            guard !text.isEmpty, SensitiveDataDetector.reason(text) == nil else { return nil }
            return LearnedPreference(id: pref.id, text: text, createdAt: pref.createdAt)
        }
        p.learnedPreferences = Array(p.learnedPreferences.suffix(Self.maxPreferences))
        return (p, problems)
    }

    static func singleLine(_ text: String, max: Int) -> String {
        String(text.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(max))
    }

    /// A typed shortcut ("/standup", optionally followed by more text) becomes its prompt; anything else is
    /// returned unchanged. A shortcut only ever produces a message: it can't approve or skip anything.
    public func expandShortcut(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return message }
        let trigger = trimmed.prefix { !$0.isWhitespace }.lowercased()
        guard let shortcut = shortcuts.first(where: { $0.trigger == trigger }) else { return message }
        let rest = trimmed.dropFirst(trigger.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? shortcut.prompt : shortcut.prompt + "\n\n" + rest
    }
}

/// "/standup" → "Summarise today's calendar and reminders".
public struct UserShortcut: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// Lowercase, starts with "/", letters/digits/hyphens, at most 31 characters.
    public var trigger: String
    public var prompt: String

    public init(id: UUID = UUID(), trigger: String, prompt: String) {
        self.id = id
        self.trigger = trigger
        self.prompt = prompt
    }

    public static func isValidTrigger(_ trigger: String) -> Bool {
        trigger.range(of: #"^/[a-z0-9][a-z0-9-]{0,29}$"#, options: .regularExpression) != nil
    }

    func sanitized() -> UserShortcut? {
        let trigger = trigger.trimmingCharacters(in: .whitespaces).lowercased()
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidTrigger(trigger), !prompt.isEmpty, prompt.count <= PersonalizationProfile.maxShortcutPrompt,
              SensitiveDataDetector.reason(prompt) == nil else { return nil }
        return UserShortcut(id: id, trigger: trigger, prompt: prompt)
    }
}

/// Something the user told Ivy to remember ("prefers metric units"). Each one was approved on a card or typed
/// by the user; all can be reviewed and deleted.
public struct LearnedPreference: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// Refuses text that looks like something Ivy must never keep in personalization: credentials, card numbers,
/// government ID numbers, bank account numbers. Errs on the side of refusing.
public enum SensitiveDataDetector {
    /// What the text looks like (for the message to the user), or nil if it seems fine.
    public static func reason(_ text: String) -> String? {
        if SecretRedactor.redact(text) != text { return "a password, token or API key" }
        if text.range(of: #"(?i)\b(password|passcode|passwd|pin|otp|cvv)\b\s*(?:is|:|=)\s*\S+"#, options: .regularExpression) != nil {
            return "a password or PIN"
        }
        if containsCardNumber(text) { return "a card number" }
        let patterns: [(String, String)] = [
            (#"\b\d{3}-\d{2}-\d{4}\b"#, "a social security number"),
            (#"\b\d{4}\s?\d{4}\s?\d{4}\b"#, "an ID number (e.g. Aadhaar)"),
            (#"\b[A-Z]{5}\d{4}[A-Z]\b"#, "a PAN number"),
            (#"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#, "a bank account number (IBAN)"),
        ]
        for (pattern, label) in patterns where text.range(of: pattern, options: .regularExpression) != nil {
            return label
        }
        return nil
    }

    /// 13–19 digits (spaces/hyphens allowed) passing the Luhn check.
    static func containsCardNumber(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"(?:\d[ -]?){12,18}\d"#) else { return false }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let r = Range(match.range, in: text) else { continue }
            let digits = text[r].compactMap(\.wholeNumberValue)
            if (13...19).contains(digits.count), luhn(digits) { return true }
        }
        return false
    }

    static func luhn(_ digits: [Int]) -> Bool {
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }
}
