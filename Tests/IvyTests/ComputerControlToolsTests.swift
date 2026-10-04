import Testing
import Foundation
import CoreGraphics
import os
@testable import IvyCore

@Suite("Computer Control Tools Tests")
struct ComputerControlToolsTests {

    private func makeSession(authorized: Bool = true) -> (ComputerControlSession, ObservationToken) {
        let session = ComputerControlSession()
        let scope = ComputerControlScope(
            bundleIdentifier: "com.apple.TextEdit",
            processIdentifier: 1234,
            isAuthorized: authorized
        )
        let tokenResult = session.start(goal: "Edit document", scope: scope)
        guard case .success(let token) = tokenResult else {
            fatalError("Failed to start session in test helper")
        }
        return (session, token)
    }

    @Test("UIClickTool validates coordinates and executes through driver")
    func clickToolExecution() async throws {
        let (session, _) = makeSession()
        let driver = MockComputerInputDriver(isAuthorized: true)
        let tool = UIClickTool(session: session, driver: driver)

        // Missing args
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [:])
        }

        // Invalid click count
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: ["x": AnyCodable(100), "y": AnyCodable(100), "click_count": AnyCodable(5)])
        }

        // Valid execution
        let result = try await tool.execute(arguments: [
            "x": AnyCodable(150),
            "y": AnyCodable(300),
            "button": AnyCodable("left"),
            "click_count": AnyCodable(1)
        ])
        #expect(!result.isError)
        #expect(result.output.contains("Clicked at (150, 300)"))
        #expect(driver.recordedEvents.count == 2)
        #expect(driver.recordedEvents[1] == .click(point: CGPoint(x: 150, y: 300), button: .left, clickCount: 1))

        // Tool confirmation card
        let confirmation = tool.confirmation(for: ["x": AnyCodable(150), "y": AnyCodable(300)])
        #expect(confirmation != nil)
        #expect(confirmation?.title == "Mouse Click")
        #expect(confirmation?.detail.contains("com.apple.TextEdit") == true)
    }

    @Test("UITypeTool executes text typing and checks length limits")
    func typeToolExecution() async throws {
        let (session, _) = makeSession()
        let driver = MockComputerInputDriver(isAuthorized: true)
        let tool = UITypeTool(session: session, driver: driver)

        // Missing text
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [:])
        }

        // Valid type
        let result = try await tool.execute(arguments: ["text": AnyCodable("Hello, World!")])
        #expect(!result.isError)
        #expect(result.output.contains("Typed 13 characters"))
        #expect(driver.recordedEvents == [.type(text: "Hello, World!")])

        // Confirmation card
        let confirmation = tool.confirmation(for: ["text": AnyCodable("Hello, World!")])
        #expect(confirmation?.title == "Type Text")
        #expect(confirmation?.detail.contains("13 characters") == true)
    }

    @Test("UIKeyTool validates keys and modifiers")
    func keyToolExecution() async throws {
        let (session, _) = makeSession()
        let driver = MockComputerInputDriver(isAuthorized: true)
        let tool = UIKeyTool(session: session, driver: driver)

        // Missing key
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [:])
        }

        // Valid key combo
        let result = try await tool.execute(arguments: [
            "key": AnyCodable("s"),
            "modifiers": AnyCodable([AnyCodable("command")])
        ])
        #expect(!result.isError)
        #expect(result.output.contains("Pressed key combination 'command + s'"))
        #expect(driver.recordedEvents == [.key(key: "s", modifiers: ["command"])])

        // Confirmation card
        let confirmation = tool.confirmation(for: [
            "key": AnyCodable("s"),
            "modifiers": AnyCodable([AnyCodable("command")])
        ])
        #expect(confirmation?.title == "Press Key")
        #expect(confirmation?.prompt.contains("command + s") == true)
    }

    @Test("UIScrollTool validates deltas and executes scroll")
    func scrollToolExecution() async throws {
        let (session, _) = makeSession()
        let driver = MockComputerInputDriver(isAuthorized: true)
        let tool = UIScrollTool(session: session, driver: driver)

        // Missing delta_y
        #expect(throws: ToolError.self) {
            try tool.validate(arguments: [:])
        }

        // Valid scroll
        let result = try await tool.execute(arguments: [
            "delta_y": AnyCodable(-120),
            "delta_x": AnyCodable(0),
            "x": AnyCodable(200),
            "y": AnyCodable(200)
        ])
        #expect(!result.isError)
        #expect(driver.recordedEvents == [.scroll(point: CGPoint(x: 200, y: 200), deltaX: 0, deltaY: -120)])
    }

    @Test("UIMoveTool and UIDragTool execute cursor motions")
    func moveAndDragToolsExecution() async throws {
        let (session, _) = makeSession()
        let driver = MockComputerInputDriver(isAuthorized: true)
        let moveTool = UIMoveTool(session: session, driver: driver)
        let dragTool = UIDragTool(session: session, driver: driver)

        // Move
        let moveResult = try await moveTool.execute(arguments: ["x": AnyCodable(400), "y": AnyCodable(500)])
        #expect(!moveResult.isError)
        #expect(driver.recordedEvents == [.move(point: CGPoint(x: 400, y: 500))])

        driver.clearEvents()

        // Drag
        let dragResult = try await dragTool.execute(arguments: [
            "start_x": AnyCodable(100),
            "start_y": AnyCodable(100),
            "end_x": AnyCodable(500),
            "end_y": AnyCodable(500)
        ])
        #expect(!dragResult.isError)
        #expect(driver.recordedEvents.count == 2)
        #expect(driver.recordedEvents[0] == .move(point: CGPoint(x: 100, y: 100)))
        #expect(driver.recordedEvents[1] == .drag(start: CGPoint(x: 100, y: 100), end: CGPoint(x: 500, y: 500), button: .left))
    }

    @Test("Inactive or stopped session rejects tool execution")
    func inactiveSessionRejectsTools() async throws {
        let (session, _) = makeSession()
        session.stop(reason: "User cancelled")
        #expect(!session.state.isActive)

        let driver = MockComputerInputDriver(isAuthorized: true)
        let tool = UIClickTool(session: session, driver: driver)

        let result = try await tool.execute(arguments: ["x": AnyCodable(100), "y": AnyCodable(100)])
        #expect(result.isError)
        #expect(result.output.contains("session is not active"))
        #expect(driver.recordedEvents.isEmpty)
    }

    @Test("SafetyGate intercepts computer control tools for user confirmation")
    func safetyGateIntegration() async throws {
        let (session, _) = makeSession()
        let driver = MockComputerInputDriver(isAuthorized: true)
        let clickTool = UIClickTool(session: session, driver: driver)

        let capturedRequest = OSAllocatedUnfairLock<ConfirmationRequest?>(initialState: nil)
        let confirmationProvider = ClosureConfirmationProvider { request in
            capturedRequest.withLock { $0 = request }
            return true // Approve
        }
        let gate = InteractiveSafetyGate(confirmationProvider: confirmationProvider)

        let call = FunctionCall(name: "ui_click", args: ["x": AnyCodable(120), "y": AnyCodable(240)], id: "call_1")
        let decision = await gate.evaluate(tool: clickTool, call: call)

        #expect(decision == .approve)
        let requested = capturedRequest.withLock { $0 }
        #expect(requested != nil)
        #expect(requested?.title == "Mouse Click")
        #expect(requested?.prompt.contains("com.apple.TextEdit") == true)
    }

    @Test("SafetyGate rejection prevents tool execution")
    func safetyGateRejection() async throws {
        let (session, _) = makeSession()
        let driver = MockComputerInputDriver(isAuthorized: true)
        let clickTool = UIClickTool(session: session, driver: driver)

        let confirmationProvider = ClosureConfirmationProvider { _ in false } // Cancel
        let gate = InteractiveSafetyGate(confirmationProvider: confirmationProvider)

        let call = FunctionCall(name: "ui_click", args: ["x": AnyCodable(50), "y": AnyCodable(50)], id: "call_2")
        let decision = await gate.evaluate(tool: clickTool, call: call)

        guard case .reject(let reason) = decision else {
            Issue.record("Expected safety gate rejection")
            return
        }
        #expect(reason.contains("User cancelled"))
        #expect(driver.recordedEvents.isEmpty)
    }

    @Test("ComputerControlTools factory instantiates all 7 primitives")
    func factoryInstantiatesAllTools() {
        let (session, _) = makeSession()
        let driver = MockComputerInputDriver()
        let tools = ComputerControlTools.all(session: session, driver: driver)

        #expect(tools.count == 7)
        let names = Set(tools.map(\.name))
        let expected: Set<String> = ["ui_click", "ui_type", "ui_key", "ui_scroll", "ui_move", "ui_drag", "ui_observe"]
        #expect(names == expected)

        // Check required permissions
        for tool in tools {
            #expect(tool.requiredPermissions(for: [:]) == [.accessibility])
        }
    }
}
