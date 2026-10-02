import SwiftUI
import IvyCore

struct RegionalPreferencesView: View {
    var region: SystemRegionalPreferences = .current

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Region & language", systemImage: "globe")
                    .font(.body.weight(.medium))
                Spacer()
                Text("From macOS").font(.caption).foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                regionalRow("Time zone", value: region.timeZone.replacingOccurrences(of: "_", with: " "))
                regionalRow("Units", value: region.units)
                regionalRow("Language", value: region.language)
            }
            .font(.callout)
            Text("Ivy follows your Mac’s settings automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ivy.systemRegion")
    }

    private func regionalRow(_ title: String, value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
