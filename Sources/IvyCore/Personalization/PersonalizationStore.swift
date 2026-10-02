import Foundation
import Combine
import os

public enum PersonalizationError: Error, LocalizedError, Equatable, Sendable {
    /// The text looks like something Ivy must not store; the associated value says what.
    case sensitive(String)
    case invalid(String)
    case tooMany(String)
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .sensitive(let what): return "Ivy doesn't store sensitive details, and this looks like \(what)."
        case .invalid(let why): return why
        case .tooMany(let what): return "There are already too many \(what). Remove some first."
        case .unavailable: return "Personalization isn't available right now."
        }
    }
}

public protocol PersonalizationStore: Sendable {
    /// Never throws: missing → default profile; unreadable → set aside (reported via notices) and default.
    func load() -> PersonalizationProfile
    func save(_ profile: PersonalizationProfile) throws
    func drainRecoveryNotices() -> [String]
}

/// `Application Support/Ivy/profile.json`, readable only by the user.
public struct FilePersonalizationStore: PersonalizationStore {
    public let fileURL: URL
    private let notices = NoticeBox()

    public static var defaultURL: URL {
        FileConversationStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("profile.json")
    }

    public init(fileURL: URL = FilePersonalizationStore.defaultURL) {
        self.fileURL = fileURL
    }

    public func load() -> PersonalizationProfile {
        guard let data = FileManager.default.contents(atPath: fileURL.path) else { return PersonalizationProfile() }
        do {
            let profile = try JSONDecoder().decode(PersonalizationProfile.self, from: data)
            guard profile.schemaVersion <= PersonalizationProfile.currentSchemaVersion else {
                throw ConversationStoreError.newerSchema(profile.schemaVersion)
            }
            let (clean, problems) = profile.sanitized()
            problems.forEach(notices.add)
            return clean
        } catch {
            quarantine()
            return PersonalizationProfile()
        }
    }

    public func save(_ profile: PersonalizationProfile) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(profile).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func drainRecoveryNotices() -> [String] {
        notices.drain()
    }

    private func quarantine() {
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        let folder = fileURL.deletingLastPathComponent().appendingPathComponent("Quarantine/\(day)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.moveItem(at: fileURL, to: folder.appendingPathComponent("profile-\(UUID().uuidString).json"))
            notices.add("Your personalization couldn't be read and was set aside in \(folder.path).")
        } catch {
            print("[PROFILE] profile is unreadable and could not be quarantined: \(error.localizedDescription)")
            notices.add("Your personalization couldn't be read.")
        }
    }
}

public final class InMemoryPersonalizationStore: PersonalizationStore, Sendable {
    private let state: OSAllocatedUnfairLock<PersonalizationProfile>

    public init(_ initial: PersonalizationProfile = PersonalizationProfile()) {
        state = OSAllocatedUnfairLock(initialState: initial)
    }

    public func load() -> PersonalizationProfile { state.withLock { $0 } }
    public func save(_ profile: PersonalizationProfile) throws { state.withLock { $0 = profile } }
    public func drainRecoveryNotices() -> [String] { [] }
}

/// The user's profile for the UI. Every change is validated (sensitive text is refused, not stored) and saved.
@MainActor
public final class PersonalizationModel: ObservableObject {
    @Published public private(set) var profile: PersonalizationProfile
    @Published public private(set) var notice: String?

    private let store: PersonalizationStore
    private let now: () -> Date

    public init(store: PersonalizationStore, now: @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
        profile = store.load()
        let notices = store.drainRecoveryNotices()
        notice = notices.isEmpty ? nil : notices.joined(separator: " ")
    }

    /// The prompt the brain and Live use with this profile.
    public var systemPrompt: String {
        SystemPromptBuilder.build(profile: profile, region: .current)
    }

    /// Applies an edit. Text fields that look sensitive are refused with the reason; nothing is saved then.
    public func update(_ edit: (inout PersonalizationProfile) -> Void) throws {
        var next = profile
        edit(&next)
        try Self.refuseSensitive(next)
        let clean = next.sanitized().profile
        try commit(clean)
    }

    public func setSass(_ level: Int) {
        try? update { $0.sass = level }
    }

    public func setResponseLength(_ length: PersonalizationProfile.ResponseLength) {
        try? update { $0.responseLength = length }
    }

    public func setUseEmoji(_ on: Bool) {
        try? update { $0.useEmoji = on }
    }

