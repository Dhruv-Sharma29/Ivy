import Foundation

/// Where a credential currently comes from (for UI status; never the value itself).
public enum CredentialSource: Equatable, Sendable {
    case keychain
    case environment
    case missing
    /// A key is stored but the Keychain refused to hand it over (access denied, locked, damaged item).
    /// Saving the key again replaces the item and restores access.
    case keychainInaccessible

    /// Whether a usable key is available right now.
    public var isUsable: Bool { self == .keychain || self == .environment }
}

/// Clients ask for credentials through this; none of them touch Security.framework.
public protocol CredentialProvider: Sendable {
    /// The trimmed, non-empty credential, or nil when unconfigured.
    func credential(for key: CredentialKey) -> String?
    func source(for key: CredentialKey) -> CredentialSource
    /// Saves (or replaces) the credential in the Keychain. Empty values are rejected.
    func store(_ value: String, for key: CredentialKey) throws
    /// Removes the Keychain copy. The environment fallback, if any, is left alone.
    func remove(_ key: CredentialKey) throws
}

/// Keychain first; during migration, falls back to the process environment when the Keychain is empty.
/// Environment values are never copied into the Keychain implicitly — only `store(_:for:)` writes.
public struct KeychainCredentialProvider: CredentialProvider {
    private let keychain: KeychainStore
    private let environment: [String: String]

    public init(keychain: KeychainStore = SystemKeychainStore(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.keychain = keychain
        self.environment = environment
    }

    public func credential(for key: CredentialKey) -> String? {
        keychainValue(for: key) ?? environmentValue(for: key)
    }

    public func source(for key: CredentialKey) -> CredentialSource {
        var keychainFailed = false
        do {
            if Self.normalized(String(data: try keychain.read(key), encoding: .utf8)) != nil { return .keychain }
        } catch KeychainError.itemNotFound {
            keychainFailed = false
        } catch {
            keychainFailed = true
        }
        if environmentValue(for: key) != nil { return .environment }
        return keychainFailed ? .keychainInaccessible : .missing
    }

    public func store(_ value: String, for key: CredentialKey) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw KeychainError.invalidData }
        let data = Data(trimmed.utf8)
        do {
            if keychain.exists(key) {
                try keychain.update(data, for: key)
            } else {
                try keychain.save(data, for: key)
            }
        } catch KeychainError.itemNotFound, KeychainError.duplicateItem, KeychainError.accessDenied, KeychainError.invalidData {
            // The existing item is unusable (stale ACL after re-signing, damaged, or racing): replace it outright.
            do {
                try keychain.delete(key)
            } catch KeychainError.itemNotFound {
                // nothing to remove; fall through to a clean save
            }
            try keychain.save(data, for: key)
        }
    }

    public func remove(_ key: CredentialKey) throws {
        do {
            try keychain.delete(key)
        } catch KeychainError.itemNotFound {
            return // already absent: removal is idempotent
        }
    }

    private func keychainValue(for key: CredentialKey) -> String? {
        do {
            return Self.normalized(String(data: try keychain.read(key), encoding: .utf8))
        } catch KeychainError.itemNotFound {
            return nil
        } catch {
            // Logged by kind only: the error type carries no secret material.
            print("[CREDENTIALS] \(key.displayName) Keychain read failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func environmentValue(for key: CredentialKey) -> String? {
        Self.normalized(environment[key.environmentVariable])
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Explicitly injected credentials (e.g. a key passed to an initializer). Read-only.
public struct FixedCredentialProvider: CredentialProvider {
    private let values: [CredentialKey: String]

    public init(_ values: [CredentialKey: String]) {
        self.values = values
    }

    public func credential(for key: CredentialKey) -> String? {
        guard let trimmed = values[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    public func source(for key: CredentialKey) -> CredentialSource {
        credential(for: key) == nil ? .missing : .environment
    }

    public func store(_ value: String, for key: CredentialKey) throws {
        throw KeychainError.accessDenied
    }

    public func remove(_ key: CredentialKey) throws {
        throw KeychainError.accessDenied
    }
}

/// Bridges the credential provider into the ElevenLabs synthesizer's key lookup.
public struct CredentialElevenLabsKeyProvider: ElevenLabsKeyProvider {
    private let credentials: CredentialProvider

    public init(credentials: CredentialProvider) {
        self.credentials = credentials
    }

    public func getAPIKey() -> String? {
        credentials.credential(for: .elevenLabsAPIKey)
    }
}
