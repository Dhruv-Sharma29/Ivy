import Foundation
import MetricKit
import IvyCore

/// Keeps the crash/hang diagnostics macOS delivers (MetricKit) on this Mac, so they can be included in an
/// exported diagnostics report. Nothing is uploaded.
/// Stateless (no stored properties), so sharing one instance across threads is safe.
final class CrashDiagnosticsCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashDiagnosticsCollector()
    private static let maxStoredReports = 5

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let directory = DiagnosticsReport.crashReportsDirectory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for payload in payloads {
                let url = directory.appendingPathComponent("diagnostic-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
                try payload.jsonRepresentation().write(to: url, options: .atomic)
            }
            // Keep only the most recent few.
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
            for stale in files.dropFirst(Self.maxStoredReports) {
                try FileManager.default.removeItem(at: stale)
            }
        } catch {
            print("[DIAGNOSTICS] could not store crash diagnostics: \(error.localizedDescription)")
        }
    }

    static var storedReportCount: Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: DiagnosticsReport.crashReportsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.count
    }
}
