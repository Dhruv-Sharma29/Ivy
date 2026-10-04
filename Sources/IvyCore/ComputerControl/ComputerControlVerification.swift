import Foundation
import CoreGraphics

/// Result of verifying the real-world outcome of an executed computer control action.
public enum ActionVerificationResult: Error, LocalizedError, Equatable, Sendable {
    /// Expected change was observed in the UI.
    case verified(explanation: String)
    /// UI state is demonstrably unchanged (safe to ask user to retry).
    case unchanged(explanation: String)
    /// Outcome is uncertain; state may have partially or asynchronously changed.
    case uncertain(explanation: String)
    /// Target element or window moved, closed, or became invalid.
    case targetInvalidated(reason: String)

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }

    public var errorDescription: String? {
        switch self {
        case .verified(let msg): return msg
        case .unchanged(let msg): return msg
        case .uncertain(let msg): return msg
        case .targetInvalidated(let msg): return msg
        }
    }
}

/// Helper classifying whether an action is irreversible or state-altering, prohibiting blind automatic retries.
public enum IrreversibleActionClassifier {
    private static let sensitiveKeyCodes: Set<String> = [
        "return", "enter", "space", "delete", "backspace", "escape"
    ]

    private static let sensitiveKeywords: Set<String> = [
        "submit", "send", "buy", "pay", "purchase", "delete", "remove",
        "confirm", "apply", "save", "order", "install", "publish", "post"
    ]

    /// Determines if an action carries irreversible side-effects that must never be auto-retried after uncertain timeouts.
    public static func isIrreversible(action: ComputerControlAction, targetElement: UIElementSnapshot?) -> Bool {
        switch action.kind {
        case .key:
            if let key = action.text?.lowercased(), sensitiveKeyCodes.contains(key) {
                return true
            }
            return false
        case .type:
            // Typing into a field alters document/field state
            return true
        case .click:
            if let title = targetElement?.title?.lowercased() {
                for kw in sensitiveKeywords {
                    if title.contains(kw) { return true }
                }
            }
            return false
        case .drag, .scroll, .move, .observe:
            return false
        }
    }
}

/// Verifies whether executed computer control actions produced their intended effects by comparing pre- and post-observations.
public enum ComputerActionVerifier {
    /// Maximum allowed displacement in points before a target is considered to have moved materially.
    public static let maxDisplacement: CGFloat = 10.0

    /// Verifies that a target element in the scoped window is still fresh and located at its approved position.
    public static func verifyTargetFreshness(
        elementID: String,
        original: DesktopObservation,
        fresh: DesktopObservation
    ) -> Result<UIElementSnapshot, ActionVerificationResult> {
        guard original.scope.bundleIdentifier == fresh.scope.bundleIdentifier else {
            return .failure(.targetInvalidated(reason: "Active application changed from '\(original.scope.bundleIdentifier)' to '\(fresh.scope.bundleIdentifier)'."))
        }

        guard let originalElement = original.elements.first(where: { $0.id == elementID }) else {
            return .failure(.targetInvalidated(reason: "Target element '\(elementID)' was missing in original observation."))
        }

        guard let freshElement = fresh.elements.first(where: { $0.id == elementID }) else {
            return .failure(.targetInvalidated(reason: "Target element '\(elementID)' no longer exists in current window."))
        }

        guard freshElement.isEnabled else {
            return .failure(.targetInvalidated(reason: "Target element '\(elementID)' has become disabled."))
        }

        let dx = abs(originalElement.frame.origin.x - freshElement.frame.origin.x)
        let dy = abs(originalElement.frame.origin.y - freshElement.frame.origin.y)
        if dx > maxDisplacement || dy > maxDisplacement {
            return .failure(.targetInvalidated(reason: "Target element '\(elementID)' moved materially by (\(Int(dx)), \(Int(dy))) points."))
        }

        return .success(freshElement)
    }

    /// Verifies the observed change between pre- and post-action observations.
    public static func verifyActionOutcome(
        action: ComputerControlAction,
        targetElement: UIElementSnapshot?,
        preObservation: DesktopObservation,
        postObservation: DesktopObservation
    ) -> ActionVerificationResult {
        // 1. Verify app and window stability
        if preObservation.scope.bundleIdentifier != postObservation.scope.bundleIdentifier {
            return .targetInvalidated(reason: "Focused app changed from \(preObservation.scope.bundleIdentifier) to \(postObservation.scope.bundleIdentifier).")
        }

        switch action.kind {
        case .observe:
            return .verified(explanation: "Observation refreshed with \(postObservation.elements.count) elements.")

        case .type:
            guard let expectedText = action.text else {
                return .uncertain(explanation: "No text specified for verification.")
            }
            // Check if any element in postObservation now has or contains the typed text
            if let target = targetElement {
                if let postTarget = postObservation.elements.first(where: { $0.id == target.id }) {
                    if let val = postTarget.value, val.contains(expectedText) {
                        return .verified(explanation: "Target field '\(target.id)' contains expected text.")
                    }
                    if postTarget.value == target.value {
                        return .unchanged(explanation: "Target field '\(target.id)' value did not change after typing.")
                    }
                }
            }
            // Check if any focused field in postObservation contains expected text
            if let focused = postObservation.elements.first(where: { $0.isFocused }),
               let val = focused.value, val.contains(expectedText) {
                return .verified(explanation: "Focused element '\(focused.id)' contains expected text.")
            }
            // If the element count or values changed, but exact text couldn't be confirmed (e.g. custom canvas), flag as uncertain
            return .uncertain(explanation: "Text insertion reported success, but resulting field content could not be confirmed via accessibility.")

        case .click:
            // Check if elements changed or dialog appeared
            let preCount = preObservation.elements.count
            let postCount = postObservation.elements.count
            if preCount != postCount {
                return .verified(explanation: "UI element hierarchy updated (\(preCount) -> \(postCount) elements).")
            }
            // Check if target element changed its enabled, value or focused state
            if let target = targetElement, let postTarget = postObservation.elements.first(where: { $0.id == target.id }) {
                if postTarget.value != target.value || postTarget.isEnabled != target.isEnabled || postTarget.isFocused != target.isFocused {
                    return .verified(explanation: "Target control state transitioned.")
                }
            }
            // If UI elements are identical, action might have had an external effect or no effect
            return .uncertain(explanation: "Click event post succeeded, but accessibility hierarchy reflects no visible state transition.")

        case .key:
            return .verified(explanation: "Key event posted successfully.")

        case .scroll:
            return .verified(explanation: "Scroll deltas posted successfully.")

        case .move:
            return .verified(explanation: "Pointer move posted successfully.")

        case .drag:
            return .verified(explanation: "Drag path executed and mouse released.")
        }
    }
}
