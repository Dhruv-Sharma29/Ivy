import AppKit
import SwiftUI
import IvyCore

/// A borderless panel that can take keyboard focus without activating Ivy (like Spotlight).
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CommandBarController: NSObject, NSWindowDelegate {
    private let environment: IvyAppEnvironment
    private var panel: NSPanel?

    init(environment: IvyAppEnvironment) {
        self.environment = environment
    }

    func toggle() {
        if let panel, panel.isVisible { close() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        if let screen = NSScreen.main {
            let size = panel.frame.size
            let frame = screen.visibleFrame
            panel.setFrameOrigin(CGPoint(x: frame.midX - size.width / 2, y: frame.minY + frame.height * 0.62))
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    /// Clicking elsewhere closes the bar.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: CGRect(x: 0, y: 0, width: 560, height: 320),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let e = environment
        panel.contentView = NSHostingView(rootView: CommandBarView(
            brain: e.brain, library: e.library, tasks: e.tasks,
            onClose: { [weak self] in self?.close() },
            onContinueInWindow: { [weak self] in
                self?.close()
                MainWindowController.shared?.show()
            }))
        self.panel = panel
        return panel
    }
}

/// Type a request, Return to ask (the reply appears here), ⌘Return to continue in the window, Esc to close.
/// It's an ordinary chat message: risky tools still raise their card (shown in the window).
private struct CommandBarView: View {
    @ObservedObject var brain: IvyBrain
    @ObservedObject var library: ConversationLibrary
    @ObservedObject var tasks: TaskEngine
    let onClose: () -> Void
    let onContinueInWindow: () -> Void

    @State private var text = ""
    @State private var askedID: UUID?
    @FocusState private var focused: Bool

    private var reply: ChatMessage? {
        guard let askedID, let index = brain.messages.firstIndex(where: { $0.id == askedID }) else { return nil }
        return brain.messages[(index + 1)...].first { $0.role == .model }
    }

    private var blocked: String? {
        if brain.pendingConfirmation != nil { return "Ivy is waiting for your approval in its window." }
        if tasks.run?.isActive == true { return "A task is running. Watch it in Ivy's window." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: IvyLogoImage.template)
                    .renderingMode(.template)
                    .resizable()
                    .frame(width: 20, height: 20)
                    .foregroundStyle(IvyTheme.leaf)
                    .accessibilityHidden(true)
                TextField("Ask Ivy…", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18))
                    .focused($focused)
                    .onSubmit(ask)
                if brain.isThinking { ProgressView().controlSize(.small) }
            }

            if let blocked {
                HStack {
                    Text(blocked).font(.system(size: 12)).foregroundStyle(.orange)
                    Spacer()
                    Button("Open Ivy", action: onContinueInWindow)
                }
            } else if let reply {
                ScrollView {
                    MessageBlocksView(text: reply.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                HStack {
                    Spacer()
                    Button("Continue in Window", action: onContinueInWindow).keyboardShortcut(.return, modifiers: [.command])
                }
            } else if askedID == nil, !brain.isThinking {
                let recent = Array(library.list().prefix(5))
                if !recent.isEmpty {
                    Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    ForEach(recent) { entry in
                        Button {
                            library.open(entry.id)
                            onContinueInWindow()
                        } label: {
                            HStack {
                                Text(entry.title).font(.system(size: 13)).lineLimit(1)
                                Spacer()
                                Text(entry.updatedAt.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 560, alignment: .topLeading)
        .ivyGlass(cornerRadius: 16)
        .ivyGlassButtonStyle()
        .onAppear {
            focused = true
            library.refresh()
        }
        .onExitCommand(perform: onClose)
    }

    private func ask() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, blocked == nil, !brain.isThinking else { return }
        if trimmed.lowercased().hasPrefix("/agent ") {
            text = ""
            onContinueInWindow()
            Task { await tasks.start(goal: String(trimmed.dropFirst("/agent ".count))) }
            return
        }
        text = ""
        Task {
            await brain.send(trimmed)
            // The new user message is the last one sent with this text.
            askedID = brain.messages.last { $0.role == .user }?.id
        }
    }
}
