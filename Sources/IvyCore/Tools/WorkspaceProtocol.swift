import Foundation
import AppKit

/// Abstraction for interacting with macOS application workspace.
/// Enables mock-based unit testing without launching actual desktop applications.
public protocol WorkspaceProtocol: Sendable {
    /// Locates the application bundle URL for a given application name or bundle ID.
    func findApplicationURL(named name: String) -> URL?

    /// Opens the application at the specified URL.
    func openApplication(at url: URL) async throws
}

/// Production implementation of WorkspaceProtocol using NSWorkspace and standard directories.
public final class SystemWorkspace: WorkspaceProtocol, Sendable {
    private let searchDirectories: [String]

    public init(searchDirectories: [String]? = nil) {
        if let searchDirectories {
            self.searchDirectories = searchDirectories
        } else {
            let homeApps = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications").path
            self.searchDirectories = [
                "/Applications",
                "/System/Applications",
                "/System/Applications/Utilities",
                homeApps
            ]
        }
    }

    public func findApplicationURL(named name: String) -> URL? {
        let fm = FileManager.default
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = trimmed.lowercased().hasSuffix(".app") ? String(trimmed.dropLast(4)) : trimmed
        // Exact names take precedence. Known aliases never use fuzzy/substring matching,
        // which could launch an unrelated app (or the Insiders edition by mistake).
        var names = [baseName]
        let aliasKey = baseName.lowercased().filter { !$0.isWhitespace }
        switch aliasKey {
        case "vscode": names.append("Visual Studio Code")
        case "vscodeinsiders", "vscode-insiders": names.append("Visual Studio Code - Insiders")
        default: break
        }

        for candidate in names {
            let target = "\(candidate).app"
            for dir in searchDirectories {
                let directPath = (dir as NSString).appendingPathComponent(target)
                if fm.fileExists(atPath: directPath) {
                    return URL(fileURLWithPath: directPath)
                }

                // Case-insensitive fallback
                if let contents = try? fm.contentsOfDirectory(atPath: dir) {
                    for item in contents where item.localizedCaseInsensitiveCompare(target) == .orderedSame {
                        return URL(fileURLWithPath: (dir as NSString).appendingPathComponent(item))
                    }
                }
            }
        }

        return nil
    }

    public func openApplication(at url: URL) async throws {
        try await MainActorLauncher.open(url: url)
    }
}

// MARK: - MainActor Helpers

@MainActor
private enum MainActorLauncher {
    static func open(url: URL) async throws {
        _ = try await NSWorkspace.shared.openApplication(
            at: url,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
