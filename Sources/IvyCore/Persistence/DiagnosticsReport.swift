import Foundation

/// A plain-text support report the user can export and share. It never contains credentials, conversations,
/// transcripts or audio: only versions, non-secret settings, permission states, where each key comes from,
/// and a redacted tail of Ivy's own log.
public enum DiagnosticsReport {
    /// Where crash/hang diagnostics delivered by the system (MetricKit) are kept locally.
    public static var crashReportsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Ivy/Diagnostics", isDirectory: true)
    }

    public static func build(
        settings: IvySettings,
        credentials: CredentialProvider,
        permissions: PermissionManaging,
        logTail: String?,
        crashReportCount: Int,
        wakeStats: (fired: Int, unanswered: Int)? = nil,
        now: Date = Date()
    ) -> String {
        var lines: [String] = []
        lines.append("Ivy diagnostics")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: now))")
        lines.append("Version: \(IvyVersion.displayVersion)")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Bundle: \(Bundle.main.bundleURL.pathExtension == "app" ? "app bundle" : "unbundled (swift run)")")
        lines.append("")
        lines.append("Settings")
        lines.append("  persistConversationHistory: \(settings.persistConversationHistory)")
        lines.append("  restoreLastConversation: \(settings.restoreLastConversation)")
        lines.append("  echoCancellation: \(settings.echoCancellation)")
        lines.append("  pushToTalkEnabled: \(settings.pushToTalkEnabled)")
        lines.append("  showLiveTranscript: \(settings.showLiveTranscript)")
        lines.append("  wakeWordEnabled: \(settings.wakeWordEnabled)")
        lines.append("  voicePatience: \(settings.voicePatience.rawValue)")
        lines.append("  pauseWakeWordWhenLocked: \(settings.pauseWakeWordWhenLocked)")
        if let wakeStats {
            lines.append("")
            lines.append("\"Hey Ivy\" this launch: fired \(wakeStats.fired), no request heard after \(wakeStats.unanswered) (likely false triggers)")
        }
        lines.append("")
        lines.append("Credentials (source only, never the value)")
        for key in CredentialKey.allCases {
            lines.append("  \(key.displayName): \(describe(credentials.source(for: key)))")
        }
        lines.append("")
        lines.append("Permissions")
        for type in PermissionType.allCases {
            lines.append("  \(type.displayName): \(permissions.status(for: type).rawValue)")
        }
        lines.append("")
        lines.append("Crash/hang reports stored locally: \(crashReportCount)")
        lines.append("")
        lines.append("Recent log (redacted)")
        if let logTail, !logTail.isEmpty {
            lines.append(SecretRedactor.redact(logTail))
        } else {
            lines.append("  (no log file; launch with scripts/run-ivy-app.sh to record one)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The last `maxLines` lines of a log file, or nil if it doesn't exist.
    public static func tail(of url: URL, maxLines: Int = 300) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(maxLines).joined(separator: "\n")
    }

    private static func describe(_ source: CredentialSource) -> String {
        switch source {
        case .keychain: return "Keychain"
        case .environment: return "environment variable"
        case .missing: return "not set"
        case .keychainInaccessible: return "Keychain item inaccessible"
        }
    }
}
