import Foundation

/// Fast, deterministic, normalized wake-phrase matching for Ivy interruptions.
public struct WakePhraseMatcher: Sendable {
    /// Checks whether the provided text contains the wake phrase "Hey Ivy" (case-insensitive, ignoring punctuation).
    public static func containsWakePhrase(_ text: String) -> Bool {
        let tokens = extractTokens(text)
        guard tokens.count >= 2 else { return false }
        for i in 0..<(tokens.count - 1) {
            if tokens[i] == "hey" && tokens[i + 1] == "ivy" {
                return true
            }
        }
        return false
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
