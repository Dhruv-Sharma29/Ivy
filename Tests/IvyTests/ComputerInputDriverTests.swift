import Testing
import Foundation
import CoreGraphics
@testable import IvyCore

@Suite("Computer Input Driver Tests")
struct ComputerInputDriverTests {

    @Test("Denied permission never emits input")
    func deniedPermissionNeverEmitsInput() async throws {
        let driver = MockComputerInputDriver(isAuthorized: false)
        #expect(!driver.isAuthorized)

        // Click
        do {
            try await driver.click(at: CGPoint(x: 100, y: 100), button: .left, clickCount: 1)
            Issue.record("Expected permissionDenied error")
        } catch let error as ComputerInputError {
            #expect(error == .permissionDenied)
        }

        // Move
        do {
            try await driver.move(to: CGPoint(x: 50, y: 50))
            Issue.record("Expected permissionDenied error")
        } catch let error as ComputerInputError {
            #expect(error == .permissionDenied)
        }

        // Drag
        do {
            try await driver.drag(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 90, y: 90), button: .left)
            Issue.record("Expected permissionDenied error")
        } catch let error as ComputerInputError {
            #expect(error == .permissionDenied)
        }

        // Type
        do {
            try await driver.type(text: "Hello")
            Issue.record("Expected permissionDenied error")
        } catch let error as ComputerInputError {
            #expect(error == .permissionDenied)
        }

        // Key
        do {
            try await driver.pressKey(key: "return", modifiers: ["command"])
            Issue.record("Expected permissionDenied error")
        } catch let error as ComputerInputError {
            #expect(error == .permissionDenied)
        }

        // Scroll
        do {
            try await driver.scroll(at: nil, deltaX: 0, deltaY: 100)
            Issue.record("Expected permissionDenied error")
        } catch let error as ComputerInputError {
            #expect(error == .permissionDenied)
        }

