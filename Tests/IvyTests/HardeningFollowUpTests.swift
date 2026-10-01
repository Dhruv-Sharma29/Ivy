import Testing
import Foundation
import os
@testable import IvyCore

// Follow-up fixes found in the post-Phase 12 code review: fail-closed tool default, credential paths,
// queued Live tool calls with server cancellation, and shell processes that can't hang Ivy.

// MARK: - Fail-closed classification

@Suite("Hardening - tools are risky unless they say otherwise")
struct FailClosedClassificationTests {
    private struct UndeclaredTool: IvyTool {
        let name = "undeclared_tool"
        let description = "Forgot to declare a classification"
        let declaration = FunctionDeclaration(name: "undeclared_tool", description: "x")
        func execute(arguments: [String: AnyCodable]) async throws -> ToolResult { .success("ran") }
    }

    @Test("a tool that doesn't declare a classification needs confirmation")
    func undeclaredIsRisky() async {
        let tool = UndeclaredTool()
        #expect(tool.safetyClassification == .risky)
        #expect(SafetyPolicy().classification(for: tool, call: FunctionCall(name: tool.name)) == .risky)

        let asked = OSAllocatedUnfairLock(initialState: 0)
        let dispatcher = ToolDispatcher(
            registry: ToolRegistry(tools: [tool]),
            safetyGate: InteractiveSafetyGate(confirmationProvider: ClosureConfirmationProvider { _ in
                asked.withLock { $0 += 1 }
                return false
            }),
            permissions: MockPermissionManager())
        let response = await dispatcher.dispatch(FunctionCall(name: tool.name, id: "1"))
        #expect(asked.withLock { $0 } == 1)
        #expect(response.isCancelled)
    }

    @Test("the shipped safe tools still declare themselves safe")
    func shippedSafeToolsUnchanged() {
        let registry = ToolRegistry.standardRegistry()
        for name in ["open_app", "notify", "system_settings", "volume_brightness", "finder", "file_search", "media"] {
            #expect(registry.tool(named: name)?.safetyClassification == .safe, "\(name)")
        }
    }
}

// MARK: - Credential and private-data paths

@Suite("Hardening - file_op refuses credential and private-data locations")
struct CredentialPathTests {
    /// A made-up home: validation is path logic only, nothing is read.
    private let home = URL(fileURLWithPath: "/Users/ivy-test-home")

    @Test("credential files, shell history and private app data are refused, even for read")
    func refused() {
        let paths = [
            ".netrc", ".git-credentials", ".npmrc", ".pypirc", ".docker/config.json", ".kube/config",
            ".config/gh/hosts.yml", ".config/gcloud/credentials.db", ".azure/accessTokens.json",
            ".env", "project/.env", "project/.env.local", ".zsh_history", ".bash_history",
            "Library/Cookies/Cookies.binarycookies", "Library/Safari/History.db", "Library/Messages/chat.db",
            "Library/Mail/V10/x.emlx", "Library/Application Support/Google/Chrome/Default/Login Data",
            "Library/Application Support/Firefox/Profiles/x/logins.json",
            "Library/Application Support/Ivy/Conversations/index.json",
        ]
        for path in paths {
            #expect(throws: ToolError.self, "\(path)") {
                try ToolValidation.validateFileOpArguments(["action": "read", "path": .string(path)], allowedRoot: home)
            }
        }
    }

    @Test("ordinary project and document paths still work")
    func allowed() throws {
        for path in ["Documents/notes.txt", "Desktop/Coding/Ivy/README.md", "project/config.yml", "Downloads/report.pdf"] {
            _ = try ToolValidation.validateFileOpArguments(["action": "read", "path": .string(path)], allowedRoot: home)
        }
    }
}

// MARK: - Live: several tool calls in one turn

@MainActor
@Suite("Hardening - Live tool calls in one turn are queued, and server cancellations are honoured")
struct LiveQueuedToolCallTests {
    private func make() -> (GeminiLiveVoiceCoordinator, MockGeminiLiveSession, MockShellExecutor) {
        let session = MockGeminiLiveSession()
        let shell = MockShellExecutor()
        let bridge = ConfirmationBridge()
        let dispatcher = ToolDispatcher(
            registry: ToolRegistry(tools: [RunShellTool(executor: shell)]),
            safetyGate: InteractiveSafetyGate(confirmationProvider: bridge),
            permissions: MockPermissionManager())
        let coordinator = GeminiLiveVoiceCoordinator(
            session: session, audioCapture: MockAudioCapture(), audioPlayer: MockLiveAudioPlayer(),
            wakeWordDetector: MockWakeWordDetector(), toolDispatcher: dispatcher)
        return (coordinator, session, shell)
    }

    private func shell(_ id: String, _ command: String) -> FunctionCall {
        FunctionCall(name: "run_shell", args: ["command": .string(command)], id: id)
    }

