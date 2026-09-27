import Testing
import Foundation
@testable import IvyCore

// MARK: - Phase 2C SafetyGate Tests

@Suite("Phase 2C - SafetyGate Tests")
struct Phase2CSafetyGateTests {

    @Test("SafetyPolicy classifies calendar_event as risky")
    func testCalendarEventIsRisky() {
        let policy = SafetyPolicy()
        #expect(policy.classification(for: "calendar_event") == .risky)

        let tool = CalendarEventTool(executor: MockCalendarExecutor())
        #expect(policy.classification(for: tool) == .risky)
        #expect(tool.safetyClassification == .risky)
    }

    @Test("InteractiveSafetyGate builds structured confirmation request for calendar_event")
    func testConfirmationRequestContent() async {
        let provider = TestConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let tool = CalendarEventTool(executor: MockCalendarExecutor())
        let call = FunctionCall(
            name: "calendar_event",
            args: [
                "title": AnyCodable("Dentist"),
                "date": AnyCodable("2026-10-01T15:00:00Z")
            ],
            id: "call-cal-1"
        )

        let decision = await gate.evaluate(tool: tool, call: call)
        #expect(decision == .approve)
        #expect(provider.callCount == 1)

        let req = provider.requestedConfirmation
        #expect(req?.toolName == "calendar_event")
        #expect(req?.title == "Create Calendar Event")
        #expect(req?.prompt.contains("Dentist") == true)
        #expect(req?.prompt.contains("2026-10-01T15:00:00Z") == true)
        #expect(req?.detail.contains("Action: Create Calendar Event") == true)
        #expect(req?.detail.contains("Title: Dentist") == true)
        #expect(req?.detail.contains("Date/Time: 2026-10-01T15:00:00Z") == true)
        #expect(req?.detail.contains("Duration: 1 hour") == true)
    }

    @Test("PassThroughSafetyGate rejects calendar_event because it is risky")
    func testPassThroughRejectsCalendarEvent() async {
        let gate = PassThroughSafetyGate()
        let tool = CalendarEventTool(executor: MockCalendarExecutor())
        let call = FunctionCall(name: "calendar_event", args: ["title": "Test", "date": "2026-10-01T10:00:00Z"])

        let decision = await gate.evaluate(tool: tool, call: call)
        #expect(decision == .reject(reason: "Execution rejected by safety policy: Tool 'calendar_event' is classified as risky and requires user confirmation."))
    }
}

// MARK: - Phase 2C Confirmation Workflow Tests

@Suite("Phase 2C - Confirmation Workflow Tests")
struct Phase2CConfirmationWorkflowTests {

