import Foundation
import Testing
@testable import IvyCore

private struct EvaluationSet: Decodable {
    let version: String
    let fixtures: [EvaluationFixture]
}

private struct EvaluationFixture: Decodable {
    let id: String
    let request: String
    let scenario: String
    let approve: Bool
    let call: FunctionCall
    let expectedEffects: [String]
    let expectedRefusals: Int
    let expectedFailures: Int
    let expectedOutput: String
}

/// In-memory OS drivers only. The real tools, dispatcher and InteractiveSafetyGate remain in the path.
private actor EvaluationDrivers: WorkspaceProtocol, FinderControlling, FileExecutorProtocol {
    nonisolated let root = "/Users/ivy-fixture/Documents/TaskEvaluation"
    private(set) var effects: [String] = []
    private(set) var files: [String: String] = [:]

    nonisolated func findApplicationURL(named name: String) -> URL? {
        name == "Missing App" ? nil : URL(fileURLWithPath: root + "/" + name + ".app")
    }
    func openApplication(at url: URL) { effects.append("open:" + url.deletingPathExtension().lastPathComponent) }
    func reveal(path: String) { effects.append("reveal:" + path) }
    func openFolder(path: String) { effects.append("folder:" + path) }
    func selection() -> [String] {
        effects.append("finder:selection")
        return [root + "/Project"]
    }
    func readFile(at path: String) throws -> FileOpResult {
        guard let content = files[path] else { throw FileOpError.fileNotFound(path) }
        effects.append("read:" + path)
        return FileOpResult(action: .read, path: path, content: content, bytesAffected: content.utf8.count, message: content)
    }
    func writeFile(at path: String, content: String) -> FileOpResult {
        files[path] = content
        effects.append("write:" + path + ":" + content)
        return FileOpResult(action: .write, path: path, bytesAffected: content.utf8.count, message: "Written")
    }
    func deleteFile(at path: String) throws -> FileOpResult {
        guard let content = files.removeValue(forKey: path) else { throw FileOpError.fileNotFound(path) }
        effects.append("delete:" + path)
        return FileOpResult(action: .delete, path: path, bytesAffected: content.utf8.count, message: "Deleted")
    }
}

private actor EvaluationConfirmation: ConfirmationProvider {
    let approve: Bool
    private(set) var requests = 0
    init(approve: Bool) { self.approve = approve }
    func requestConfirmation(for request: ConfirmationRequest) -> Bool {
        requests += 1
        return approve
    }
}

private struct EvaluationObservation: Codable {
    let fixtureID: String
    let passed: Bool
    let completed: Bool
    let wrongActionAttempts: Int
    let unexpectedEffects: Int
    let refusals: Int
    let failures: Int
    let modelCalls: Int
    let elapsedMilliseconds: Double
}

private struct EvaluationReport: Codable {
    let schemaVersion: String
    let fixtureVersion: String
    let mode: String
    let provider: ModelProviderDescriptor
    let results: [EvaluationObservation]
    var passed: Int { results.filter(\.passed).count }
}

@Suite("Phase 21 offline task evaluations")
struct Phase21TaskEvaluationTests {
    private func fixtures() throws -> EvaluationSet {
        let url = try #require(Bundle.module.url(forResource: "TaskEvaluations-v1", withExtension: "json"))
        let set = try JSONDecoder().decode(EvaluationSet.self, from: Data(contentsOf: url))
        #expect(Set(set.fixtures.map(\.id)).count == set.fixtures.count)
        #expect(set.fixtures.allSatisfy { ["normal", "cancel"].contains($0.scenario) })
        return set
    }

