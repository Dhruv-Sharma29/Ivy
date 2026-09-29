import Foundation
import AppKit

/// Abstraction for executing AppleScript payloads.
/// Allows mock-based unit testing without executing actual scripts on macOS.
public protocol AppleScriptExecutorProtocol: Sendable {
    /// Executes the provided AppleScript and returns its output or result description.
    func execute(script: String) async throws -> String
}

/// Production implementation of AppleScriptExecutorProtocol using NSAppleScript.
public final class SystemAppleScriptExecutor: AppleScriptExecutorProtocol, Sendable {
    public init() {}

    public func execute(script: String) async throws -> String {
        try await MainActorAppleScriptLauncher.execute(source: script)
    }
}

// MARK: - MainActor Helpers

@MainActor
private enum MainActorAppleScriptLauncher {
    static func execute(source: String) throws -> String {
        var errorDict: NSDictionary?
        guard let appleScript = NSAppleScript(source: source) else {
            throw ToolError.executionFailed("Failed to parse AppleScript source.")
        }
        let descriptor = appleScript.executeAndReturnError(&errorDict)
        if let error = errorDict {
            let message = error[NSAppleScript.errorMessage] as? String
                ?? error["NSAppleScriptErrorMessage"] as? String
                ?? "AppleScript execution error"
            let number = error[NSAppleScript.errorNumber] as? Int
            if let number {
                if number == -1743 {
                    throw ToolError.executionFailed("Automation permission denied (Error -1743). Please grant Ivy permission to automate target applications in macOS System Settings > Privacy & Security > Automation.")
                }
                throw ToolError.executionFailed("Error \(number): \(message)")
            } else {
                throw ToolError.executionFailed(message)
            }
        }
        if let stringValue = descriptor.stringValue {
            return stringValue
        }
        let desc = descriptor.description
        if !desc.isEmpty && desc != "<NSAppleEventDescriptor: null()>" {
            return desc
        }
        return "Script executed successfully with no return value."
    }
}