    @Test("Execution halts while calendar confirmation is pending")
    @MainActor
    func testExecutionHaltsWhilePending() async {
        final class StepClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "Cancelled.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "calendar_event", args: ["title": "Meeting", "date": "2026-10-01T14:00:00Z"], id: "call-1")]
                )
            }
        }

        let mockExecutor = MockCalendarExecutor()
        let tool = CalendarEventTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let brain = IvyBrain(client: StepClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Schedule a meeting")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        #expect(mockExecutor.recordedCalls.isEmpty)

        brain.respondToPendingConfirmation(approved: false)
        await sendTask.value
    }

    @Test("Cancel guarantees calendar executor is never called")
    @MainActor
    func testCancelNeverCallsCalendarExecutor() async {
        let mockExecutor = MockCalendarExecutor()
        let tool = CalendarEventTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        final class CancelClient: GeminiClientProtocol, @unchecked Sendable {
            var receivedFunctionResponse: FunctionResponse?

            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if let last = history.last, let resp = last.functionResponse {
                    self.receivedFunctionResponse = resp
                    return ModelTurnResponse(text: "Cancelled.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "calendar_event", args: ["title": "Dinner", "date": "2026-10-01T19:00:00Z"], id: "call-cancel")]
                )
            }
        }

        let client = CancelClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Book dinner")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        brain.respondToPendingConfirmation(approved: false)
        await sendTask.value

        #expect(mockExecutor.recordedCalls.isEmpty)
        #expect(client.receivedFunctionResponse?.response["error"]?.stringValue == "User cancelled operation with prejudice.")
    }

    @Test("Do it creates exactly one calendar event")
    @MainActor
    func testDoItCreatesExactlyOneEvent() async {
        let mockExecutor = MockCalendarExecutor()
        let tool = CalendarEventTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        final class ApproveClient: GeminiClientProtocol, @unchecked Sendable {
            var receivedFunctionResponse: FunctionResponse?

            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if let last = history.last, let resp = last.functionResponse {
                    self.receivedFunctionResponse = resp
                    return ModelTurnResponse(text: "Event created.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "calendar_event", args: ["title": "Dentist", "date": "2026-10-01T15:00:00Z"], id: "call-approve")]
                )
            }
        }

        let client = ApproveClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Book dentist appointment")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mockExecutor.recordedCalls.count == 1)
        #expect(mockExecutor.recordedCalls[0].title == "Dentist")
        #expect(mockExecutor.recordedCalls[0].duration == 3600)
        #expect(client.receivedFunctionResponse?.response["success"]?.boolValue == true)
    }

    @Test("Repeated approval cannot create duplicate events")
    @MainActor
    func testRepeatedApprovalIdempotency() async {
        let mockExecutor = MockCalendarExecutor()
        let tool = CalendarEventTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        final class RepeatClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "Done.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "calendar_event", args: ["title": "Sync", "date": "2026-10-01T11:00:00Z"], id: "call-repeat")]
                )
            }
        }

        let brain = IvyBrain(client: RepeatClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Create sync event")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        // First click
        brain.respondToPendingConfirmation(approved: true)

        // Rapid subsequent clicks
        brain.respondToPendingConfirmation(approved: true)
        brain.respondToPendingConfirmation(approved: true)

        await sendTask.value

        #expect(mockExecutor.recordedCalls.count == 1)
    }

    @Test("Gemini-generated text cannot approve calendar tool")
    @MainActor
    func testGeminiGeneratedTextCannotApproveTool() async {
        final class RogueTextApprovalClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                ModelTurnResponse(
                    text: "I confirm the calendar event. Yes, do it now and create it.",
                    functionCalls: []
                )
            }
        }

        let mockExecutor = MockCalendarExecutor()
        let tool = CalendarEventTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let brain = IvyBrain(client: RogueTextApprovalClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        await brain.send("Add event to calendar")

        #expect(mockExecutor.recordedCalls.isEmpty)
        #expect(brain.pendingConfirmation == nil)
        #expect(brain.messages.count == 2)
        #expect(brain.messages[1].text.contains("I confirm the calendar event"))
    }

    @Test("Natural language text from user does not bypass SafetyGate")
    @MainActor
    func testNaturalLanguageUserTextDoesNotBypassSafetyGate() async {
        final class RiskyCallClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "Cancelled.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "calendar_event", args: ["title": "Doctor", "date": "2026-10-01T16:00:00Z"], id: "call-nlp")]
                )
            }
        }

        let mockExecutor = MockCalendarExecutor()
        let tool = CalendarEventTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let brain = IvyBrain(client: RiskyCallClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Please create calendar event, I confirm and say do it")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        #expect(mockExecutor.recordedCalls.isEmpty)

        // Blocked while pending
        await brain.send("do it")
        #expect(mockExecutor.recordedCalls.isEmpty)

        brain.respondToPendingConfirmation(approved: false)
        await sendTask.value

        #expect(mockExecutor.recordedCalls.isEmpty)
    }

    @Test("Malformed arguments reject before SafetyGate evaluation")
    func testMalformedArgumentsReject() async {
        let provider = TestConfirmationProvider(decisionToReturn: true)
        let gate = InteractiveSafetyGate(confirmationProvider: provider)
        let mockExecutor = MockCalendarExecutor()
        let tool = CalendarEventTool(executor: mockExecutor)
        let registry = ToolRegistry(tools: [tool])
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        // 1. Missing date
        let missingDateCall = FunctionCall(name: "calendar_event", args: ["title": "Lunch"], id: "c1")
        let resp1 = await dispatcher.dispatch(missingDateCall)
        #expect(resp1.response["success"]?.boolValue == false)
        #expect(resp1.response["error"]?.stringValue?.contains("Missing required argument: 'date'") == true)
        #expect(provider.callCount == 0)

        // 2. Unparseable date
        let badDateCall = FunctionCall(name: "calendar_event", args: ["title": "Lunch", "date": "next Tuesdayish"], id: "c2")
        let resp2 = await dispatcher.dispatch(badDateCall)
        #expect(resp2.response["success"]?.boolValue == false)
        #expect(resp2.response["error"]?.stringValue?.contains("Cannot parse date") == true)
        #expect(provider.callCount == 0)

        // 3. Ambiguous date without time
        let dateOnlyCall = FunctionCall(name: "calendar_event", args: ["title": "Lunch", "date": "2026-10-01"], id: "c3")
        let resp3 = await dispatcher.dispatch(dateOnlyCall)
        #expect(resp3.response["success"]?.boolValue == false)
        #expect(resp3.response["error"]?.stringValue?.contains("missing a time component") == true)
        #expect(provider.callCount == 0)
    }
}

