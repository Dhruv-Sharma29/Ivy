import AppKit
import SwiftUI
import IvyCore

/// The introduction window: opens by itself only on a fresh install, and from Settings › General.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static var shared: OnboardingWindowController?

    private let model: OnboardingModel
    private var window: NSWindow?

    init(model: OnboardingModel) {
        self.model = model
    }

    func show() {
        let window = self.window ?? makeWindow()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close() {
        window?.close()
    }

    /// Closing early counts as skipping the rest; nothing that wasn't chosen gets turned on.
    func windowWillClose(_ notification: Notification) {
        model.finish()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 460),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Welcome to Ivy"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: OnboardingView(model: model) { [weak self] in self?.close() })
        window.delegate = self
        self.window = window
        return window
    }
}

struct OnboardingView: View {
    @ObservedObject var model: OnboardingModel
    let onClose: () -> Void
    @State private var geminiDraft = ""
    @State private var elevenDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ProgressView(value: model.progress)
                .tint(IvyTheme.leaf)
                .accessibilityLabel("Step \(model.step.rawValue + 1) of \(OnboardingModel.Step.allCases.count)")
            Text(model.step.title).font(.system(size: 22, weight: .bold, design: .rounded))
            content
            Spacer(minLength: 0)
            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            controls
        }
        .padding(28)
        .frame(width: 520, height: 460)
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .nameTag:
            nameTag
            Text("And you are…? (Optional. I'll use it; I won't store anything else about you.)")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            TextField("Your name", text: $model.name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.next)
        case .personality:
            Picker("Sass", selection: $model.sass) {
                Text("Polite").tag(0)
                Text("Light").tag(1)
                Text("Ivy").tag(2)
                Text("Roast").tag(3)
            }
            .pickerStyle(.segmented)
            Text("\u{201C}\(OnboardingModel.sampleLine(sass: model.sass))\u{201D}")
                .font(.system(size: 15, design: .rounded))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: IvyTheme.cardRadius).fill(IvyTheme.sprout))
            Text("Change it any time in Settings › Personalization. It changes how I talk, never what I'm allowed to do.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        case .keys:
            Text("Paste a Gemini API key (required) and, if you want me to read replies aloud, an ElevenLabs key. They go straight to the macOS Keychain and are never shown again.")
                .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            keyRow("Gemini API key", key: .geminiAPIKey, draft: $geminiDraft)
            keyRow("ElevenLabs API key (optional)", key: .elevenLabsAPIKey, draft: $elevenDraft)
        case .voice:
            Text("Hold \u{2318}\u{21E7}Space anywhere and talk; let go when you're done. Or press the mic in my window.")
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Text("For that I need the microphone. macOS will ask you next; I only listen while you hold the keys or a voice session is open.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Allow Microphone…") { Task { await model.requestMicrophone() } }
                    .disabled(model.microphone == .authorized)
                Text(microphoneText).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .superpowers:
            Text("All off unless you switch them on. Each says what it does and what it never does.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            superpower("\u{201C}Hey Ivy\u{201D} wake word", detail: "Keeps the mic open with on-device recognition only; nothing leaves your Mac until you say \u{201C}Hey Ivy\u{201D}.",
                       isOn: model.wakeWordEnabled, set: model.setWakeWord)
            superpower("Screen help \u{2303}\u{2325}\u{2318}S", detail: "Shows me your front window only when you press it. Screenshots are never saved.",
                       isOn: model.screenHelpEnabled, set: model.setScreenHelp)
            superpower("Proactive nudges", detail: "Reminders and heads-ups you ask for. I can notify; I can never act on my own.",
                       isOn: model.proactiveEnabled, set: model.setProactive)
        case .done:
            Text("I live in your menu bar (the leaf). Open my window with \u{2318}O from there, or \u{2303}\u{2325}\u{2318}K for a quick question. Risky actions always ask you first.")
                .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var nameTag: some View {
        VStack(spacing: 0) {
            Text("HELLO").font(.system(size: 22, weight: .heavy)).foregroundStyle(.white)
            Text("my name is").font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            Text("Ivy")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(nsColor: .textBackgroundColor))
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .padding(.top, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(IvyTheme.moss))
        .frame(width: 240)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hello, my name is Ivy")
    }

    private var microphoneText: String {
        switch model.microphone {
        case .authorized: return "Allowed."
        case .denied, .restricted: return "Not allowed. You can change that in System Settings later."
        case .notDetermined: return "Not asked yet."
        case .unsupported: return "Not available here."
        }
    }

    private func keyRow(_ title: String, key: CredentialKey, draft: Binding<String>) -> some View {
        HStack {
            SecureField(title, text: draft)
                .textFieldStyle(.roundedBorder)
            Button("Save") {
                if model.saveKey(draft.wrappedValue, for: key) { draft.wrappedValue = "" }
            }
            .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if model.source(for: key).isUsable {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(IvyTheme.leaf).accessibilityLabel("Saved")
            }
        }
    }

    private func superpower(_ title: String, detail: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
    }

    private var controls: some View {
        HStack {
            if model.step != .nameTag, model.step != .done {
                Button("Back", action: model.back)
            }
            Spacer()
            if model.step == .done {
                Button("Start") {
                    model.finish()
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(IvyTheme.leaf)
            } else {
                Button("Skip", action: model.skip)
                Button("Continue", action: model.next)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(IvyTheme.leaf)
            }
        }
    }
}
