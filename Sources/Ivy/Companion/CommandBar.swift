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
    private let session: CommandBarSession

    init(environment: IvyAppEnvironment) {
        self.environment = environment
        session = CommandBarSession(brain: environment.brain, tray: environment.attachments, tasks: environment.tasks, live: environment.liveCoordinator)
    }

    func showScreenQuestion(_ attachment: ImageAttachment) {
        session.prepareScreenQuestion(attachment)
        show()
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
        let panel = KeyablePanel(contentRect: CGRect(x: 0, y: 0, width: 560, height: 220),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let e = environment
        panel.contentView = NSHostingView(rootView: CommandBarView(
            brain: e.brain, library: e.library, tasks: e.tasks, tray: e.attachments, live: e.liveCoordinator,
            session: session,
            onClose: { [weak self] in self?.close() },
            onContinueInWindow: { [weak self] in
                self?.close()
                MainWindowController.shared?.show()
            }, onContentHeight: { [weak self] height in self?.fitContent(height) }))
        self.panel = panel
        return panel
    }

    private func fitContent(_ height: CGFloat) {
        guard let panel else { return }
        let limit = (panel.screen?.visibleFrame.height ?? 600) - 24
        let frame = Self.fittedFrame(panel.frame, contentHeight: height, maximumHeight: limit)
        if abs(frame.height - panel.frame.height) > 1 { panel.setFrame(frame, display: true) }
    }

    /// Keep the top edge stable when attachments and replies make the bar taller.
    static func fittedFrame(_ frame: CGRect, contentHeight: CGFloat, maximumHeight: CGFloat) -> CGRect {
        guard contentHeight.isFinite, contentHeight > 0, maximumHeight.isFinite, maximumHeight >= 120 else { return frame }
        let height = min(maximumHeight, max(120, contentHeight.rounded(.up)))
        return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }
}

/// Type a request, Return to ask (the reply appears here), ⌘Return to continue in the window, Esc to close.
/// It's an ordinary chat message: risky tools still raise their card (shown in the window).
struct CommandBarView: View {
    @ObservedObject var brain: IvyBrain
    @ObservedObject var library: ConversationLibrary
    @ObservedObject var tasks: TaskEngine
    @ObservedObject var tray: AttachmentTray
    @ObservedObject var live: GeminiLiveVoiceCoordinator
    @ObservedObject var session: CommandBarSession
    let onClose: () -> Void
    let onContinueInWindow: () -> Void
    var onContentHeight: (CGFloat) -> Void = { _ in }

    @FocusState private var focused: Bool

    private var reply: ChatMessage? {
        guard let askedID = session.askedID, let index = brain.messages.firstIndex(where: { $0.id == askedID }) else { return nil }
        return brain.messages[(index + 1)...].first { $0.role == .model }
    }

    private var blocked: String? {
        session.blocked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                IvyAppIconView().frame(width: 24, height: 24)
                Text("Ivy").font(.headline)
                Text("Quick chat").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: onContinueInWindow) { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 28, height: 28) }
                    .help("Open Ivy").accessibilityLabel("Open Ivy")
                    .accessibilityIdentifier("ivy.commandBar.open")
                Button(action: onClose) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                    .help("Close (Esc)").accessibilityLabel("Close quick chat")
                    .accessibilityIdentifier("ivy.commandBar.close")
            }
            .buttonStyle(IvyNavigationButtonStyle())
            HStack(spacing: 10) {
                TextField("Ask Ivy…", text: $session.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .focused($focused)
                    .onSubmit(ask)
                    .accessibilityLabel("Message Ivy")
                Button {
                    Task { await session.captureFrontWindow() }
                } label: { Image(systemName: "rectangle.dashed.badge.record") }
                .frame(minWidth: 28, minHeight: 28)
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .help("Attach front window (⌘⇧S)")
                .accessibilityLabel("Attach front window")
                .accessibilityIdentifier("ivy.commandBar.screen")
                .disabled(brain.isThinking || blocked != nil)
                Button(action: ask) {
                    Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                }
                .ivyGlassButtonStyle(prominent: true)
                .buttonBorderShape(.circle)
                .help("Send request (Return)").accessibilityLabel("Send request")
                .accessibilityIdentifier("ivy.commandBar.send")
                .disabled(brain.isThinking || blocked != nil || (session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && tray.attachments.isEmpty))
            }
            .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 8)
            .frame(minHeight: 52)
            .ivyGlass(cornerRadius: 26)

            AttachmentBar(tray: tray)
            if let id = session.screenQuestionID, let attachment = tray.attachments.first(where: { $0.id == id }),
               let bytes = attachment.jpeg.first, let image = NSImage(data: bytes) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 180)
                    .accessibilityLabel("Selected screen area preview")
                Text("Selected bounds · review the crop, then edit your question and send. Not saved.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if brain.isThinking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Working on your request…").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if let blocked {
                HStack(alignment: .top, spacing: 12) {
                    Label(blocked, systemImage: "info.circle").font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Open Ivy", action: onContinueInWindow)
                }
            } else if let reply {
                ScrollView {
                    MessageBlocksView(text: reply.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 180)
                HStack {
                    Spacer()
                    Button("Continue in Window", action: onContinueInWindow).keyboardShortcut(.return, modifiers: [.command])
                }
            } else if session.askedID == nil, !brain.isThinking {
                HStack(spacing: 8) {
                    ForEach([HomeShortcut.browse, .explain, .plan]) { shortcut in
                        Button { session.text = shortcut.prompt; focused = true } label: {
                            Label(shortcut.rawValue, systemImage: shortcut.symbol).font(.caption)
                        }
                        .help("Draft a \(shortcut.rawValue.lowercased()) request")
                        .accessibilityHint("Fills the draft without sending")
                    }
                }
                let recent = Array(library.list(.active).prefix(3))
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
                        .buttonStyle(IvyNavigationButtonStyle())
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 560, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .ivyGlass(cornerRadius: IvyTheme.cardRadius)
        .ivyGlassButtonStyle()
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onContentHeight($0) }
        .onAppear {
            focused = true
            library.refresh()
        }
        .onExitCommand(perform: onClose)
    }

    private func ask() {
        let plansTask = session.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("/agent ")
        Task {
            if await session.send(), plansTask { onContinueInWindow() }
        }
    }
}