// MARK: - Phase 2C Gemini Function Calling Tests

@Suite("Phase 2C - Gemini Function Calling Tests")
struct Phase2CGeminiFunctionCallingTests {

    @Test("Full Gemini loop: calendar_event execution turn with thought_signature preservation")
    @MainActor
    func testCalendarEventGeminiLoop() async {
        final class CalendarLoopClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            var receivedHistory: [ChatMessage] = []
            let expectedSignature = "cal_signature_abc123"

            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                self.receivedHistory = history
                step += 1

                if step == 1 {
                    let part = Part(
                        functionCall: FunctionCall(
                            name: "calendar_event",
                            args: ["title": "Team Standup", "date": "2026-10-01T09:00:00Z"],
                            id: "call-loop-cal"
                        ),
                        thoughtSignature: expectedSignature
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [part.functionCall!],
                        functionCallParts: [part],
                        thoughtSignature: expectedSignature
                    )
                } else if step == 2 {
                    return ModelTurnResponse(text: "Your standup is booked. Don't be late.")
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mockExecutor = MockCalendarExecutor()
        let tool = CalendarEventTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = CalendarLoopClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Put standup on my calendar")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mockExecutor.recordedCalls.count == 1)
        #expect(mockExecutor.recordedCalls[0].title == "Team Standup")
        #expect(brain.messages.last?.text == "Your standup is booked. Don't be late.")

        // Verify thought_signature was preserved in the history sent to Gemini
        let modelCallMsg = client.receivedHistory.first { $0.functionCall?.name == "calendar_event" }
        #expect(modelCallMsg?.thoughtSignature == "cal_signature_abc123")
        #expect(modelCallMsg?.functionCallPart?.thoughtSignature == "cal_signature_abc123")

        let functionRespMsg = client.receivedHistory.first { $0.role == .function }
        #expect(functionRespMsg?.functionResponse?.name == "calendar_event")
        #expect(functionRespMsg?.functionResponse?.response["success"]?.boolValue == true)
    }

    @Test("Calendar error in EventKit is returned in functionResponse and explained by Gemini")
    @MainActor
    func testCalendarErrorFlow() async {
        final class ErrorReportingClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            var receivedFunctionResponse: FunctionResponse?

            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [FunctionCall(name: "calendar_event", args: ["title": "Offsite", "date": "2026-10-01T10:00:00Z"], id: "call-err")]
                    )
                } else if step == 2 {
                    if let last = history.last, let resp = last.functionResponse {
                        self.receivedFunctionResponse = resp
                        return ModelTurnResponse(text: "Your calendar refused: \(resp.response["error"]?.stringValue ?? ""). Check System Settings.")
                    }
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mockExecutor = MockCalendarExecutor()
        mockExecutor.errorToThrow = CalendarError.permissionDenied

        let tool = CalendarEventTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = ErrorReportingClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Schedule offsite")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mockExecutor.recordedCalls.count == 0)
        #expect(client.receivedFunctionResponse?.response["success"]?.boolValue == false)
        #expect(client.receivedFunctionResponse?.response["error"]?.stringValue?.contains("Calendar access denied") == true)
        #expect(brain.messages.last?.text.contains("Check System Settings") == true)
    }

