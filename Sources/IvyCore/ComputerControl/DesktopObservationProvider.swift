import Foundation
import CoreGraphics
import ApplicationServices
import os

/// Protocol abstracting accessibility tree traversal for testability and thread safety.
public protocol AccessibilityTreeTraversing: Sendable {
    func inspectWindow(
        pid: Int32,
        windowID: UInt32?,
        maxNodes: Int,
        maxDepth: Int
    ) async throws -> [UIElementSnapshot]
}

/// Errors occurring during desktop accessibility observation.
public enum DesktopObservationError: Error, LocalizedError, Equatable, Sendable {
    case accessibilityPermissionDenied
    case applicationNotFound(Int32)
    case windowNotFound
    case timeout
    case traversalFailed(String)
    case secureFieldEncountered

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionDenied:
            return "Accessibility permission is required to observe controls on screen."
        case .applicationNotFound(let pid):
            return "Application process \(pid) was not found."
        case .windowNotFound:
            return "No matching visible window was found for the target application."
        case .timeout:
            return "Accessibility tree inspection timed out."
        case .traversalFailed(let msg):
            return "Accessibility traversal failed: \(msg)"
        case .secureFieldEncountered:
            return "Protected or secure input field encountered; observation halted for privacy."
        }
    }
}

/// Protocol for capturing bounded desktop observations.
public protocol DesktopObservationProviding: Sendable {
    func observe(
        session: ComputerControlSession,
        scope: ComputerControlScope
    ) async throws -> DesktopObservation
}

/// Mock implementation of DesktopObservationProviding for hermetic unit testing.
public final class MockDesktopObservationProvider: DesktopObservationProviding, @unchecked Sendable {
    private struct State {
        var queuedObservations: [Result<DesktopObservation, Error>]
        var defaultElements: [UIElementSnapshot]
        var defaultVisualMetadata: ScreenshotMetadata?
        var observedCalls: [(sessionID: UUID, scope: ComputerControlScope)]
    }
    private let lock: OSAllocatedUnfairLock<State>

    public init(
        queuedObservations: [Result<DesktopObservation, Error>] = [],
        defaultElements: [UIElementSnapshot] = [],
        defaultVisualMetadata: ScreenshotMetadata? = nil
    ) {
        self.lock = OSAllocatedUnfairLock(initialState: State(
            queuedObservations: queuedObservations,
            defaultElements: defaultElements,
            defaultVisualMetadata: defaultVisualMetadata,
            observedCalls: []
        ))
    }

    public var observedCalls: [(sessionID: UUID, scope: ComputerControlScope)] {
        lock.withLock { $0.observedCalls }
    }

    public func setDefaultElements(_ elements: [UIElementSnapshot]) {
        lock.withLock { $0.defaultElements = elements }
    }

    public func setDefaultVisualMetadata(_ metadata: ScreenshotMetadata?) {
        lock.withLock { $0.defaultVisualMetadata = metadata }
    }

    public func enqueue(_ observation: DesktopObservation) {
        lock.withLock { $0.queuedObservations.append(.success(observation)) }
    }

    public func enqueueFailure(_ error: Error) {
        lock.withLock { $0.queuedObservations.append(.failure(error)) }
    }

    public func observe(session: ComputerControlSession, scope: ComputerControlScope) async throws -> DesktopObservation {
        let queued = lock.withLock { state -> Result<DesktopObservation, Error>? in
            state.observedCalls.append((sessionID: session.id, scope: scope))
            guard !state.queuedObservations.isEmpty else { return nil }
            return state.queuedObservations.removeFirst()
        }
        if let queued {
            return try queued.get()
        }
        let tokenResult = session.issueToken()
        let token: ObservationToken
        switch tokenResult {
        case .success(let t): token = t
        case .failure(let err): throw err
        }
        let (fallbackElements, fallbackMeta) = lock.withLock { ($0.defaultElements, $0.defaultVisualMetadata) }
        return DesktopObservation(
            sessionID: session.id,
            token: token,
            scope: scope,
            elements: fallbackElements,
            kind: fallbackMeta != nil ? .screenshotVisual : .accessibilityTree,
            visualMetadata: fallbackMeta
        )
    }
}

/// Coordinator capturing bounded, immutable accessibility snapshots for an authorized control scope.
public final class DesktopObservationProvider: DesktopObservationProviding, @unchecked Sendable {
    private let traverser: AccessibilityTreeTraversing
    private let maxNodes: Int
    private let maxDepth: Int
    private let timeout: TimeInterval

    public init(
        traverser: AccessibilityTreeTraversing,
        maxNodes: Int = 100,
        maxDepth: Int = 8,
        timeout: TimeInterval = 2.0
    ) {
        self.traverser = traverser
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.timeout = timeout
    }

