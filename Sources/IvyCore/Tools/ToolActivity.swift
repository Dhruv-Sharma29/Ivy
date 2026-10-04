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

    public static func displayJSON(_ values: [String: AnyCodable]) -> String {
        func mask(_ value: AnyCodable) -> AnyCodable {
            switch value {
            case .dictionary(let entries):
                return .dictionary(entries.mapValues(mask).mapWithSensitiveKeys())
            case .array(let values): return .array(values.map(mask))
            case .string(let text): return .string(SecretRedactor.redact(text))
            default: return value
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(mask(.dictionary(values)))
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

    public func begin(_ call: FunctionCall, now: Date = Date()) -> UUID {
        if let destination { return destination.begin(call, now: now) }
        let record = ToolExecution(id: UUID(), name: call.name, arguments: ToolExecution.displayJSON(call.args),
                                   startedAt: now, status: .running, output: nil)
        records.append(record)
        if records.count > 100 { records.removeFirst(records.count - 100) }
        return record.id
    }

    public func complete(_ id: UUID, response: FunctionResponse) {
        if let destination { destination.complete(id, response: response); return }
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].status = response.response["success"]?.boolValue == true ? .succeeded : .failed
        records[index].output = ToolExecution.displayJSON(response.response)
    }

    public func reset() {
        if let destination { destination.reset() } else { records = [] }
    }
}