    @Test("Chained multi-tool turns: calendar_event approved then open_app auto-executed in single send")
    @MainActor
    func testChainedCalendarAndAppTurns() async {
        final class ChainedToolsClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            var receivedCallNames: [String] = []

            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let part = Part(
                        functionCall: FunctionCall(name: "calendar_event", args: ["title": "Demo", "date": "2026-10-01T15:00:00Z"], id: "call-cal"),
                        thoughtSignature: "sig_cal_1"
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [part.functionCall!],
                        functionCallParts: [part],
                        thoughtSignature: "sig_cal_1"
                    )
                } else if step == 2 {
                    if let last = history.last, let resp = last.functionResponse {
                        receivedCallNames.append(resp.name)
                    }
                    let part = Part(
                        functionCall: FunctionCall(name: "open_app", args: ["name": "Calendar"], id: "call-app"),
                        thoughtSignature: "sig_app_2"
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [part.functionCall!],
                        functionCallParts: [part],
                        thoughtSignature: "sig_app_2"
                    )
                } else if step == 3 {
                    if let last = history.last, let resp = last.functionResponse {
                        receivedCallNames.append(resp.name)
                    }
                    return ModelTurnResponse(text: "Event created and Calendar opened. Anything else?")
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mockCal = MockCalendarExecutor()
        let mockWS = MockWorkspace()
        mockWS.knownApps["calendar"] = URL(fileURLWithPath: "/System/Applications/Calendar.app")

        let calTool = CalendarEventTool(executor: mockCal)
        let appTool = OpenAppTool(workspace: mockWS)
        let toolRegistry = ToolRegistry(tools: [calTool, appTool])

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = ChainedToolsClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Add demo event and open calendar")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        // Approve calendar event
        #expect(brain.pendingConfirmation?.toolName == "calendar_event")
        brain.respondToPendingConfirmation(approved: true)

        await sendTask.value

        #expect(mockCal.recordedCalls.count == 1)
        #expect(mockWS.openedURLs.count == 1)
        #expect(client.receivedCallNames == ["calendar_event", "open_app"])
        #expect(brain.messages.last?.text == "Event created and Calendar opened. Anything else?")
    }
}

// MARK: - Phase 2C Regression Tests

@Suite("Phase 2C - Regression Tests")
struct Phase2CRegressionTests {

