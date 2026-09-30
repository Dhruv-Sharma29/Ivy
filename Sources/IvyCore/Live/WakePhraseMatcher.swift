import Foundation

/// Fast, deterministic, normalized wake-phrase matching for Ivy interruptions.
public struct WakePhraseMatcher: Sendable {
    /// How the recognizer renders a spoken "hey". Said over Ivy's own voice, echo suppression clips its onset,
    /// so it often comes back as "a", "AI" or "eh". Other greetings ("hi", "hello") are deliberately excluded:
    /// only "Hey Ivy" interrupts.
    static let heyVariants: Set<String> = ["hey", "hay", "hei", "heh", "eh", "ay", "aye", "a", "ai"]
    /// How the recognizer renders "Ivy" (whole tokens only, so "Ivyberry" never matches).
    static let ivyVariants: Set<String> = ["ivy", "ivey", "ivie", "ivee", "iv", "ivory"]

    public static func isHey(_ token: String) -> Bool { heyVariants.contains(token) }
    public static func isIvy(_ token: String) -> Bool { ivyVariants.contains(token) }

    /// Checks whether the text contains "Hey Ivy" (case-insensitive, punctuation ignored, common mishearings allowed).
    public static func containsWakePhrase(_ text: String) -> Bool {
        let tokens = extractTokens(text)
        guard tokens.count >= 2 else { return false }
        for i in 0..<(tokens.count - 1) where isHey(tokens[i]) {
            if isIvy(tokens[i + 1]) { return true }
            // Spelled-out "I V".
            if tokens[i + 1] == "i", i + 2 < tokens.count, tokens[i + 2] == "v" { return true }
        }
        return false
    }

    /// "Ivy" on its own. Far more prone to false triggers than the full phrase, so callers gate it
    /// (a setting, plus the user audibly speaking).
    public static func containsIvy(_ text: String) -> Bool {
        extractTokens(text).contains(where: isIvy)
    }

    /// Normalizes and tokenizes text by stripping punctuation, lowercasing, and splitting on whitespace.
    public static func extractTokens(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let cleaned = text.lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters)
            .joined(separator: " ")
        return cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
