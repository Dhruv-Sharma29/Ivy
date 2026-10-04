import SwiftUI
import IvyCore

struct PointerSettingsSection: View {
    @ObservedObject var settings: SettingsModel

    var body: some View {
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
