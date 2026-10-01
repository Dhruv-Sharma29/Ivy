import SwiftUI
import UniformTypeIdentifiers
import IvyCore

/// Settings › Personalization: personality, answer length, about me, favourite apps, custom instructions,
/// shortcuts, and everything Ivy remembers. Nothing here can change what Ivy is allowed to do.
struct PersonalizationPanel: View {
    @ObservedObject var model: PersonalizationModel

    @State private var instructions = ""
    @State private var about: [String: String] = [:]
    @State private var apps: [String: String] = [:]
    @State private var newPreference = ""
    @State private var newTrigger = ""
    @State private var newPrompt = ""
    @State private var errorText: String?
    @State private var savedText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Personalization")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Picker("Sass", selection: Binding(get: { model.profile.sass }, set: { model.setSass($0) })) {
                Text("Polite").tag(0)
                Text("Light").tag(1)
                Text("Ivy").tag(2)
                Text("Roast").tag(3)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            Picker("Answers", selection: Binding(get: { model.profile.responseLength }, set: { model.setResponseLength($0) })) {
                Text("Brief").tag(PersonalizationProfile.ResponseLength.brief)
                Text("Balanced").tag(PersonalizationProfile.ResponseLength.balanced)
                Text("Detailed").tag(PersonalizationProfile.ResponseLength.detailed)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)

            Toggle("Occasional emoji", isOn: Binding(get: { model.profile.useEmoji }, set: { model.setUseEmoji($0) }))
                .toggleStyle(.checkbox)

            DisclosureGroup("About you") {
                ForEach(PersonalizationProfile.AboutField.allCases, id: \.self) { field in
                    TextField(field.label, text: aboutBinding(field.rawValue))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveAbout)
                }
                Button("Save", action: saveAbout).controlSize(.small)
                Text("No addresses, ID numbers or passwords: Ivy refuses to store them.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            DisclosureGroup("Favourite apps") {
                ForEach(PersonalizationProfile.AppRole.allCases, id: \.self) { role in
                    TextField("My \(role.rawValue) (app name)", text: appBinding(role.rawValue))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveApps)
                }
                Button("Save", action: saveApps).controlSize(.small)
            }

            DisclosureGroup("Custom instructions") {
                TextEditor(text: $instructions)
                    .font(.system(size: 11))
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                HStack {
                    Text("\(instructions.count)/\(PersonalizationProfile.maxCustomInstructions)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Save", action: saveInstructions).controlSize(.small)
                }
            }

            DisclosureGroup("Shortcuts") {
                ForEach(model.profile.shortcuts) { shortcut in
                    HStack(alignment: .top) {
                        Text(shortcut.trigger).font(.system(size: 11, design: .monospaced))
                        Text(shortcut.prompt).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        Button { model.removeShortcut(shortcut.id) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(shortcut.trigger)")
                    }
                }
                HStack {
                    TextField("/standup", text: $newTrigger).textFieldStyle(.roundedBorder).frame(width: 90)
                    TextField("What it asks Ivy", text: $newPrompt).textFieldStyle(.roundedBorder)
                    Button("Add", action: addShortcut).controlSize(.small)
                }
                Text("Type the shortcut as a message to send its text. It never approves anything for you.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }

            DisclosureGroup("What Ivy remembers (\(model.profile.learnedPreferences.count))") {
                ForEach(model.profile.learnedPreferences) { preference in
                    HStack {
                        Text(preference.text).font(.system(size: 11))
                        Spacer()
                        Button { model.forget(preference.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Forget \(preference.text)")
                    }
                }
                HStack {
                    TextField("e.g. prefers metric units", text: $newPreference)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addPreference)
                    Button("Add", action: addPreference).controlSize(.small)
                }
                if !model.profile.learnedPreferences.isEmpty {
                    Button("Forget everything", role: .destructive) { model.forgetEverything() }
                        .controlSize(.small)
                }
            }

            HStack {
                Button("Export…", action: exportProfile)
                Button("Import…", action: importProfile)
                Spacer()
                Button("Reset", role: .destructive) { model.reset(); loadDrafts() }
            }
            .controlSize(.small)

            if let errorText {
                Text(errorText).font(.system(size: 10)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let savedText {
                Text(savedText).font(.system(size: 10)).foregroundStyle(.green)
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 10)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Changes apply to chat now and to Ivy Live from the next launch.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 11))
        .onAppear(perform: loadDrafts)
    }

    // MARK: - Drafts

    private func aboutBinding(_ key: String) -> Binding<String> {
        Binding(get: { about[key] ?? "" }, set: { about[key] = $0 })
    }

    private func appBinding(_ key: String) -> Binding<String> {
        Binding(get: { apps[key] ?? "" }, set: { apps[key] = $0 })
    }

    private func loadDrafts() {
        instructions = model.profile.customInstructions
        about = model.profile.aboutMe
        apps = model.profile.favoriteApps
    }

    private func attempt(_ success: String, _ action: () throws -> Void) {
        do {
            try action()
            errorText = nil
            savedText = success
        } catch {
            errorText = error.localizedDescription
            savedText = nil
        }
    }

    private func saveAbout() {
        attempt("Saved.") {
            try model.update { $0.aboutMe = about.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty } }
        }
        about = model.profile.aboutMe
    }

    private func saveApps() {
        attempt("Saved.") {
            try model.update { $0.favoriteApps = apps.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty } }
        }
        apps = model.profile.favoriteApps
    }

    private func saveInstructions() {
        attempt("Saved.") { try model.update { $0.customInstructions = instructions } }
    }

    private func addPreference() {
        attempt("Remembered.") { try model.remember(newPreference) }
        if errorText == nil { newPreference = "" }
    }

    private func addShortcut() {
        attempt("Shortcut added.") { try model.addShortcut(trigger: newTrigger, prompt: newPrompt) }
        if errorText == nil {
            newTrigger = ""
            newPrompt = ""
        }
    }

    // MARK: - Import / export (user-chosen files only)

    private func exportProfile() {
        let includePreferences = NSAlert()
        includePreferences.messageText = "Include what Ivy remembers?"
        includePreferences.informativeText = "Remembered preferences are left out unless you include them."
        includePreferences.addButton(withTitle: "Leave Out")
        includePreferences.addButton(withTitle: "Include")
        let include = includePreferences.runModal() == .alertSecondButtonReturn
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Ivy Personalization.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt("Exported.") { try model.exportData(includingPreferences: include).write(to: url, options: .atomic) }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt("Imported.") {
            let dropped = try model.importData(Data(contentsOf: url))
            if !dropped.isEmpty { throw PersonalizationError.invalid("Imported, but some fields were dropped: " + dropped.joined(separator: " ")) }
        }
        loadDrafts()
    }
}
