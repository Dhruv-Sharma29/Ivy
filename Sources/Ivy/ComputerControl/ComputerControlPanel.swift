import SwiftUI
import AppKit
import IvyCore

// MARK: - Non-Activating Panels

/// Non-activating floating panel that hosts the computer control progress and controls.
public final class ComputerControlFloatingPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

/// Click-through overlay panel for visual target highlights. Never intercepts mouse events.
public final class TargetHighlightOverlayPanel: NSPanel {
    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    public init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

// MARK: - SwiftUI Views

/// Visual highlight indicating the current accessibility target or click point.
public struct TargetHighlightView: View {
    public let frameRect: CGRect?
    public let point: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(frameRect: CGRect? = nil, point: CGPoint? = nil) {
        self.frameRect = frameRect
        self.point = point
    }

    public var body: some View {
        ZStack {
            if let frameRect {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(IvyTheme.leaf, lineWidth: 2)
                    .background(IvyTheme.leaf.opacity(0.12))
                    .frame(width: max(frameRect.width, 24), height: max(frameRect.height, 24))
                    .position(x: frameRect.midX, y: frameRect.midY)
            } else if let point {
                Circle()
                    .stroke(IvyTheme.leaf, lineWidth: 2)
                    .background(Circle().fill(IvyTheme.leaf.opacity(0.2)))
                    .frame(width: 28, height: 28)
                    .position(x: point.x, y: point.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Compact non-activating control bar displaying current action, target app, step count, and Stop/Pause controls.
public struct ComputerControlPanelView: View {
    public let statusText: String
    public let targetAppName: String
    public let stepCount: Int
    public let maxSteps: Int
    public let isPaused: Bool
    public let pauseReason: ComputerControlPauseReason?
    public let onPause: () -> Void
    public let onResume: () -> Void
    public let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(
        statusText: String,
        targetAppName: String,
        stepCount: Int,
        maxSteps: Int = 20,
        isPaused: Bool,
        pauseReason: ComputerControlPauseReason? = nil,
        onPause: @escaping () -> Void,
        onResume: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.statusText = statusText
        self.targetAppName = targetAppName
        self.stepCount = stepCount
        self.maxSteps = maxSteps
        self.isPaused = isPaused
        self.pauseReason = pauseReason
        self.onPause = onPause
        self.onResume = onResume
        self.onStop = onStop
    }

    public var body: some View {
        HStack(spacing: 12) {
            // App badge & status
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(IvyTheme.leaf)
                    Text(targetAppName)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Step \(stepCount)/\(maxSteps)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }

                Text(statusDescription)
                    .font(.system(size: 12))
                    .foregroundStyle(isPaused ? IvyTheme.riskAmber : .primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Pause / Resume Button
            Button(action: isPaused ? onResume : onPause) {
                Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(isPaused ? "Resume Computer Control" : "Pause Computer Control")

            // Stop Button (Always labeled and accessible)
            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.borderedProminent)
            .tint(IvyTheme.dangerRed)
            .controlSize(.small)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityLabel("Stop Computer Control")
            .accessibilityHint("Cancels autonomous control immediately")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 320, maxWidth: 420)
        .ivyGlass(cornerRadius: 14)
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Computer Control Panel")
    }

    private var statusDescription: String {
        if isPaused {
            if let reason = pauseReason {
                return "Paused: \(reason.rawValue)"
            }
            return "Paused"
        }
        return statusText
    }
}

// MARK: - Controller

/// Coordinates presentation and positioning of the floating control panel and target highlights.
@MainActor
public final class ComputerControlPanelController: ObservableObject {
    @Published public private(set) var feedbackState: ComputerControlFeedbackState
    private let session: ComputerControlSession
    private let takeoverMonitor: PhysicalTakeoverMonitoring
    private var panelWindow: ComputerControlFloatingPanel?
    private var highlightWindow: TargetHighlightOverlayPanel?

    public init(
        session: ComputerControlSession,
        takeoverMonitor: PhysicalTakeoverMonitoring = SystemPhysicalTakeoverMonitor()
    ) {
        self.session = session
        self.takeoverMonitor = takeoverMonitor
        self.feedbackState = ComputerControlFeedbackState(
            statusText: "Initializing...",
            targetAppName: session.state.currentScope?.bundleIdentifier ?? "Application"
        )
    }

    deinit {
        // Safe background cleanup
    }

    /// Shows the control panel and starts physical takeover monitoring.
    public func show(initialStatus: String = "Starting control session...") {
        let appName = session.state.currentScope?.bundleIdentifier ?? "Application"
        feedbackState = ComputerControlFeedbackState(
            statusText: initialStatus,
            targetAppName: appName,
            stepCount: 1,
            maxSteps: 20,
            isPaused: false
        )

        let window = panelWindow ?? makePanelWindow()
        window.contentView = NSHostingView(rootView: makePanelRootView())
        positionPanel(window)
        window.orderFrontRegardless()

        // Start physical takeover monitoring
        takeoverMonitor.startMonitoring { [weak self] reason in
            Task { @MainActor [weak self] in
                self?.handleTakeover(reason: reason)
            }
        }
    }

    /// Updates status copy and target coordinates.
    public func update(status: String, targetFrame: CGRect? = nil, targetPoint: CGPoint? = nil, step: Int? = nil) {
        feedbackState.statusText = status
        if let targetFrame { feedbackState.targetFrame = targetFrame }
        if let targetPoint { feedbackState.targetPoint = targetPoint }
        if let step { feedbackState.stepCount = step }

        panelWindow?.contentView = NSHostingView(rootView: makePanelRootView())
        updateHighlightOverlay()
    }

    /// Pauses control and displays pause reason in the panel.
    public func pause(reason: ComputerControlPauseReason) {
        session.pause(reason: reason)
        feedbackState.isPaused = true
        feedbackState.pauseReason = reason
        panelWindow?.contentView = NSHostingView(rootView: makePanelRootView())
        hideHighlight()
    }

    /// Resumes control.
    public func resume() {
        let resumeResult = session.resume()
        if case .success = resumeResult {
            feedbackState.isPaused = false
            feedbackState.pauseReason = nil
            feedbackState.statusText = "Resumed control"
            panelWindow?.contentView = NSHostingView(rootView: makePanelRootView())
        }
    }

    /// Stops control and closes overlays.
    public func stop(reason: String = "User stopped") {
        takeoverMonitor.stopMonitoring()
        session.stop(reason: reason)
        hide()
    }

    /// Hides all windows.
    public func hide() {
        takeoverMonitor.stopMonitoring()
        hideHighlight()
        panelWindow?.orderOut(nil)
        panelWindow = nil
    }

    public func handleTakeover(reason: ComputerControlPauseReason) {
        pause(reason: reason)
    }

    private func makePanelRootView() -> some View {
        ComputerControlPanelView(
            statusText: feedbackState.statusText,
            targetAppName: feedbackState.targetAppName,
            stepCount: feedbackState.stepCount,
            maxSteps: feedbackState.maxSteps,
            isPaused: feedbackState.isPaused,
            pauseReason: feedbackState.pauseReason,
            onPause: { [weak self] in self?.pause(reason: .userRequested) },
            onResume: { [weak self] in self?.resume() },
            onStop: { [weak self] in self?.stop(reason: "Stopped from control panel") }
        )
    }

    private func makePanelWindow() -> ComputerControlFloatingPanel {
        let panel = ComputerControlFloatingPanel(contentRect: CGRect(x: 100, y: 100, width: 360, height: 60))
        panelWindow = panel
        return panel
    }

    private func positionPanel(_ window: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let visibleFrame = screen.visibleFrame
        let panelWidth: CGFloat = 380
        let panelHeight: CGFloat = 58
        // Position at top center of main display, comfortably below menu bar
        let x = visibleFrame.midX - (panelWidth / 2)
        let y = visibleFrame.maxY - panelHeight - 16
        window.setFrame(CGRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    private func updateHighlightOverlay() {
        guard feedbackState.targetFrame != nil || feedbackState.targetPoint != nil else {
            hideHighlight()
            return
        }
        guard let screen = NSScreen.main else { return }
        let window = highlightWindow ?? TargetHighlightOverlayPanel(contentRect: screen.frame)
        highlightWindow = window
        window.setFrame(screen.frame, display: false)
        window.contentView = NSHostingView(
            rootView: TargetHighlightView(frameRect: feedbackState.targetFrame, point: feedbackState.targetPoint)
        )
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    private func hideHighlight() {
        highlightWindow?.orderOut(nil)
        highlightWindow = nil
    }
}

extension ComputerControlPanelController: ComputerControlFeedbackManaging {
    public func updateStatus(_ status: String) {
        update(status: status)
    }

    public func updateTarget(element: UIElementSnapshot?, point: CGPoint?) {
        update(status: feedbackState.statusText, targetFrame: element?.frame, targetPoint: point)
    }

    public func clearTarget() {
        feedbackState.targetFrame = nil
        feedbackState.targetPoint = nil
        hideHighlight()
    }

    public func stop() {
        stop(reason: "Stopped from control panel")
    }
}
