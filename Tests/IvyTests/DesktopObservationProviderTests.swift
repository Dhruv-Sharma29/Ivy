import Testing
import Foundation
import CoreGraphics
@testable import IvyCore

@Suite("Phase 19.2 - Desktop Accessibility Observation Tests")
struct DesktopObservationProviderTests {

    @Test("Observation requires active session and authorized scope")
    func observePrerequisites() async throws {
        let traverser = MockAccessibilityTreeTraverser()
        let provider = DesktopObservationProvider(traverser: traverser)
        let session = ComputerControlSession()
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 1234, isAuthorized: false)

        await #expect(throws: ComputerControlSessionError.sessionNotActive) {
            try await provider.observe(session: session, scope: scope)
        }

        _ = session.start(goal: "Edit file", scope: ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 1234, isAuthorized: true))

        await #expect(throws: ComputerControlSessionError.unauthorizedScope) {
            try await provider.observe(session: session, scope: scope)
        }
    }

    @Test("Observation prohibits sensitive apps")
    func observeProhibitsSensitiveApps() async throws {
        let traverser = MockAccessibilityTreeTraverser()
        let provider = DesktopObservationProvider(traverser: traverser)
        let session = ComputerControlSession()
        let sensitive = ComputerControlScope(bundleIdentifier: "com.apple.Keychain-Access", processIdentifier: 555, isAuthorized: true)

        // Session start itself refuses, and observation check confirms refusal
        _ = session.start(goal: "Test", scope: ComputerControlScope(bundleIdentifier: "com.apple.calculator", processIdentifier: 123, isAuthorized: true))

        await #expect(throws: ComputerControlSessionError.prohibitedApplication("com.apple.Keychain-Access")) {
            try await provider.observe(session: session, scope: sensitive)
        }
    }

    @Test("Observation captures bounded elements and generates valid token")
    func observeCapturesElements() async throws {
        let mockElements = (1...20).map { i in
            UIElementSnapshot(
                id: "el_\(i)",
                role: i == 1 ? "AXWindow" : "AXButton",
                title: "Button \(i)",
                frame: CGRect(x: i * 10, y: i * 10, width: 50, height: 25)
            )
        }
        let traverser = MockAccessibilityTreeTraverser(mockElements: mockElements)
        let provider = DesktopObservationProvider(traverser: traverser, maxNodes: 5)
        let session = ComputerControlSession()
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.calculator", processIdentifier: 999, isAuthorized: true)

        guard case .success = session.start(goal: "Calc", scope: scope) else {
            Issue.record("Failed to start session")
            return
        }

        let observation = try await provider.observe(session: session, scope: scope)

        #expect(observation.sessionID == session.id)
        #expect(observation.elements.count == 5)
        #expect(observation.elements.first?.id == "el_1")
        #expect(observation.token.revision == 2) // Start issued rev 1; observe issued rev 2
        #expect(observation.token.isValid(for: session.id))
    }

    @Test("Observation times out when traversal hangs")
    func observeTimesOut() async throws {
        let traverser = MockAccessibilityTreeTraverser()
        traverser.delay = 0.5
        let provider = DesktopObservationProvider(traverser: traverser, timeout: 0.05)
        let session = ComputerControlSession()
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 101, isAuthorized: true)

        _ = session.start(goal: "Test", scope: scope)

        await #expect(throws: DesktopObservationError.timeout) {
            try await provider.observe(session: session, scope: scope)
        }
    }

    @Test("Accessibility permission denial is reported as user-actionable error")
    func accessibilityPermissionDenied() async throws {
        let traverser = MockAccessibilityTreeTraverser()
        traverser.shouldThrow = .accessibilityPermissionDenied
        let provider = DesktopObservationProvider(traverser: traverser)
        let session = ComputerControlSession()
        let scope = ComputerControlScope(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 202, isAuthorized: true)

        _ = session.start(goal: "Test", scope: scope)

        await #expect(throws: DesktopObservationError.accessibilityPermissionDenied) {
            try await provider.observe(session: session, scope: scope)
        }
    }
}