    /// Captures a fresh observation of the scoped application window.
    public func observe(
        session: ComputerControlSession,
        scope: ComputerControlScope
    ) async throws -> DesktopObservation {
        guard case .active = session.state else {
            throw ComputerControlSessionError.sessionNotActive
        }
        guard scope.isAuthorized else {
            throw ComputerControlSessionError.unauthorizedScope
        }
        guard scope.isPermittedApp else {
            throw ComputerControlSessionError.prohibitedApplication(scope.bundleIdentifier)
        }
        guard let pid = scope.processIdentifier else {
            throw DesktopObservationError.applicationNotFound(0)
        }

        // Run traversal with timeout
        let elements: [UIElementSnapshot]
        do {
            elements = try await withThrowingTaskGroup(of: [UIElementSnapshot].self) { group in
                group.addTask {
                    try await self.traverser.inspectWindow(
                        pid: pid,
                        windowID: scope.windowID,
                        maxNodes: self.maxNodes,
                        maxDepth: self.maxDepth
                    )
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
                    throw DesktopObservationError.timeout
                }
                guard let first = try await group.next() else {
                    throw DesktopObservationError.traversalFailed("No result returned")
                }
                group.cancelAll()
                return first
            }
        } catch {
            if let obsErr = error as? DesktopObservationError {
                throw obsErr
            }
            throw DesktopObservationError.traversalFailed(error.localizedDescription)
        }

        let tokenResult = session.issueToken()
        guard case .success(let token) = tokenResult else {
            throw ComputerControlSessionError.sessionNotActive
        }

        return DesktopObservation(
            sessionID: session.id,
            token: token,
            scope: scope,
            elements: elements,
            screenshotID: nil,
            timestamp: Date()
        )
    }
}

/// Native macOS Accessibility tree traverser using ApplicationServices APIs.
public final class SystemAccessibilityTreeTraverser: AccessibilityTreeTraversing {
    public init() {}

    public func inspectWindow(
        pid: Int32,
        windowID: UInt32?,
        maxNodes: Int,
        maxDepth: Int
    ) async throws -> [UIElementSnapshot] {
        guard AXIsProcessTrusted() else {
            throw DesktopObservationError.accessibilityPermissionDenied
        }

        let appRef = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        let axError = AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue)
        guard axError == .success, let windows = windowsValue as? [AXUIElement], !windows.isEmpty else {
            throw DesktopObservationError.windowNotFound
        }

        // Use the first window or matching window
        let targetWindow = windows[0]
        var collected: [UIElementSnapshot] = []
        var nextID = 1

        try traverse(
            element: targetWindow,
            depth: 0,
            maxDepth: maxDepth,
            maxNodes: maxNodes,
            counter: &nextID,
            results: &collected
        )

        return collected
    }

    private func traverse(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        maxNodes: Int,
        counter: inout Int,
        results: inout [UIElementSnapshot]
    ) throws {
        guard depth <= maxDepth, results.count < maxNodes else { return }

        // Role check
        var roleValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        let role = (roleValue as? String) ?? "AXUnknown"

        // Sensitive field exclusion
        if role == "AXSecureTextField" {
            // Secure passwords and tokens must not be read or exposed
            return
        }

        // Title / Description
        var titleValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleValue) != .success {
            AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &titleValue)
        }
        let title = (titleValue as? String).map { SecretRedactor.redact($0) }

        // Value
        var valValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valValue)
        let value: String?
        if let s = valValue as? String {
            value = SecretRedactor.redact(s)
        } else if let n = valValue as? NSNumber {
            value = n.stringValue
        } else {
            value = nil
        }

        // Bounds / Frame
        var frame = CGRect.zero
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue) == .success,
           AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
           let posVal = posValue, let sizeVal = sizeValue {
            var point = CGPoint.zero
            var size = CGSize.zero
            if AXValueGetValue(posVal as! AXValue, .cgPoint, &point),
               AXValueGetValue(sizeVal as! AXValue, .cgSize, &size) {
                frame = CGRect(origin: point, size: size)
            }
        }

        // Enabled
        var enabledValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabledValue)
        let isEnabled = (enabledValue as? Bool) ?? true

        // Focused
        var focusedValue: AnyObject?
        AXUIElementCopyAttributeValue(element, kAXFocusedAttribute as CFString, &focusedValue)
        let isFocused = (focusedValue as? Bool) ?? false

        // Supported Action names
        var actionNames: CFArray?
        var actions: [String] = []
        if AXUIElementCopyActionNames(element, &actionNames) == .success, let names = actionNames as? [String] {
            actions = names
        }

        let elementID = "el_\(counter)"
        counter += 1

        let snapshot = UIElementSnapshot(
            id: elementID,
            role: role,
            title: title,
            value: value,
            frame: frame,
            isEnabled: isEnabled,
            isFocused: isFocused,
            actions: actions
        )
        results.append(snapshot)

        // Traverse children
        var childrenValue: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
           let children = childrenValue as? [AXUIElement] {
            for child in children {
                if results.count >= maxNodes { break }
                try traverse(
                    element: child,
                    depth: depth + 1,
                    maxDepth: maxDepth,
                    maxNodes: maxNodes,
                    counter: &counter,
                    results: &results
                )
            }
        }
    }
}

/// In-memory mock accessibility tree traverser for deterministic offline testing.
public final class MockAccessibilityTreeTraverser: AccessibilityTreeTraversing, @unchecked Sendable {
    public var shouldThrow: DesktopObservationError?
    public var delay: TimeInterval = 0
    public var mockElements: [UIElementSnapshot]

    public init(mockElements: [UIElementSnapshot] = []) {
        self.mockElements = mockElements
    }

    public func inspectWindow(
        pid: Int32,
        windowID: UInt32?,
        maxNodes: Int,
        maxDepth: Int
    ) async throws -> [UIElementSnapshot] {
        if delay > 0 {
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if let err = shouldThrow {
            throw err
        }
        return Array(mockElements.prefix(maxNodes))
    }
}