    @MainActor private func evaluate(_ fixture: EvaluationFixture, emittedCall: FunctionCall? = nil,
                                     skipAction: Bool = false) async -> EvaluationObservation {
        let drivers = EvaluationDrivers()
        let confirmation = EvaluationConfirmation(approve: fixture.approve)
        let root = URL(fileURLWithPath: drivers.root)
        let registry = ToolRegistry(tools: [OpenAppTool(workspace: drivers), FinderTool(finder: drivers, allowedRoot: root),
                                            FileOpTool(executor: drivers, allowedRoot: root)])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: InteractiveSafetyGate(confirmationProvider: confirmation))
        let call = emittedCall ?? fixture.call
        let provider = Phase21Provider(skipAction ? [ModelTurnResponse(text: "Done")]
            : [ModelTurnResponse(functionCalls: [call]), ModelTurnResponse(text: "Fixture response")])
        let brain = IvyBrain(modelProvider: provider, toolDispatcher: dispatcher, credentials: FixedCredentialProvider([:]))
        let clock = ContinuousClock()
        let start = clock.now
        if fixture.scenario == "cancel" {
            let turn = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                await brain.send(fixture.request)
            }
            await turn.value
        } else {
            await brain.send(fixture.request)
        }
        await brain.waitForMaintenance()
        let elapsed = start.duration(to: clock.now).components
        let effects = await drivers.effects
        let calls = await provider.emittedCalls
        let requests = await provider.requests
        let responses = requests.last?.history.compactMap(\.functionResponse) ?? []
        let refusals = responses.filter { $0.response["rejected"]?.boolValue == true }.count
        let failures = dispatcher.activity.records.filter { $0.status == .failed }.count
        let wrong = calls.filter { $0.name != fixture.call.name || $0.args != fixture.call.args }.count
        let unexpected = effects.filter { !fixture.expectedEffects.contains($0) }.count
        let output = dispatcher.activity.records.compactMap(\.output).joined(separator: "\n")
        let metExpectation = effects == fixture.expectedEffects && failures == fixture.expectedFailures
            && refusals == fixture.expectedRefusals
            && (fixture.expectedOutput.isEmpty || output.contains(fixture.expectedOutput)) && brain.errorMessage == nil
            && (fixture.scenario != "cancel" || (calls.isEmpty && requests.isEmpty && brain.messages.count == 1))
        if fixture.id == "draft-document", metExpectation {
            #expect(await drivers.files[drivers.root + "/draft.txt"] == "Hello from Ivy")
            #expect(await confirmation.requests == 1)
        }
        if !fixture.approve { #expect(await drivers.files.isEmpty) }
        let completed = metExpectation && fixture.expectedFailures == 0 && fixture.scenario == "normal"
            && !fixture.expectedEffects.isEmpty
        return EvaluationObservation(fixtureID: fixture.id, passed: metExpectation && wrong == 0 && unexpected == 0,
                                     completed: completed, wrongActionAttempts: wrong, unexpectedEffects: unexpected,
                                     refusals: refusals, failures: failures, modelCalls: requests.count,
                                     elapsedMilliseconds: Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1e15)
    }

    @Test("Versioned fixtures run through production validation and approval; optional report is synthetic only")
    @MainActor func baseline() async throws {
        let set = try fixtures()
        var results: [EvaluationObservation] = []
        for fixture in set.fixtures {
            let result = await evaluate(fixture)
            #expect(result.passed, "Fixture: \(fixture.id)")
            results.append(result)
        }
        let report = EvaluationReport(schemaVersion: "1.0.0", fixtureVersion: set.version,
                                      mode: "offline-scripted", provider: Phase21Provider([]).descriptor, results: results)
        #expect(report.passed == 8)
        #expect(results.filter(\.completed).count == 3)
        #expect(results.reduce(0) { $0 + $1.refusals } == 1)
        if let path = ProcessInfo.processInfo.environment["IVY_EVALUATION_REPORT_PATH"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(report)
            // Round-trip the report before writing; no conversation, credentials, audio or image payloads.
            #expect(try JSONDecoder().decode(EvaluationReport.self, from: data).passed == 8)
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }

    @Test("Evaluator detects wrong app, incorrect draft contents and false completion claims")
    @MainActor func detectsRegressions() async throws {
        let set = try fixtures()
        let open = try #require(set.fixtures.first { $0.id == "open-vscode" })
        let wrong = await evaluate(open, emittedCall: FunctionCall(name: "open_app", args: ["name": "Safari"]))
        #expect(!wrong.passed && wrong.wrongActionAttempts == 1 && wrong.unexpectedEffects == 1)
        #expect(!(await evaluate(open, skipAction: true)).passed)
        let draft = try #require(set.fixtures.first { $0.id == "draft-document" })
        var args = draft.call.args
        args["content"] = "Wrong draft"
        let wrongDraft = await evaluate(draft, emittedCall: FunctionCall(name: "file_op", args: args))
        #expect(!wrongDraft.passed && wrongDraft.wrongActionAttempts == 1)
        let rejected = try #require(set.fixtures.first { $0.id == "declined-write" })
        #expect(!(await evaluate(rejected, skipAction: true)).passed)
    }
}
