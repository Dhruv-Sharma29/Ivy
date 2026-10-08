import Testing
import Foundation
import os
@testable import IvyCore

@Suite("Phase 4D - Voice + Tool Calling Integration Tests")
@MainActor
struct Phase4DVoiceToolCallingTests {

    // MARK: - Helper Setup

    private static let testSandboxURL = URL(fileURLWithPath: "/Users/testuser/Sandbox")

    private func createTestCoordinator(
        session: MockGeminiLiveSession = MockGeminiLiveSession(),
        capture: MockAudioCapture = MockAudioCapture(isPermissionGranted: true),
        player: MockLiveAudioPlayer = MockLiveAudioPlayer(autoDrain: false),
        detector: MockWakeWordDetector = MockWakeWordDetector(),
        hotkey: MockGlobalHotkeyManager = MockGlobalHotkeyManager(),
        workspace: MockWorkspace = MockWorkspace(),
        shellExecutor: MockShellExecutor = MockShellExecutor(),
        appleScriptExecutor: MockAppleScriptExecutor = MockAppleScriptExecutor(),
        calendarExecutor: MockCalendarExecutor = MockCalendarExecutor(),
        fileExecutor: MockFileExecutor = MockFileExecutor()
    ) -> (
        coordinator: GeminiLiveVoiceCoordinator,
        session: MockGeminiLiveSession,
        capture: MockAudioCapture,
        player: MockLiveAudioPlayer,
        detector: MockWakeWordDetector,
        hotkey: MockGlobalHotkeyManager,
        workspace: MockWorkspace,
        shellExecutor: MockShellExecutor,
        appleScriptExecutor: MockAppleScriptExecutor,
        calendarExecutor: MockCalendarExecutor,
        fileExecutor: MockFileExecutor
    ) {
        let registry = ToolRegistry(tools: [
            OpenAppTool(workspace: workspace),
            RunAppleScriptTool(executor: appleScriptExecutor),
            CalendarEventTool(executor: calendarExecutor),
            FileOpTool(executor: fileExecutor, allowedRoot: Self.testSandboxURL),
            RunShellTool(executor: shellExecutor)
        ])

        let bridge = ConfirmationBridge()
        let safetyGate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: safetyGate)

        let coordinator = GeminiLiveVoiceCoordinator(
            session: session,
            audioCapture: capture,
            audioPlayer: player,
            wakeWordDetector: detector,
            hotkeyManager: hotkey,
            toolDispatcher: dispatcher
        )