    @Test("two risky calls: each gets its own card, in order; the first is not silently denied")
    func eachCallGetsACard() async throws {
        let (coordinator, session, shellExecutor) = make()
        await coordinator.startSession()
        session.simulateToolCall(shell("a", "echo one"))
        session.simulateToolCall(shell("b", "echo two"))

        #expect(await waitUntil { coordinator.pendingConfirmation?.callId == "a" })
        // The second call waits its turn instead of replacing the first card.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(coordinator.pendingConfirmation?.callId == "a")
        #expect(coordinator.state == .toolConfirmation)
        let first = try #require(coordinator.pendingConfirmation)
        coordinator.respondToPendingConfirmation(id: first.id, approved: true)

        #expect(await waitUntil { coordinator.pendingConfirmation?.callId == "b" })
        let second = try #require(coordinator.pendingConfirmation)
        coordinator.respondToPendingConfirmation(id: second.id, approved: true)

        #expect(await waitUntil { session.sentToolResponses.count == 2 })
        #expect(session.sentToolResponses.map(\.id) == ["a", "b"])
        #expect(session.sentToolResponses.allSatisfy { $0.isSuccess })
        #expect(shellExecutor.recordedCommands.map(\.command) == ["echo one", "echo two"])
        await coordinator.stopSession()
    }

    @Test("a server cancellation denies the waiting card and skips a queued call; nothing cancelled runs")
    func serverCancellation() async throws {
        let (coordinator, session, shellExecutor) = make()
        await coordinator.startSession()
        session.simulateToolCall(shell("a", "rm -rf ~/Drafts"))
        session.simulateToolCall(shell("b", "rm -rf ~/Old"))
        #expect(await waitUntil { coordinator.pendingConfirmation?.callId == "a" })

        session.simulateEvent(.toolCallCancelled(["a", "b"]))
        #expect(await waitUntil { coordinator.pendingConfirmation == nil })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(coordinator.pendingConfirmation == nil, "the queued call never shows a card")
        #expect(shellExecutor.recordedCommands.isEmpty)
        #expect(!session.sentToolResponses.contains { $0.id == "b" })
        await coordinator.stopSession()
    }

    @Test("ending the session with calls queued runs none of them")
    func teardownCancelsQueue() async throws {
        let (coordinator, session, shellExecutor) = make()
        await coordinator.startSession()
        session.simulateToolCall(shell("a", "echo one"))
        session.simulateToolCall(shell("b", "echo two"))
        #expect(await waitUntil { coordinator.pendingConfirmation != nil })
        await coordinator.stopSession()
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(coordinator.pendingConfirmation == nil)
        #expect(shellExecutor.recordedCommands.isEmpty)
        #expect(coordinator.activeTaskCount == 0)
    }

    @Test("the client turns the server's toolCallCancellation into an event")
    func clientDecodesCancellation() throws {
        let json = #"{"toolCallCancellation": {"ids": ["a", "b"]}}"#
        let message = try JSONDecoder().decode(BidiServerMessage.self, from: Data(json.utf8))
        #expect(message.toolCallCancellation?.ids == ["a", "b"])
    }
}

// MARK: - Shell processes (real /bin/zsh; short timeouts)

@Suite("Hardening - run_shell can't hang Ivy", .serialized)
struct ShellProcessTests {
    @Test("ordinary output and exit codes")
    func ordinary() async throws {
        let result = try await SystemShellExecutor().execute(command: "echo hello; echo oops >&2; exit 3")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == "oops")
        #expect(result.exitCode == 3)
    }

    @Test("a pipeline past its timeout is killed, children included, and reported as a timeout")
    func timeoutKillsTree() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("ivy-shell-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let started = Date()
        await #expect(throws: ShellError.self) {
            _ = try await SystemShellExecutor(defaultCommandTimeout: 0.5)
                .execute(command: "sh -c 'echo $$ > \(pidFile.path); sleep 30' | cat")
        }
        #expect(Date().timeIntervalSince(started) < 6)
        let childPID = try #require(pid_t(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        // Polled: a killed process can linger briefly as a zombie until it is reaped.
        #expect(await waitUntil { kill(childPID, 0) != 0 }, "the grandchild was killed too")
    }

    @Test("a background child holding the output open doesn't stall the result")
    func backgroundChild() async throws {
        let started = Date()
        let result = try await SystemShellExecutor(defaultCommandTimeout: 10).execute(command: "sleep 3 & echo started")
        #expect(Date().timeIntervalSince(started) < 2.5)
        #expect(result.stdout.contains("started"))
        #expect(result.stdout.contains("background process is still running"))
    }

    @Test("descendants are found through libproc")
    func descendants() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 5 & sleep 5 & wait"]
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        #expect(await waitUntil { SystemShellExecutor.descendants(of: process.processIdentifier).count >= 2 })
        await SystemShellExecutor.terminateTree(rootedAt: process.processIdentifier)
        #expect(await waitUntil { !process.isRunning })
    }
}