    @Test("Phase 1 regression: pure text multi-turn conversations unaffected by calendar")
    @MainActor
    func testPureTextConversation() async {
        final class TextClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "Sarcastic text" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                ModelTurnResponse(text: "Pure sarcastic text")
            }
        }

        let brain = IvyBrain(client: TextClient(), apiKey: "valid_key")
        await brain.send("Hello Ivy")
        #expect(brain.messages.count == 2)
        #expect(brain.messages[1].text == "Pure sarcastic text")
        #expect(brain.pendingConfirmation == nil)
    }

    @Test("Phase 2A regression: open_app executes without confirmation")
    @MainActor
    func testOpenAppRegression() async {
        final class AppClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "Safari opened.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "open_app", args: ["name": "Safari"], id: "call-safari")]
                )
            }
        }

        let mockWS = MockWorkspace()
        mockWS.knownApps["safari"] = URL(fileURLWithPath: "/Applications/Safari.app")
        let appTool = OpenAppTool(workspace: mockWS)
        let toolRegistry = ToolRegistry(tools: [appTool])

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let brain = IvyBrain(client: AppClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        await brain.send("Open Safari")

        #expect(mockWS.openedURLs.count == 1)
        #expect(brain.pendingConfirmation == nil)
        #expect(brain.messages.last?.text == "Safari opened.")
    }

    @Test("Phase 2B regression: run_applescript prompts and executes safely upon approval")
    @MainActor
    func testAppleScriptRegression() async {
        final class ASClient: GeminiClientProtocol, @unchecked Sendable {
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                if history.contains(where: { $0.role == .function }) {
                    return ModelTurnResponse(text: "Script complete.")
                }
                return ModelTurnResponse(
                    text: nil,
                    functionCalls: [FunctionCall(name: "run_applescript", args: ["script": "beep"], id: "call-as")]
                )
            }
        }

        let mockExecutor = MockAppleScriptExecutor()
        let tool = RunAppleScriptTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let brain = IvyBrain(client: ASClient(), toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Beep")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        #expect(brain.pendingConfirmation?.toolName == "run_applescript")
        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mockExecutor.executedScripts.count == 1)
        #expect(brain.messages.last?.text == "Script complete.")
    }

    @Test("Cancellation response produces in-character sarcastic reply from Gemini")
    @MainActor
    func testCancellationResponseProducesInCharacterReply() async {
        final class CancelPersonalityClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let part = Part(
                        functionCall: FunctionCall(name: "calendar_event", args: ["title": "Sync", "date": "2026-10-01T10:00:00Z"], id: "call-c1"),
                        thoughtSignature: "sig_cal_c1"
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [part.functionCall!],
                        functionCallParts: [part],
                        thoughtSignature: "sig_cal_c1"
                    )
                } else if step == 2 {
                    if let last = history.last, let resp = last.functionResponse {
                        let errorMsg = resp.response["error"]?.stringValue ?? ""
                        return ModelTurnResponse(text: "You chickened out (\(errorMsg)). Fine by me.")
                    }
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mockExecutor = MockCalendarExecutor()
        let tool = CalendarEventTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = CancelPersonalityClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        let sendTask = Task {
            await brain.send("Schedule sync")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(brain.pendingConfirmation != nil)
        brain.respondToPendingConfirmation(approved: false)
        await sendTask.value

        #expect(mockExecutor.recordedCalls.isEmpty)
        #expect(brain.messages.last?.text.contains("You chickened out") == true)
    }

    @Test("Multi-turn conversation: calendar tool execution turn followed by pure text follow-up")
    @MainActor
    func testMultiTurnConversationWithCalendarFollowUp() async {
        final class MultiTurnCalClient: GeminiClientProtocol, @unchecked Sendable {
            var step = 0
            func generateContent(history: [ChatMessage], systemPrompt: String, apiKey: String) async throws -> String { "ok" }
            func generateContent(history: [ChatMessage], systemPrompt: String, tools: [ToolDeclarationWrapper]?, apiKey: String) async throws -> ModelTurnResponse {
                step += 1
                if step == 1 {
                    let part = Part(
                        functionCall: FunctionCall(name: "calendar_event", args: ["title": "Demo", "date": "2026-10-01T15:00:00Z"], id: "call-demo"),
                        thoughtSignature: "sig_demo"
                    )
                    return ModelTurnResponse(
                        text: nil,
                        functionCalls: [part.functionCall!],
                        functionCallParts: [part],
                        thoughtSignature: "sig_demo"
                    )
                } else if step == 2 {
                    return ModelTurnResponse(text: "I added Demo to your calendar. Try not to miss it.")
                } else if step == 3 {
                    return ModelTurnResponse(text: "Your Demo event is at 3 PM, obviously.")
                }
                throw GeminiClientError.emptyResponse
            }
        }

        let mockExecutor = MockCalendarExecutor()
        let tool = CalendarEventTool(executor: mockExecutor)
        let toolRegistry = ToolRegistry(tools: [tool])
        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: toolRegistry, safetyGate: gate)

        let client = MultiTurnCalClient()
        let brain = IvyBrain(client: client, toolDispatcher: dispatcher, apiKey: "valid_key")
        bridge.handler = brain

        // Turn 1: tool turn
        let sendTask = Task {
            await brain.send("Add demo to calendar")
        }

        for _ in 0..<50 {
            if brain.pendingConfirmation != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        brain.respondToPendingConfirmation(approved: true)
        await sendTask.value

        #expect(mockExecutor.recordedCalls.count == 1)
        #expect(brain.messages.last?.text == "I added Demo to your calendar. Try not to miss it.")

        // Turn 2: pure text follow-up
        await brain.send("What time is it again?")
        #expect(brain.messages.last?.text == "Your Demo event is at 3 PM, obviously.")
        #expect(brain.messages.count == 4)
    }

    @Test("Combined ToolRegistry.defaultRegistry includes calendar_event and enforces SafetyGate")
    @MainActor
    func testCombinedToolRegistryDefaultDispatch() async {
        let mockCal = MockCalendarExecutor()
        let mockWS = MockWorkspace()
        let mockAS = MockAppleScriptExecutor()

        let registry = ToolRegistry.defaultRegistry(
            workspace: mockWS,
            appleScriptExecutor: mockAS,
            calendarExecutor: mockCal
        )

        #expect(registry.hasTool(named: "open_app"))
        #expect(registry.hasTool(named: "run_applescript"))
        #expect(registry.hasTool(named: "calendar_event"))
        #expect(registry.hasTool(named: "file_op"))
        #expect(registry.count == 4)

        let bridge = ConfirmationBridge()
        let gate = InteractiveSafetyGate(confirmationProvider: bridge)
        let dispatcher = ToolDispatcher(registry: registry, safetyGate: gate)

        let provider = TestConfirmationProvider(decisionToReturn: false)
        let testGate = InteractiveSafetyGate(confirmationProvider: provider)
        let testDispatcher = ToolDispatcher(registry: registry, safetyGate: testGate)

        let call = FunctionCall(name: "calendar_event", args: ["title": "Doctor", "date": "2026-10-01T11:00:00Z"], id: "c-def")
        let response = await testDispatcher.dispatch(call)

        #expect(response.response["success"]?.boolValue == false)
        #expect(response.response["error"]?.stringValue?.contains("User cancelled") == true)
        #expect(mockCal.recordedCalls.isEmpty)
    }
}
