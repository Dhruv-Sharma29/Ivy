import SwiftUI
import IvyCore

struct PointerSettingsSection: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
        VStack(spacing: 18) {
        SettingsCard(title: "Ask about your screen", symbol: "viewfinder", subtitle: "Point to something, then ask Ivy about it.") {
            SettingsToggle(title: "Hold shortcut to select", detail: "Changes apply immediately. Screen Recording is required when you attach an area.", isOn: $settings.settings.screenQuestionEnabled)
            SettingsControlRow(title: "Selection shortcut") {
                SettingsSegmentedPicker(title: "Selection shortcut", selection: $settings.settings.screenQuestionShortcut,
                    options: ScreenQuestionShortcut.allCases.map { ($0, $0.label) }).frame(height: 28)
            }
            Text("With Voice key selected, hold ⌘⇧Space, point or draw while speaking, then release to ask about that area. Push-to-talk must be enabled. R/A shortcuts attach a crop to Quick chat for a typed question. Esc cancels. Ivy's menu also offers selection with arrow keys and Return.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        SettingsCard(title: "Floating pointer", symbol: "cursorarrow", subtitle: "A small Ivy pointer beside your mouse cursor.") {
            SettingsToggle(title: "Follow my cursor", detail: "Off hides the pointer immediately. The Ivy companion must also be enabled.",
                           isOn: $settings.settings.floatingPointerEnabled)
                .accessibilityIdentifier("ivy.settings.pointer.enabled")
            Divider()
            SettingsControlRow(title: "Pointer color") {
                SettingsSegmentedPicker(title: "Pointer color", selection: $settings.settings.floatingPointerColor,
                                        options: FloatingPointerColor.allCases.map { ($0, $0.title) })
                    .frame(height: 28)
            }
            HStack(spacing: 10) {
                FloatingPointerView(color: settings.settings.floatingPointerColor)
                Text(settings.settings.floatingPointerColor.title).font(.callout)
            }
            Text("This is a visual companion: your mouse stays under your control. Reduce Motion turns off following; screen arrows remain available.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        }
    }
}
