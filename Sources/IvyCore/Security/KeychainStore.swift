import Foundation
import Security

/// The only credentials Ivy stores. Every Keychain/environment identifier lives here, nowhere else.
public enum CredentialKey: String, CaseIterable, Sendable {
    case geminiAPIKey
    case elevenLabsAPIKey

    /// Keychain service shared by all Ivy credentials.
    public static let keychainService = "com.ivy.assistant.credentials"

    /// Keychain account name for this credential.
    public var account: String {
        switch self {
        case .geminiAPIKey: return "gemini-api-key"
        case .elevenLabsAPIKey: return "elevenlabs-api-key"
        }
    }

    /// Development-migration fallback, read only when the Keychain has no value.
    public var environmentVariable: String {
        switch self {
        case .geminiAPIKey: return "GEMINI_API_KEY"
        case .elevenLabsAPIKey: return "ELEVENLABS_API_KEY"
        }
    }

    /// Human-readable name for UI and errors (never the value).
    public var displayName: String {
        switch self {
        case .geminiAPIKey: return "Gemini API key"
        case .elevenLabsAPIKey: return "ElevenLabs API key"
        }
    }
}

/// Keychain failures. Descriptions name the credential and the failure, never the secret.
public enum KeychainError: Error, LocalizedError, Equatable, Sendable {
    case itemNotFound
    case duplicateItem
    case accessDenied
    case invalidData
    case unexpectedStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound: return "The credential is not stored in the Keychain."
        case .duplicateItem: return "The credential already exists in the Keychain."
        case .accessDenied: return "Access to the Keychain was denied."
        case .invalidData: return "The Keychain returned data in an unexpected format."
        case .unexpectedStatus(let status): return "Keychain error (OSStatus \(status))."
        }
    }

    init(status: OSStatus) {
        switch status {
        case errSecItemNotFound: self = .itemNotFound
        case errSecDuplicateItem: self = .duplicateItem
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled, errSecNoAccessForItem: self = .accessDenied
        default: self = .unexpectedStatus(status)
        }
    }
}

/// Stores credentials as opaque `Data`. `save` fails on an existing item; `read`/`update`/`delete` fail on a missing one.
public protocol KeychainStore: Sendable {
    func save(_ data: Data, for key: CredentialKey) throws
    func read(_ key: CredentialKey) throws -> Data
    func update(_ data: Data, for key: CredentialKey) throws
    func delete(_ key: CredentialKey) throws
    func exists(_ key: CredentialKey) -> Bool
}

/// Generic-password items in the user's login Keychain via Security.framework.
public struct SystemKeychainStore: KeychainStore {
    public init() {}

    /// Identity of an item; shared by every query so service/account can't drift between calls.
    static func baseQuery(for key: CredentialKey) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: CredentialKey.keychainService,
            kSecAttrAccount as String: key.account
        ]
    }

    public func save(_ data: Data, for key: CredentialKey) throws {
        var query = Self.baseQuery(for: key)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        query[kSecAttrLabel as String] = "Ivy \(key.displayName)"
        try check(SecItemAdd(query as CFDictionary, nil))
    }

    public func read(_ key: CredentialKey) throws -> Data {
        var query = Self.baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        try check(SecItemCopyMatching(query as CFDictionary, &result))
        guard let data = result as? Data else { throw KeychainError.invalidData }
        return data
    }

    public func update(_ data: Data, for key: CredentialKey) throws {
        let attributes = [kSecValueData as String: data]
        try check(SecItemUpdate(Self.baseQuery(for: key) as CFDictionary, attributes as CFDictionary))
    }

    public func delete(_ key: CredentialKey) throws {
        try check(SecItemDelete(Self.baseQuery(for: key) as CFDictionary))
    }

    public func exists(_ key: CredentialKey) -> Bool {
        var query = Self.baseQuery(for: key)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}
