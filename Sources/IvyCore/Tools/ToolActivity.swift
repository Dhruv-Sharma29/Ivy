import Foundation
import Combine

/// Display-only, bounded records. Arguments and output never enter conversation persistence or model context.
public struct ToolExecution: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case running, succeeded, failed }
    public let id: UUID
    public let name: String
    public let arguments: String
    public let startedAt: Date
    public var status: Status
    public var output: String?
    /// Display-only link to the request that caused this call, including late voice transcripts.
    public var requestMessageID: UUID? = nil

    public static func displayJSON(_ values: [String: AnyCodable], toolName: String? = nil) -> String {
        func maskKeyAndValue(key: String, value: AnyCodable) -> AnyCodable {
            let lower = key.lowercased()
            if toolName == "ui_type" && lower == "text" {
                if let str = value.stringValue {
                    let redacted = SecretRedactor.redact(str)
                    return .string(redacted.contains("[REDACTED") ? redacted : "[redacted: \(str.count) chars]")
                }
                return .string("[redacted text]")
            }
            if lower.contains("imagedata") || lower.contains("screenshot") || lower.contains("axtree") || lower.contains("elements") {
                return .string("[redacted observation payload]")
            }
            switch value {
            case .dictionary(let entries):
                var sanitized: [String: AnyCodable] = [:]
                for (k, v) in entries {
                    sanitized[k] = maskKeyAndValue(key: k, value: v)
                }
                return .dictionary(sanitized.mapWithSensitiveKeys())
            case .array(let items):
                return .array(items.map { maskKeyAndValue(key: key, value: $0) })
            case .string(let text):
                return .string(SecretRedactor.redact(text))
            default:
                return value
            }
        }

        var sanitizedTop: [String: AnyCodable] = [:]
        for (k, v) in values {
            sanitizedTop[k] = maskKeyAndValue(key: k, value: v)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(sanitizedTop.mapWithSensitiveKeys())
            let text = String(decoding: data, as: UTF8.self)
            return text.count > 12_000 ? String(text.prefix(12_000)) + "\n… (truncated)" : text
        } catch {
            return "Details unavailable: \(error.localizedDescription)"
        }
    }
}

private extension Dictionary where Key == String, Value == AnyCodable {
    func mapWithSensitiveKeys() -> Self {
        mapValuesWithKeys { key, value in
            let normalized = key.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
            return ["apikey", "password", "secret", "token", "authorization", "credential"].contains(where: normalized.contains)
                ? .string(SecretRedactor.placeholder) : value
        }
    }
    func mapValuesWithKeys(_ transform: (String, AnyCodable) -> AnyCodable) -> Self {
        Dictionary(uniqueKeysWithValues: map { ($0.key, transform($0.key, $0.value)) })
    }
}

@MainActor
public final class ToolActivity: ObservableObject {
    @Published public private(set) var records: [ToolExecution] = []
    /// Live uses a separate SafetyGate, but forwards display events into the shared chat feed.
    public var destination: ToolActivity?
    public nonisolated init() {}

    public func begin(_ call: FunctionCall, now: Date = Date(), requestMessageID: UUID? = nil) -> UUID {
        if let destination { return destination.begin(call, now: now, requestMessageID: requestMessageID) }
        let record = ToolExecution(id: UUID(), name: call.name, arguments: ToolExecution.displayJSON(call.args, toolName: call.name),
                                   startedAt: now, status: .running, output: nil, requestMessageID: requestMessageID)
        records.append(record)
        if records.count > 100 { records.removeFirst(records.count - 100) }
        return record.id
    }

    public func complete(_ id: UUID, response: FunctionResponse) {
        if let destination { destination.complete(id, response: response); return }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        let toolName = records[index].name
        records[index].status = response.response["success"]?.boolValue == true ? .succeeded : .failed
        records[index].output = ToolExecution.displayJSON(response.response, toolName: toolName)
    }

    public func reset() {
        if let destination { destination.reset() } else { records = [] }
    }
}