        // Verify zero events were recorded
        #expect(driver.recordedEvents.isEmpty)
    }

    @Test("Click synthesizes move and click with correct count and button")
    func clickEventOrderAndButton() async throws {
        let driver = MockComputerInputDriver(isAuthorized: true)
        let target = CGPoint(x: 250, y: 400)

        try await driver.click(at: target, button: .left, clickCount: 1)
        #expect(driver.recordedEvents.count == 2)
        #expect(driver.recordedEvents[0] == .move(point: target))
        #expect(driver.recordedEvents[1] == .click(point: target, button: .left, clickCount: 1))

        driver.clearEvents()
        try await driver.click(at: target, button: .right, clickCount: 2)
        #expect(driver.recordedEvents.count == 2)
        #expect(driver.recordedEvents[0] == .move(point: target))
        #expect(driver.recordedEvents[1] == .click(point: target, button: .right, clickCount: 2))
    }

    @Test("Coordinate boundary validation rejects invalid points")
    func coordinateValidation() async throws {
        let driver = MockComputerInputDriver(isAuthorized: true)

        // Negative coordinates
        do {
            try await driver.move(to: CGPoint(x: -5, y: 100))
            Issue.record("Expected invalidCoordinates")
        } catch let error as ComputerInputError {
            guard case .invalidCoordinates = error else { Issue.record("Wrong error"); return }
        }

        // Out of bounds (> 20,000)
        do {
            try await driver.move(to: CGPoint(x: 25_000, y: 100))
            Issue.record("Expected invalidCoordinates")
        } catch let error as ComputerInputError {
            guard case .invalidCoordinates = error else { Issue.record("Wrong error"); return }
        }

        // NaN / Infinite
        do {
            try await driver.move(to: CGPoint(x: Double.nan, y: 100))
            Issue.record("Expected invalidCoordinates")
        } catch let error as ComputerInputError {
            guard case .invalidCoordinates = error else { Issue.record("Wrong error"); return }
        }
    }

    @Test("Drag guarantees mouse button release")
    func dragGuaranteesRelease() async throws {
        let driver = MockComputerInputDriver(isAuthorized: true)
        let start = CGPoint(x: 100, y: 100)
        let end = CGPoint(x: 300, y: 300)

        try await driver.drag(from: start, to: end, button: .left)
        #expect(!driver.isMouseDown)
        #expect(driver.recordedEvents.count == 2)
        #expect(driver.recordedEvents[0] == .move(point: start))
        #expect(driver.recordedEvents[1] == .drag(start: start, end: end, button: .left))
        #expect(driver.currentCursorPosition == end)
    }

    @Test("Typing text respects Unicode, null bytes, and length limits")
    func typingValidationAndExecution() async throws {
        let driver = MockComputerInputDriver(isAuthorized: true)

        // Valid unicode
        try await driver.type(text: "Swift 6 strict concurrency 🚀")
        #expect(driver.recordedEvents == [.type(text: "Swift 6 strict concurrency 🚀")])

        // Empty string
        do {
            try await driver.type(text: "")
            Issue.record("Expected empty text error")
        } catch let error as ComputerInputError {
            guard case .invalidArgument = error else { Issue.record("Wrong error"); return }
        }

        // Embedded null byte
        do {
            try await driver.type(text: "Hello\0World")
            Issue.record("Expected null byte error")
        } catch let error as ComputerInputError {
            guard case .invalidArgument = error else { Issue.record("Wrong error"); return }
        }

        // Exceeds max length (2000)
        let longString = String(repeating: "A", count: 2001)
        do {
            try await driver.type(text: longString)
            Issue.record("Expected textTooLong error")
        } catch let error as ComputerInputError {
            guard case .textTooLong(let count, let limit) = error else { Issue.record("Wrong error"); return }
            #expect(count == 2001)
            #expect(limit == 2000)
        }
    }

    @Test("Key press guarantees key release and rejects excessive combinations")
    func keyPressValidationAndRelease() async throws {
        let driver = MockComputerInputDriver(isAuthorized: true)

        // Valid key and modifier
        try await driver.pressKey(key: "return", modifiers: ["command"])
        #expect(driver.heldKeys.isEmpty)
        #expect(driver.recordedEvents == [.key(key: "return", modifiers: ["command"])])

        // Excessive modifiers (> 4)
        do {
            try await driver.pressKey(key: "a", modifiers: ["command", "shift", "option", "control", "fn"])
            Issue.record("Expected excessiveModifiers")
        } catch let error as ComputerInputError {
            guard case .excessiveModifiers(let mods) = error else { Issue.record("Wrong error"); return }
            #expect(mods.count == 5)
        }

        // Unsupported key
        do {
            try await driver.pressKey(key: "not_a_real_key_12345", modifiers: [])
            Issue.record("Expected unsupportedKey")
        } catch let error as ComputerInputError {
            guard case .unsupportedKey = error else { Issue.record("Wrong error"); return }
        }
    }

    @Test("Scroll delta validation and recording")
    func scrollValidation() async throws {
        let driver = MockComputerInputDriver(isAuthorized: true)

        try await driver.scroll(at: CGPoint(x: 100, y: 100), deltaX: 10, deltaY: -50)
        #expect(driver.recordedEvents == [.scroll(point: CGPoint(x: 100, y: 100), deltaX: 10, deltaY: -50)])

        // Excessive scroll delta (> 5000)
        do {
            try await driver.scroll(at: nil, deltaX: 6000, deltaY: 0)
            Issue.record("Expected invalid delta")
        } catch let error as ComputerInputError {
            guard case .invalidArgument = error else { Issue.record("Wrong error"); return }
        }
    }

    @Test("Emergency release cleans up all held inputs")
    func emergencyRelease() async throws {
        let driver = MockComputerInputDriver(isAuthorized: true)
        await driver.releaseAllHeldInputs()
        #expect(driver.recordedEvents == [.releaseAll])
        #expect(!driver.isMouseDown)
        #expect(driver.heldKeys.isEmpty)
    }

    @Test("SystemComputerInputDriver checks injected authorization")
    func systemDriverChecksAuthorization() async throws {
        let systemDriver = SystemComputerInputDriver(permissionChecker: { false })
        #expect(!systemDriver.isAuthorized)

        do {
            try await systemDriver.click(at: CGPoint(x: 100, y: 100), button: .left, clickCount: 1)
            Issue.record("Expected permissionDenied")
        } catch let error as ComputerInputError {
            #expect(error == .permissionDenied)
        }
    }
}
