import Foundation

/// Fast, deterministic, normalized wake-phrase matching for Ivy interruptions.
public struct WakePhraseMatcher: Sendable {
    /// Checks whether the provided text contains the wake phrase "Hey Ivy" (case-insensitive, ignoring punctuation).
    public static func containsWakePhrase(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }

        // Strip punctuation and normalize case
        let cleaned = text.lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters)
            .joined(separator: " ")

        let tokens = cleaned.split(whereSeparator: \.isWhitespace).map(String.init)

        // Find consecutive "hey" followed by "ivy"
        guard tokens.count >= 2 else { return false }
        for i in 0..<(tokens.count - 1) {
            if tokens[i] == "hey" && tokens[i + 1] == "ivy" {
                return true
            }
        }
        return false
    }
}
