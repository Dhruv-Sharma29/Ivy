import Foundation
import Testing
import os
@testable import IvyCore

@Suite("Script approval explains its purpose")
struct ScriptApprovalReasonTests {
    @Test("Purpose reaches approval while the complete payload and explicit decision remain",
          arguments: ["run_applescript", "run_shell"])
    func purposeAndPayload(name: String) async throws {
        let tool: any IvyTool = name == "run_applescript" ? RunAppleScriptTool() : RunShellTool()
        let argument = name == "run_applescript" ? "script" : "command"
        let payload = name == "run_applescript" ? "tell application \"Safari\" to activate" : "open -a Safari"
        let request = OSAllocatedUnfairLock<ConfirmationRequest?>(initialState: nil)
        let gate = InteractiveSafetyGate(confirmationProvider: ClosureConfirmationProvider { card in
            request.withLock { $0 = card }
            return false
        })
        let call = FunctionCall(name: name, args: [argument: AnyCodable(payload),
            "reason": AnyCodable("  Open\n Safari\tto view the requested page  ")], id: "purpose-fixture")
        try tool.validate(arguments: call.args)
        let decision = await gate.evaluate(tool: tool, call: call)
        #expect(decision != .approve, "A displayed purpose cannot authorize a script")
        let card = try #require(request.withLock { $0 })
        #expect(card.callId == call.id && card.toolName == name)
        #expect(card.companionReason == "Open Safari to view the requested page")
        #expect(card.prompt.contains(card.companionReason))
        #expect(card.detail == payload)
        #expect(card.title == (name == "run_applescript" ? "AppleScript Execution" : "Run Shell Command"))
        #expect(tool.declaration.parameters?.required?.contains("reason") == true)
        #expect(tool.declaration.parameters?.properties["reason"]?.type == "STRING")
    }

    @Test("Older calls without a purpose retain full review and a neutral companion fallback",
          arguments: ["run_applescript", "run_shell"])
    func legacyFallback(name: String) async throws {
        let tool: any IvyTool = name == "run_applescript" ? RunAppleScriptTool() : RunShellTool()
        let argument = name == "run_applescript" ? "script" : "command"
        let payload = name == "run_applescript" ? "return 1" : "echo fixture"
        for reason: AnyCodable? in [nil, AnyCodable("\n\t "), AnyCodable(42)] {
            let captured = OSAllocatedUnfairLock<ConfirmationRequest?>(initialState: nil)
            let gate = InteractiveSafetyGate(confirmationProvider: ClosureConfirmationProvider { card in
                captured.withLock { $0 = card }; return false
            })
            var args = [argument: AnyCodable(payload)]
            args["reason"] = reason
            try tool.validate(arguments: args)
            #expect(await gate.evaluate(tool: tool, call: FunctionCall(name: name, args: args)) != .approve)
            let card = try #require(captured.withLock { $0 })
            #expect(card.reason == nil && card.detail == payload)
            #expect(card.companionReason == (name == "run_applescript" ? "Run the requested script" : "Run the requested command"))
        }
    }

    @Test("Purpose text is credential-redacted and never overrides non-script action metadata")
    func safeDisplayText() {
        let script = ConfirmationRequest(toolName: "run_applescript", title: "AppleScript Execution",
            prompt: "Review", detail: "return 1", reason: "Open Safari with token=fixture-secret-value")
        #expect(script.companionReason == "Open Safari with token=[REDACTED]")
        let calendar = ConfirmationRequest(toolName: "calendar_event", title: "Create Calendar Event",
            prompt: "Review", detail: "Fixture")
        #expect(calendar.companionReason == calendar.title)
        let custom = ConfirmationRequest(toolName: "run_shell", title: "Review project changes",
            prompt: "Review", detail: "Fixture")
        #expect(custom.companionReason == custom.title)
    }
}
