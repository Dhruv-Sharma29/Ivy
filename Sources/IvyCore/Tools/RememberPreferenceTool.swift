import Foundation

/// Lets Ivy propose remembering a preference the user stated ("I prefer metric"). Risky: the card shows exactly
/// what will be kept, and nothing is stored without the user's approval. Sensitive-looking text is refused
/// before any card appears. Everything remembered is listed (and deletable) in Settings › Personalization.
public final class RememberPreferenceTool: IvyTool, Sendable {
    public let name = "remember_preference"
    public let description = "Proposes remembering a lasting preference the user just stated about how they like things (units, tone, tools, formats), e.g. 'prefers metric units'. Only for preferences, never personal data such as addresses, ID numbers, passwords or health details. The user must approve it."
    public let safetyClassification = ToolSafetyClassification.risky
    public var declaration: FunctionDeclaration {
        FunctionDeclaration(name: name, description: description, parameters: ToolParameters(
            properties: [
                "preference": ToolProperty(type: "STRING", description: "A short phrase, at most \(PersonalizationProfile.maxPreferenceLength) characters, e.g. 'prefers code first, explanation after'."),
            ],
            required: ["preference"]))
    }

    private let memory: PreferenceMemory

    public init(memory: PreferenceMemory) {
        self.memory = memory
    }

    private func parse(_ arguments: [String: AnyCodable]) throws -> String {
        let args = ToolArguments(arguments)
        try args.allow(["preference"])
        let text = try args.string("preference", max: PersonalizationProfile.maxPreferenceLength)
        if let reason = SensitiveDataDetector.reason(text) {
            throw ToolError.invalidArgument("Not stored: this looks like \(reason). Ivy only remembers preferences, never sensitive details.")
        }
        return text
    }

    public func validate(arguments: [String: AnyCodable]) throws { _ = try parse(arguments) }

    public func confirmation(for arguments: [String: AnyCodable]) -> ToolConfirmation? {
        guard let text = try? parse(arguments) else { return nil }
        return ToolConfirmation(
            title: "Remember Preference",
            prompt: "You want me to remember this about you? Fine. I'll pretend I care. Do it or chicken out?",
            detail: "Action: Remember a preference (used in every conversation)\nPreference: \(text)\nYou can delete it any time in Settings › Personalization.")
    }

    public func execute(arguments: [String: AnyCodable]) async throws -> ToolResult {
        let text = try parse(arguments)
        do {
            let stored = try await memory.remember(text)
            return .success("Remembered: \(stored)", summary: "remembered a preference")
        } catch {
            return .failure(error.localizedDescription)
        }
    }
}
