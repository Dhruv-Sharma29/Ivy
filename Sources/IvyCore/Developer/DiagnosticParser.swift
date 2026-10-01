import Foundation

/// One problem found in build/test output.
public struct Diagnostic: Equatable, Sendable {
    public enum Severity: String, Sendable {
        case error, warning, note, failure
    }

    public let file: String?
    public let line: Int?
    public let column: Int?
    public let severity: Severity
    public let message: String

    public init(file: String?, line: Int?, column: Int? = nil, severity: Severity, message: String) {
        self.file = file
        self.line = line
        self.column = column
        self.severity = severity
        self.message = message
    }

    /// "Sources/App/Main.swift:12:5: error: cannot find 'x' in scope"
    public var summary: String {
        var location = file ?? ""
        if let line { location += ":\(line)" }
        if let column { location += ":\(column)" }
        return (location.isEmpty ? "" : location + ": ") + "\(severity.rawValue): \(message)"
    }
}

/// Recognises the common formats: Swift/clang/gcc/Go (`file:line:col: error: …`), Swift Testing, XCTest,
/// TypeScript (`file(line,col): error TS…`), cargo (`error[E…]: …` + ` --> file:line:col`), pytest.
public enum DiagnosticParser {
    public static let maxDiagnostics = 100

    public static func parse(_ output: String) -> [Diagnostic] {
        var found: [Diagnostic] = []
        var seen = Set<String>()
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var pendingCargo: (Diagnostic.Severity, String)?

        func add(_ diagnostic: Diagnostic) {
            guard found.count < maxDiagnostics, seen.insert(diagnostic.summary).inserted else { return }
            found.append(diagnostic)
        }

        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            // cargo: the message comes first, the location on a following " --> " line.
            if let match = line.firstMatch(of: /^(error|warning)(?:\[[A-Z0-9]+\])?: (.+)$/), !line.contains(" --> ") {
                pendingCargo = (match.1 == "error" ? .error : .warning, String(match.2))
                continue
            }
            if let pending = pendingCargo, let match = line.firstMatch(of: /^--> (.+?):(\d+):(\d+)$/) {
                add(Diagnostic(file: String(match.1), line: Int(match.2), column: Int(match.3), severity: pending.0, message: pending.1))
                pendingCargo = nil
                continue
            }

            // Swift Testing: ✘ Test foo() recorded an issue at File.swift:12:5: Expectation failed: …
            if let match = line.firstMatch(of: /recorded an issue at (.+?):(\d+):(\d+): (.+)$/) {
                add(Diagnostic(file: String(match.1), line: Int(match.2), column: Int(match.3), severity: .failure, message: String(match.4)))
                continue
            }

            // TypeScript: src/a.ts(12,5): error TS2304: Cannot find name 'x'.
            if let match = line.firstMatch(of: /^(.+?)\((\d+),(\d+)\): (error|warning) (TS\d+: .+)$/) {
                add(Diagnostic(file: String(match.1), line: Int(match.2), column: Int(match.3),
                               severity: match.4 == "error" ? .error : .warning, message: String(match.5)))
                continue
            }

            // Swift / clang / gcc / Go vet / XCTest: path:line[:col]: error|warning|note: message
            if let match = line.firstMatch(of: /^(.+?):(\d+):(?:(\d+):)? (error|warning|note|fatal error): (.+)$/) {
                let severity: Diagnostic.Severity
                switch match.4 {
                case "warning": severity = .warning
                case "note": severity = .note
                default: severity = .error
                }
                add(Diagnostic(file: String(match.1), line: Int(match.2), column: match.3.flatMap { Int($0) }, severity: severity, message: String(match.5)))
                continue
            }

            // pytest summary: FAILED tests/test_x.py::test_name - AssertionError: …
            if let match = line.firstMatch(of: /^FAILED (.+?)::(\S+)(?: - (.+))?$/) {
                add(Diagnostic(file: String(match.1), line: nil, severity: .failure,
                               message: "\(match.2)" + (match.3.map { ": \($0)" } ?? "")))
                continue
            }
            // pytest traceback location: tests/test_x.py:12: AssertionError
            if let match = line.firstMatch(of: /^(.+?\.py):(\d+): (\w+(?:Error|Exception)\b.*)$/) {
                add(Diagnostic(file: String(match.1), line: Int(match.2), severity: .failure, message: String(match.3)))
                continue
            }
        }
        return found
    }
}
