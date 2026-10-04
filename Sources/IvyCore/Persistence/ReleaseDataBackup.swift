import Foundation

/// Runs before any production store loads. Copies only Ivy's durable stores, never caches, captures,
/// diagnostics or Keychain items. A completed backup is immutable; failure leaves the source untouched.
public struct ReleaseDataBackup {
    public static let dataNames = ["Conversations", "Tasks", "Proactive", "profile.json", "workspaces.json"]
    public let directory: URL
    private let defaults: UserDefaults
    private let files: FileManager
    private static let markerName = "release-data-version.json"
    private struct Manifest: Codable {
        let sourceVersion: String
        let targetVersion: String
        let createdAt: Date
        let entries: [String]
    }
    public enum BackupError: LocalizedError {
        case unsafePath, incompleteBackup, unknownVersion, cleanup(String)
        public var errorDescription: String? {
            switch self {
            case .unsafePath: "The backup contains a symbolic link or unsupported file."
            case .incompleteBackup: "The existing 1.0 backup has no valid completion manifest. Preserve it and choose a new backup location before retrying."
            case .unknownVersion: "The data belongs to an unsupported release version."
            case .cleanup(let message): "The backup failed and its staging folder could not be cleaned up: \(message)"
            }
        }
    }

    public init(directory: URL = FileConversationStore.defaultDirectory.deletingLastPathComponent(),
                defaults: UserDefaults = .standard, files: FileManager = .default) {
        self.directory = directory; self.defaults = defaults; self.files = files
    }

    /// Returns the completed rollback folder, or nil on a fresh/current install.
    @discardableResult
    public func prepare() throws -> URL? {
        try rejectLinksInAncestors(directory)
        let marker = directory.appendingPathComponent(Self.markerName)
        try rejectLink(marker)
        if files.fileExists(atPath: marker.path) {
            let version = try JSONDecoder().decode(String.self, from: Data(contentsOf: marker))
            guard version == "1.1.0" else { throw BackupError.unknownVersion }
            return nil
        }
        let root = directory.appendingPathComponent("Backups", isDirectory: true)
        let destination = root.appendingPathComponent("1.0", isDirectory: true)
        try rejectLink(root)
        try rejectLink(destination)
        if files.fileExists(atPath: destination.path) {
            let manifestURL = destination.appendingPathComponent("manifest.json")
            try rejectLink(manifestURL)
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(Manifest.self, from: data)
            guard manifest.sourceVersion == "1.0.0", manifest.targetVersion == "1.1.0",
                  manifest.entries.allSatisfy({ Self.dataNames.contains($0) || $0 == "settings.plist" }) else { throw BackupError.incompleteBackup }
            for entry in manifest.entries {
                let url = destination.appendingPathComponent(entry)
                guard files.fileExists(atPath: url.path) else { throw BackupError.incompleteBackup }
                try validateTree(url)
            }
            try writeMarker(marker)
            return destination
        }
        let sources = try Self.dataNames.filter { name in
            let url = directory.appendingPathComponent(name)
            try rejectLink(url)
            return files.fileExists(atPath: url.path)
        }
        let rawSettings = defaults.object(forKey: UserDefaultsSettingsStore.storageKey)
        guard !sources.isEmpty || rawSettings != nil else {
            try writeMarker(marker)
            return nil
        }
        for name in sources { try validateTree(directory.appendingPathComponent(name)) }
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = root.appendingPathComponent(".1.0-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var entries = sources
            for name in sources {
                let target = staging.appendingPathComponent(name)
                try files.copyItem(at: directory.appendingPathComponent(name), to: target)
                try secureTree(target)
            }
            if let rawSettings {
                let data = try PropertyListSerialization.data(fromPropertyList: [UserDefaultsSettingsStore.storageKey: rawSettings], format: .binary, options: 0)
                try writePrivate(data, to: staging.appendingPathComponent("settings.plist"))
                entries.append("settings.plist")
            }
            let manifest = Manifest(sourceVersion: "1.0.0", targetVersion: "1.1.0", createdAt: Date(), entries: entries)
            try writePrivate(JSONEncoder().encode(manifest), to: staging.appendingPathComponent("manifest.json"))
            try files.moveItem(at: staging, to: destination)
            try writeMarker(marker)
            return destination
        } catch {
            let original = error
            if files.fileExists(atPath: staging.path) {
                do { try files.removeItem(at: staging) }
                catch { throw BackupError.cleanup(error.localizedDescription) }
            }
            throw original
        }
    }

    private func writeMarker(_ url: URL) throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writePrivate(JSONEncoder().encode("1.1.0"), to: url)
    }
    private func writePrivate(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func rejectLink(_ url: URL) throws {
        do {
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw BackupError.unsafePath }
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                    && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError) {
            return // Missing optional stores are expected on a fresh install.
        }
    }
    private func rejectLinksInAncestors(_ url: URL) throws {
        var current = url
        while current.path != "/" {
            if files.fileExists(atPath: current.path) { try rejectLink(current) }
            current.deleteLastPathComponent()
        }
    }
    private func validateTree(_ url: URL) throws {
        try rejectLink(url)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
            for child in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try validateTree(child) }
        } else if values.isRegularFile != true { throw BackupError.unsafePath }
    }
    private func secureTree(_ url: URL) throws {
        let folder = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        try files.setAttributes([.posixPermissions: folder ? 0o700 : 0o600], ofItemAtPath: url.path)
        if folder {
            for child in try files.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) { try secureTree(child) }
        }
    }
}