        return (coordinator, session, capture, player, detector, hotkey, workspace, shellExecutor, appleScriptExecutor, calendarExecutor, fileExecutor)
    }

    private func waitForCondition(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        intervalNanoseconds: UInt64 = 10_000_000,
        _ condition: () -> Bool
    ) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
        return condition()
    }

    // =========================================================================
    // MARK: - 1. Gemini Live Function Calling & DTO Decoding
    // =========================================================================

    @Test("1. BidiServerMessage decodes functionCall from serverContent.modelTurn.parts")
    func testDecodeFunctionCallFromModelTurnPart() throws {
        let json = """
        {
            "serverContent": {
                "modelTurn": {
                    "parts": [
                        {
                            "functionCall": {
                                "id": "call-live-1",
                                "name": "open_app",
                                "args": { "name": "Safari" }
                            },
                            "thoughtSignature": "test-sig-live"
                        }
                    ]
                }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let message = try JSONDecoder().decode(BidiServerMessage.self, from: data)

        #expect(message.serverContent?.modelTurn?.parts.count == 1)
        let part = message.serverContent?.modelTurn?.parts.first
        #expect(part?.functionCall?.id == "call-live-1")
        #expect(part?.functionCall?.name == "open_app")
        #expect(part?.functionCall?.args["name"]?.stringValue == "Safari")
        #expect(part?.thoughtSignature == "test-sig-live")
    }

    @Test("2. BidiServerMessage decodes toolCall from top-level toolCall container")
    func testDecodeFunctionCallFromToolCallContainer() throws {
        let json = """
        {
            "toolCall": {
                "functionCalls": [
                    {
                        "id": "call-live-top",
                        "name": "run_shell",
                        "args": { "command": "echo 'Ivy Live'" }
                    }
                ]
            }
        }
        """
        let data = json.data(using: .utf8)!
        let message = try JSONDecoder().decode(BidiServerMessage.self, from: data)

        #expect(message.toolCall?.functionCalls.count == 1)
        let call = message.toolCall?.functionCalls.first
        #expect(call?.id == "call-live-top")
        #expect(call?.name == "run_shell")
        #expect(call?.args["command"]?.stringValue == "echo 'Ivy Live'")
    }

    @Test("3. BidiToolResponse encodes structured function response matching Gemini Live specification")
    func testEncodeBidiToolResponse() throws {
        let response = FunctionResponse(
            name: "open_app",
            response: [
                "output": AnyCodable("Opened Safari successfully."),
                "success": AnyCodable(true)
            ],
            id: "call-123"
        )
        let bidiToolResponse = BidiToolResponse(functionResponse: response)
        let clientMessage = BidiClientMessage(toolResponse: bidiToolResponse)

        let data = try JSONEncoder().encode(clientMessage)
        let decoded = try JSONDecoder().decode(BidiClientMessage.self, from: data)

        #expect(decoded.toolResponse?.functionResponses.count == 1)
        let first = decoded.toolResponse?.functionResponses.first
        #expect(first?.id == "call-123")
        #expect(first?.response["output"]?.stringValue == "Opened Safari successfully.")
        #expect(first?.response["success"]?.boolValue == true)
    }

    @Test("4. Plain text turns from model are never treated as tool calls")
    func testPlainTextTurnNotTreatedAsToolCall() throws {
        let json = """
        {
            "serverContent": {
                "modelTurn": {
                    "parts": [
                        { "text": "Sure, I can help you with that!" }
                    ]
                }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let message = try JSONDecoder().decode(BidiServerMessage.self, from: data)

        #expect(message.serverContent?.modelTurn?.parts.first?.text == "Sure, I can help you with that!")
        #expect(message.serverContent?.modelTurn?.parts.first?.functionCall == nil)
        #expect(message.toolCall == nil)
    }

    // =========================================================================
    // MARK: - 2. Tool Routing & Execution via ToolRegistry
    // =========================================================================

    @Test("5. Safe tool (open_app) executes automatically without requiring user confirmation")
    func testSafeToolExecutionWithoutConfirmation() async throws {
        let (coordinator, session, _, _, _, _, workspace, _, _, _, _) = createTestCoordinator()
        let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
        workspace.knownApps["safari.app"] = safariURL

        await coordinator.startSession()
        #expect(coordinator.state == .listening)

        let call = FunctionCall(name: "open_app", args: ["name": "Safari"], id: "call-open-1")
        session.simulateToolCall(call)

        let receivedResponse = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-open-1" })
        }

        #expect(receivedResponse)
        #expect(coordinator.pendingConfirmation == nil)
        #expect(workspace.openedURLs == [safariURL])

        let sentResponse = session.sentToolResponses.first(where: { $0.id == "call-open-1" })
        #expect(sentResponse?.response["success"]?.boolValue == true)
        #expect(sentResponse?.response["result"]?.stringValue?.contains("Opened Safari successfully.") == true)

        await coordinator.stopSession()
    }

    @Test("6. Safe tool (file_op read) executes automatically without requiring user confirmation")
    func testSafeFileReadWithoutConfirmation() async throws {
        let (coordinator, session, _, _, _, _, _, _, _, _, fileExecutor) = createTestCoordinator()
        let filePath = Self.testSandboxURL.appendingPathComponent("test.txt").path
        fileExecutor.files[filePath] = "Hello from Ivy Live"

        await coordinator.startSession()

        let call = FunctionCall(
            name: "file_op",
            args: ["action": "read", "path": AnyCodable(filePath)],
            id: "call-file-read-1"
        )
        session.simulateToolCall(call)

        let receivedResponse = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-file-read-1" })
        }

        #expect(receivedResponse)
        #expect(coordinator.pendingConfirmation == nil)
        #expect(fileExecutor.recordedCalls.count == 1)
        #expect(fileExecutor.recordedCalls.first?.action == .read)

        let sentResponse = session.sentToolResponses.first(where: { $0.id == "call-file-read-1" })
        #expect(sentResponse?.response["success"]?.boolValue == true)
        #expect(sentResponse?.response["result"]?.stringValue?.contains("Hello from Ivy Live") == true)

        await coordinator.stopSession()
    }

    @Test("7. Unknown tool call produces structured toolNotFound response to Gemini Live")
    func testUnknownToolCallRejection() async throws {
        let (coordinator, session, _, _, _, _, _, _, _, _, _) = createTestCoordinator()

        await coordinator.startSession()

        let call = FunctionCall(name: "non_existent_tool", args: ["foo": "bar"], id: "call-unknown-1")
        session.simulateToolCall(call)

        let receivedResponse = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-unknown-1" })
        }

        #expect(receivedResponse)
        let sentResponse = session.sentToolResponses.first(where: { $0.id == "call-unknown-1" })
        #expect(sentResponse?.response["success"]?.boolValue == false)
        #expect(sentResponse?.response["toolNotFound"]?.boolValue == true)
        #expect(sentResponse?.response["error"]?.stringValue?.contains("Tool 'non_existent_tool' is not recognized.") == true)

        await coordinator.stopSession()
    }

    @Test("8. Malformed tool arguments produce validationError response before reaching executor")
    func testMalformedArgumentsRejectedBeforeExecution() async throws {
        let (coordinator, session, _, _, _, _, workspace, _, _, _, _) = createTestCoordinator()

        await coordinator.startSession()

        // Invalid empty application name for open_app
        let call = FunctionCall(name: "open_app", args: ["name": "  "], id: "call-invalid-arg-1")
        session.simulateToolCall(call)

        let receivedResponse = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-invalid-arg-1" })
        }

        #expect(receivedResponse)
        #expect(workspace.openedURLs.isEmpty)

        let sentResponse = session.sentToolResponses.first(where: { $0.id == "call-invalid-arg-1" })
        #expect(sentResponse?.response["success"]?.boolValue == false)
        #expect(sentResponse?.response["validationError"]?.boolValue == true)

        await coordinator.stopSession()
    }

    // =========================================================================
    // MARK: - 3. SafetyGate Invariants & Risky Tool Interception
    // =========================================================================

    @Test("9. Risky tool (run_applescript) intercepts execution and sets state to .toolConfirmation")
    func testRiskyAppleScriptRequiresConfirmation() async throws {
        let (coordinator, session, _, _, _, _, _, _, appleScriptExecutor, _, _) = createTestCoordinator()

        await coordinator.startSession()

        let call = FunctionCall(
            name: "run_applescript",
            args: ["script": "tell application \"Finder\" to get name"],
            id: "call-apple-1"
        )
        session.simulateToolCall(call)

        let reachedConfirmation = await waitForCondition {
            coordinator.state == .toolConfirmation && coordinator.pendingConfirmation != nil
        }

        #expect(reachedConfirmation)
        #expect(coordinator.pendingConfirmation?.toolName == "run_applescript")
        #expect(coordinator.pendingConfirmation?.title == "AppleScript Execution")
        #expect(appleScriptExecutor.executedScripts.isEmpty)

        // Approve via UI
        coordinator.respondToPendingConfirmation(id: coordinator.pendingConfirmation?.id, approved: true)

        let receivedResponse = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-apple-1" })
        }

        #expect(receivedResponse)
        #expect(appleScriptExecutor.executedScripts.count == 1)

        await coordinator.stopSession()
    }

    @Test("10. Risky tool (calendar_event) intercepts execution and sets state to .toolConfirmation")
    func testRiskyCalendarEventRequiresConfirmation() async throws {
        let (coordinator, session, _, _, _, _, _, _, _, calendarExecutor, _) = createTestCoordinator()

        await coordinator.startSession()

        let call = FunctionCall(
            name: "calendar_event",
            args: ["title": "Doctor Appointment", "date": "2026-10-01 10:00"],
            id: "call-cal-1"
        )
        session.simulateToolCall(call)

        let reachedConfirmation = await waitForCondition {
            coordinator.state == .toolConfirmation && coordinator.pendingConfirmation != nil
        }

        #expect(reachedConfirmation)
        #expect(coordinator.pendingConfirmation?.toolName == "calendar_event")
        #expect(calendarExecutor.recordedCalls.isEmpty)

        // Approve
        coordinator.respondToPendingConfirmation(id: coordinator.pendingConfirmation?.id, approved: true)

        let receivedResponse = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-cal-1" })
        }

        #expect(receivedResponse)
        #expect(calendarExecutor.recordedCalls.count == 1)

        await coordinator.stopSession()
    }

    @Test("11. Risky tool (run_shell) intercepts execution and sets state to .toolConfirmation")
    func testRiskyShellRequiresConfirmation() async throws {
        let (coordinator, session, _, _, _, _, _, shellExecutor, _, _, _) = createTestCoordinator()

        await coordinator.startSession()

        let call = FunctionCall(
            name: "run_shell",
            args: ["command": "ls -la"],
            id: "call-shell-1"
        )
        session.simulateToolCall(call)

        let reachedConfirmation = await waitForCondition {
            coordinator.state == .toolConfirmation && coordinator.pendingConfirmation != nil
        }

        #expect(reachedConfirmation)
        #expect(coordinator.pendingConfirmation?.toolName == "run_shell")
        #expect(shellExecutor.recordedCommands.isEmpty)

        // Approve
        coordinator.respondToPendingConfirmation(id: coordinator.pendingConfirmation?.id, approved: true)

        let receivedResponse = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-shell-1" })
        }

        #expect(receivedResponse)
        #expect(shellExecutor.recordedCommands.count == 1)

        await coordinator.stopSession()
    }

    @Test("12. Risky tool (file_op write) intercepts execution and sets state to .toolConfirmation")
    func testRiskyFileWriteRequiresConfirmation() async throws {
        let (coordinator, session, _, _, _, _, _, _, _, _, fileExecutor) = createTestCoordinator()
        let filePath = Self.testSandboxURL.appendingPathComponent("ivy_voice_test.txt").path

        await coordinator.startSession()

        let call = FunctionCall(
            name: "file_op",
            args: ["action": "write", "path": AnyCodable(filePath), "content": "Important Data"],
            id: "call-file-write-1"
        )
        session.simulateToolCall(call)

        let reachedConfirmation = await waitForCondition {
            coordinator.state == .toolConfirmation && coordinator.pendingConfirmation != nil
        }

        #expect(reachedConfirmation)
        #expect(coordinator.pendingConfirmation?.toolName == "file_op")
        #expect(fileExecutor.recordedCalls.isEmpty)

        // Approve
        coordinator.respondToPendingConfirmation(id: coordinator.pendingConfirmation?.id, approved: true)

        let receivedResponse = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-file-write-1" })
        }

        #expect(receivedResponse)
        #expect(fileExecutor.recordedCalls.count == 1)
        #expect(fileExecutor.recordedCalls.first?.action == .write)

        await coordinator.stopSession()
    }

    @Test("13. Risky tool (file_op delete) intercepts execution and sets state to .toolConfirmation")
    func testRiskyFileDeleteRequiresConfirmation() async throws {
        let (coordinator, session, _, _, _, _, _, _, _, _, fileExecutor) = createTestCoordinator()
        let filePath = Self.testSandboxURL.appendingPathComponent("ivy_voice_test.txt").path
        fileExecutor.files[filePath] = "Existing Content"

        await coordinator.startSession()

        let call = FunctionCall(
            name: "file_op",
            args: ["action": "delete", "path": AnyCodable(filePath)],
            id: "call-file-delete-1"
        )
        session.simulateToolCall(call)

        let reachedConfirmation = await waitForCondition {
            coordinator.state == .toolConfirmation && coordinator.pendingConfirmation != nil
        }

        #expect(reachedConfirmation)
        #expect(coordinator.pendingConfirmation?.toolName == "file_op")
        #expect(fileExecutor.recordedCalls.isEmpty)

        // Approve
        coordinator.respondToPendingConfirmation(id: coordinator.pendingConfirmation?.id, approved: true)

        let receivedResponse = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-file-delete-1" })
        }

        #expect(receivedResponse)
        #expect(fileExecutor.recordedCalls.count == 1)
        #expect(fileExecutor.recordedCalls.first?.action == .delete)

        await coordinator.stopSession()
    }

    @Test("14. User cancellation of confirmation executes nothing and returns cancellation response")
    func testUserCancellationExecutesNothing() async throws {
        let (coordinator, session, _, _, _, _, _, shellExecutor, _, _, _) = createTestCoordinator()

        await coordinator.startSession()

        let call = FunctionCall(
            name: "run_shell",
            args: ["command": "rm -rf /tmp/test"],
            id: "call-shell-cancel-1"
        )
        session.simulateToolCall(call)

        let reachedConfirmation = await waitForCondition {
            coordinator.state == .toolConfirmation && coordinator.pendingConfirmation != nil
        }

        #expect(reachedConfirmation)

        // Cancel via UI action
        coordinator.respondToPendingConfirmation(id: coordinator.pendingConfirmation?.id, approved: false)

        let receivedResponse = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-shell-cancel-1" })
        }

        #expect(receivedResponse)
        #expect(shellExecutor.recordedCommands.isEmpty)

        let sentResponse = session.sentToolResponses.first(where: { $0.id == "call-shell-cancel-1" })
        #expect(sentResponse?.response["success"]?.boolValue == false)
        #expect(sentResponse?.response["cancelled"]?.boolValue == true)

        await coordinator.stopSession()
    }

    @Test("15. Confirmation responses are strictly scoped to the exact pending request ID")
    func testConfirmationScopedToRequestId() async throws {
        let (coordinator, session, _, _, _, _, _, shellExecutor, _, _, _) = createTestCoordinator()

        await coordinator.startSession()

        let call = FunctionCall(name: "run_shell", args: ["command": "echo test"], id: "call-scope-1")
        session.simulateToolCall(call)

        let reachedConfirmation = await waitForCondition {
            coordinator.state == .toolConfirmation && coordinator.pendingConfirmation != nil
        }
        #expect(reachedConfirmation)

        // Try responding with a random non-matching UUID
        let fakeId = UUID()
        coordinator.respondToPendingConfirmation(id: fakeId, approved: true)

        // Should still be waiting for the real confirmation!
        #expect(coordinator.state == .toolConfirmation)
        #expect(coordinator.pendingConfirmation != nil)
        #expect(shellExecutor.recordedCommands.isEmpty)

        // Now respond with correct ID
        coordinator.respondToPendingConfirmation(id: coordinator.pendingConfirmation?.id, approved: true)

        let executed = await waitForCondition {
            !shellExecutor.recordedCommands.isEmpty
        }
        #expect(executed)

        await coordinator.stopSession()
    }

    // =========================================================================
    // MARK: - 4. Microphone Audio Suppression & Anti-Voice Approval
    // =========================================================================

    @Test("16. Microphone speech ('yes', 'do it', 'sure') during tool confirmation CANNOT approve tool")
    func testVoiceCannotApproveConfirmation() async throws {
        let (coordinator, session, _, _, detector, _, _, shellExecutor, _, _, _) = createTestCoordinator()

        await coordinator.startSession()

        let call = FunctionCall(name: "run_shell", args: ["command": "echo risky"], id: "call-voice-approve-1")
        session.simulateToolCall(call)

        let reachedConfirmation = await waitForCondition {
            coordinator.state == .toolConfirmation && coordinator.pendingConfirmation != nil
        }
        #expect(reachedConfirmation)

        // Simulate user speaking "yes", "do it", "sure", "confirm" into the microphone
        detector.simulateTranscription("yes")
        detector.simulateTranscription("do it")
        detector.simulateTranscription("sure, please proceed")
        detector.simulateTranscription("confirm")

        // Wait to verify it does not approve
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(coordinator.state == .toolConfirmation)
        #expect(coordinator.pendingConfirmation != nil)
        #expect(shellExecutor.recordedCommands.isEmpty)
        #expect(session.sentToolResponses.isEmpty)

        await coordinator.stopSession()
    }

    @Test("17. Microphone audio is NOT streamed to Gemini Live during .toolConfirmation or .toolExecution")
    func testMicrophoneAudioNotStreamedDuringConfirmationOrExecution() async throws {
        let (coordinator, session, capture, _, _, _, _, _, _, _, _) = createTestCoordinator()

        await coordinator.startSession()
        #expect(coordinator.state == .listening)

        // In listening state, audio IS forwarded
        let testChunk1 = Data([0x01, 0x02, 0x03])
        capture.simulateAudioChunk(testChunk1)

        let sentFirstChunk = await waitForCondition {
            session.sentAudioChunks.contains(testChunk1)
        }
        #expect(sentFirstChunk)

        // Trigger tool confirmation
        let call = FunctionCall(name: "run_shell", args: ["command": "echo mic-test"], id: "call-mic-1")
        session.simulateToolCall(call)

        let reachedConfirmation = await waitForCondition {
            coordinator.state == .toolConfirmation
        }
        #expect(reachedConfirmation)

        // Send audio chunk during confirmation
        let testChunk2 = Data([0xAA, 0xBB, 0xCC])
        capture.simulateAudioChunk(testChunk2)
        try await Task.sleep(nanoseconds: 30_000_000)

        // Audio must NOT be sent to Gemini Live
        #expect(!session.sentAudioChunks.contains(testChunk2))

        // Approve and transition to execution
        coordinator.respondToPendingConfirmation(id: coordinator.pendingConfirmation?.id, approved: true)

        let reachedExecution = await waitForCondition {
            coordinator.state == .toolExecution || !session.sentToolResponses.isEmpty
        }
        #expect(reachedExecution)

        // Send audio chunk during execution
        let testChunk3 = Data([0xDD, 0xEE, 0xFF])
        capture.simulateAudioChunk(testChunk3)
        try await Task.sleep(nanoseconds: 30_000_000)

        // Audio must NOT be sent to Gemini Live
        #expect(!session.sentAudioChunks.contains(testChunk3))

        await coordinator.stopSession()
    }

    // =========================================================================
    // MARK: - 5. Voice State Machine Transitions
    // =========================================================================

    @Test("18. Complete State Machine Cycle: IDLE -> LISTENING -> THINKING -> TOOL_CONFIRMATION -> TOOL_EXECUTION -> SPEAKING -> LISTENING")
    func testCompleteStateMachineCycle() async throws {
        let (coordinator, session, _, player, _, _, _, _, _, _, _) = createTestCoordinator()

        #expect(coordinator.state == .idle)

        await coordinator.startSession()
        #expect(coordinator.state == .listening)

        // Gemini Live sends tool call
        let call = FunctionCall(name: "run_shell", args: ["command": "date"], id: "call-fsm-1")
        session.simulateToolCall(call)

        let reachedConfirmation = await waitForCondition {
            coordinator.state == .toolConfirmation
        }
        #expect(reachedConfirmation)

        // Approve
        coordinator.respondToPendingConfirmation(id: coordinator.pendingConfirmation?.id, approved: true)

        let sentToolResp = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-fsm-1" })
        }
        #expect(sentToolResp)

        // Phase 4E: stays in .toolExecution until the spoken reply arrives (TOOL_EXECUTION -> SPEAKING, no THINKING flicker)
        #expect(coordinator.state == .toolExecution)

        // Gemini Live speaks response
        let spokenChunk = Data([0x12, 0x34])
        session.simulateEvent(.audioChunk(spokenChunk))

        let reachedSpeaking = await waitForCondition {
            coordinator.state == .speaking
        }
        #expect(reachedSpeaking)
        #expect(player.isPlaying)

        // Model completes turn
        session.simulateEvent(.turnComplete)

        // Audio finishes playing
        player.finishPlayback()

        let reachedListening = await waitForCondition {
            coordinator.state == .listening
        }
        #expect(reachedListening)

        await coordinator.stopSession()
        #expect(coordinator.state == .idle)
    }

    @Test("19. Safe Tool State Machine Cycle: LISTENING -> THINKING -> TOOL_EXECUTION -> SPEAKING -> LISTENING")
    func testSafeToolStateMachineCycle() async throws {
        let (coordinator, session, _, player, _, _, workspace, _, _, _, _) = createTestCoordinator()
        let notesURL = URL(fileURLWithPath: "/Applications/Notes.app")
        workspace.knownApps["notes.app"] = notesURL

        await coordinator.startSession()
        #expect(coordinator.state == .listening)

        // Gemini Live sends safe tool call
        let call = FunctionCall(name: "open_app", args: ["name": "Notes"], id: "call-safe-fsm-1")
        session.simulateToolCall(call)

        let sentToolResp = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-safe-fsm-1" })
        }
        #expect(sentToolResp)
        #expect(coordinator.pendingConfirmation == nil)

        // Audio response from Gemini
        session.simulateEvent(.audioChunk(Data([0x55, 0x66])))
        let reachedSpeaking = await waitForCondition {
            coordinator.state == .speaking
        }
        #expect(reachedSpeaking)

        session.simulateEvent(.turnComplete)
        player.finishPlayback()

        let reachedListening = await waitForCondition {
            coordinator.state == .listening
        }
        #expect(reachedListening)

        await coordinator.stopSession()
    }

    // =========================================================================
    // MARK: - 6. Interruption & Cancellation ("Hey Ivy")
    // =========================================================================

    @Test("20. Saying 'Hey Ivy' during tool confirmation cancels confirmation and resets to .listening")
    func testHeyIvyCancelsToolConfirmation() async throws {
        let (coordinator, session, _, _, detector, _, _, shellExecutor, _, _, _) = createTestCoordinator()

        await coordinator.startSession()

        let call = FunctionCall(name: "run_shell", args: ["command": "rm -rf /tmp/danger"], id: "call-danger-1")
        session.simulateToolCall(call)

        let reachedConfirmation = await waitForCondition {
            coordinator.state == .toolConfirmation && coordinator.pendingConfirmation != nil
        }
        #expect(reachedConfirmation)

        // Say "Hey Ivy"
        detector.simulateTranscription("Hey Ivy")

        let returnedToListening = await waitForCondition {
            coordinator.state == .listening
        }

        #expect(returnedToListening)
        #expect(coordinator.pendingConfirmation == nil)
        #expect(shellExecutor.recordedCommands.isEmpty)

        // Verify cancellation was sent to Gemini Live
        let sentCancellation = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-danger-1" })
        }
        #expect(sentCancellation)
        let response = session.sentToolResponses.first(where: { $0.id == "call-danger-1" })
        #expect(response?.response["cancelled"]?.boolValue == true)

        await coordinator.stopSession()
    }

    @Test("21. Saying 'Hey Ivy' while Ivy is speaking after tool execution halts audio immediately")
    func testHeyIvyHaltsAudioAfterToolExecution() async throws {
        let (coordinator, session, _, player, detector, _, workspace, _, _, _, _) = createTestCoordinator()
        let notesURL = URL(fileURLWithPath: "/Applications/Notes.app")
        workspace.knownApps["notes.app"] = notesURL

        await coordinator.startSession()

        let call = FunctionCall(name: "open_app", args: ["name": "Notes"], id: "call-halt-1")
        session.simulateToolCall(call)

        let sentToolResp = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-halt-1" })
        }
        #expect(sentToolResp)

        // Speech starts
        session.simulateEvent(.audioChunk(Data([0x11, 0x22, 0x33])))
        let reachedSpeaking = await waitForCondition {
            coordinator.state == .speaking
        }
        #expect(reachedSpeaking)
        #expect(player.isPlaying)

        // Interrupted by "Hey Ivy"
        detector.simulateTranscription("Hey Ivy")

        let interrupted = await waitForCondition {
            coordinator.state == .listening
        }
        #expect(interrupted)
        #expect(player.isStopped)

        await coordinator.stopSession()
    }

    // =========================================================================
    // MARK: - 7. Push-to-Talk (PTT) Integration
    // =========================================================================

    @Test("22. A fresh push-to-talk hold cancels pending confirmation and records a new request")
    func testPushToTalkDuringToolConfirmationCancelsApproval() async throws {
        let (coordinator, session, capture, _, _, hotkey, _, shell, _, _, _) = createTestCoordinator()

        try coordinator.registerHotkey()
        await coordinator.startSession()

        let call = FunctionCall(name: "run_shell", args: ["command": "uptime"], id: "call-ptt-1")
        session.simulateToolCall(call)

        let reachedConfirmation = await waitForCondition {
            coordinator.state == .toolConfirmation
        }
        #expect(reachedConfirmation)

        // Hotkey down
        hotkey.simulateKeyDown()
        #expect(await waitForCondition { coordinator.state == .listening && coordinator.isPushToTalkActive })
        #expect(coordinator.pendingConfirmation == nil)
        #expect(session.isConnected)
        #expect(capture.isCapturing)
        coordinator.respondToPendingConfirmation(approved: true) // withdrawn approval cannot execute

        // Hotkey up
        hotkey.simulateKeyUp()
        #expect(await waitForCondition { coordinator.state == .idle })
        #expect(!session.isConnected && !capture.isCapturing)
        #expect(shell.recordedCommands.isEmpty)

        // Clean up
        coordinator.respondToPendingConfirmation(id: coordinator.pendingConfirmation?.id, approved: false)
        await coordinator.stopSession()
    }

    // =========================================================================
    // MARK: - 8. Duplicate Tool Call Suppression & Concurrency Safety
    // =========================================================================

    @Test("23. Duplicate function call events with identical ID are executed only once")
    func testDuplicateFunctionCallSuppression() async throws {
        let (coordinator, session, _, _, _, _, workspace, _, _, _, _) = createTestCoordinator()
        let safariURL = URL(fileURLWithPath: "/Applications/Safari.app")
        workspace.knownApps["safari.app"] = safariURL

        await coordinator.startSession()

        let call = FunctionCall(name: "open_app", args: ["name": "Safari"], id: "call-dedup-1")

        // Send identical tool call twice in rapid succession
        session.simulateToolCall(call)
        session.simulateToolCall(call)

        let sentResponse = await waitForCondition {
            session.sentToolResponses.contains(where: { $0.id == "call-dedup-1" })
        }
        #expect(sentResponse)

        try await Task.sleep(nanoseconds: 50_000_000)

        // Workspace must have opened the app exactly once
        #expect(workspace.openedURLs.count == 1)
        #expect(session.sentToolResponses.count == 1)

        await coordinator.stopSession()
    }

    @Test("24. Session token change while dispatching tool safely discards result")
    func testSessionTokenChangeDiscardsToolResult() async throws {
        let (coordinator, session, _, _, _, _, _, _, _, _, fileExecutor) = createTestCoordinator()
        let filePath = Self.testSandboxURL.appendingPathComponent("token_test.txt").path
        fileExecutor.files[filePath] = "secret"

        await coordinator.startSession()

        let call = FunctionCall(
            name: "file_op",
            args: ["action": "read", "path": AnyCodable(filePath)],
            id: "call-token-1"
        )
        session.simulateToolCall(call)

        // Immediately stop session before result can be delivered to session
        await coordinator.stopSession()

        try await Task.sleep(nanoseconds: 50_000_000)

        // Stale session must not have received any tool responses
        #expect(session.sentToolResponses.isEmpty)
        #expect(coordinator.state == .idle)
    }

    // =========================================================================
    // MARK: - 9. ElevenLabs & Live Voice Configuration Preserved
    // =========================================================================

    @Test("25. ElevenLabs TTS and synthesizer remain completely intact and independent")
    func testElevenLabsTTSUntouched() {
        let keyProvider = StaticElevenLabsKeyProvider(key: "test_key")
        let config = ElevenLabsConfiguration(voiceID: "test_voice")
        let synthesizer = ElevenLabsSpeechSynthesizer(configuration: config, keyProvider: keyProvider)

        #expect(synthesizer.keyProvider.getAPIKey() == "test_key")
        #expect(synthesizer.configuration.voiceID == "test_voice")
    }

    @Test("26. Gemini Live voice name remains strictly configured as Kore")
    func testLiveVoiceNameStrictlyKore() {
        #expect(GeminiLiveVoiceCoordinator.liveVoiceName == "Kore")
        #expect(GeminiLiveClient.liveVoiceName == "Kore")
    }
}