    /// Adds a remembered preference (from the confirmed tool, or typed in settings).
    @discardableResult
    public func remember(_ text: String) throws -> LearnedPreference {
        let clean = PersonalizationProfile.singleLine(text, max: PersonalizationProfile.maxPreferenceLength + 1)
        guard !clean.isEmpty else { throw PersonalizationError.invalid("There's nothing to remember.") }
        guard clean.count <= PersonalizationProfile.maxPreferenceLength else {
            throw PersonalizationError.invalid("Keep it under \(PersonalizationProfile.maxPreferenceLength) characters.")
        }
        if let reason = SensitiveDataDetector.reason(clean) { throw PersonalizationError.sensitive(reason) }
        guard profile.learnedPreferences.count < PersonalizationProfile.maxPreferences else {
            throw PersonalizationError.tooMany("remembered preferences")
        }
        if let existing = profile.learnedPreferences.first(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) {
            return existing
        }
        let preference = LearnedPreference(text: clean, createdAt: now())
        try update { $0.learnedPreferences.append(preference) }
        return preference
    }

    public func forget(_ id: UUID) {
        try? update { $0.learnedPreferences.removeAll { $0.id == id } }
    }

    public func forgetEverything() {
        try? update { $0.learnedPreferences = [] }
    }

    public func addShortcut(trigger: String, prompt: String) throws {
        let normalized = trigger.trimmingCharacters(in: .whitespaces).lowercased()
        let withSlash = normalized.hasPrefix("/") ? normalized : "/" + normalized
        guard UserShortcut.isValidTrigger(withSlash) else {
            throw PersonalizationError.invalid("A shortcut is a slash and a short word, like /standup (letters, digits, hyphens).")
        }
        guard !profile.shortcuts.contains(where: { $0.trigger == withSlash }) else {
            throw PersonalizationError.invalid("\(withSlash) already exists.")
        }
        guard profile.shortcuts.count < PersonalizationProfile.maxShortcuts else { throw PersonalizationError.tooMany("shortcuts") }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= PersonalizationProfile.maxShortcutPrompt else {
            throw PersonalizationError.invalid("The prompt must be 1–\(PersonalizationProfile.maxShortcutPrompt) characters.")
        }
        try update { $0.shortcuts.append(UserShortcut(trigger: withSlash, prompt: text)) }
    }

    public func removeShortcut(_ id: UUID) {
        try? update { $0.shortcuts.removeAll { $0.id == id } }
    }

    public func reset() {
        try? commit(PersonalizationProfile())
    }

    public func dismissNotice() {
        notice = nil
    }

    // MARK: - Import / export

    /// JSON of the profile. Remembered preferences only when asked for.
    public func exportData(includingPreferences: Bool) throws -> Data {
        var copy = profile
        if !includingPreferences { copy.learnedPreferences = [] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(copy)
    }

    /// Replaces the profile with an imported one, validated exactly like a loaded file. Returns what was dropped.
    @discardableResult
    public func importData(_ data: Data) throws -> [String] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let imported: PersonalizationProfile
        do {
            imported = try decoder.decode(PersonalizationProfile.self, from: data)
        } catch {
            throw PersonalizationError.invalid("That file isn't an Ivy personalization export.")
        }
        guard imported.schemaVersion <= PersonalizationProfile.currentSchemaVersion else {
            throw PersonalizationError.invalid("That export comes from a newer version of Ivy.")
        }
        let (clean, problems) = imported.sanitized()
        try commit(clean)
        return problems
    }

    // MARK: - Private

    private static func refuseSensitive(_ p: PersonalizationProfile) throws {
        if let reason = SensitiveDataDetector.reason(p.customInstructions) { throw PersonalizationError.sensitive(reason) }
        for value in p.aboutMe.values {
            if let reason = SensitiveDataDetector.reason(value) { throw PersonalizationError.sensitive(reason) }
        }
        for shortcut in p.shortcuts {
            if let reason = SensitiveDataDetector.reason(shortcut.prompt) { throw PersonalizationError.sensitive(reason) }
        }
    }

    private func commit(_ next: PersonalizationProfile) throws {
        guard next != profile else { return }
        do {
            try store.save(next)
        } catch {
            notice = "Your personalization couldn't be saved: \(error.localizedDescription)"
            throw error
        }
        profile = next
    }
}

// MARK: - remember_preference plumbing

/// How the `remember_preference` tool reaches the profile (built before the model exists).
public protocol PreferenceMemory: Sendable {
    func remember(_ text: String) async throws -> String
}

public final class PersonalizationRelay: PreferenceMemory, Sendable {
    @MainActor public weak var model: PersonalizationModel?

    public init() {}

    public func remember(_ text: String) async throws -> String {
        guard let model = await model else { throw PersonalizationError.unavailable }
        return try await model.remember(text).text
    }
}
