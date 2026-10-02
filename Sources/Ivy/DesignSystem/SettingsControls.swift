import SwiftUI

/// One consistent surface and spacing rhythm for every Settings pane.
struct SettingsCard<Content: View>: View {
    let title: String
    let symbol: String
    var subtitle: String = ""
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(IvyTheme.sectionAccent)
                    .frame(width: 28, height: 28)
                    .background(IvyTheme.sectionAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ivyGlass(cornerRadius: 16)
    }
}

/// A native disclosure whose entire label row is a keyboard-accessible button.
struct SettingsDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 10) {
                    configuration.label.font(.body.weight(.medium))
                    Spacer()
                    Image(systemName: configuration.isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .ivyGlass(cornerRadius: 10, interactive: true)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded {
                VStack(alignment: .leading, spacing: 12) { configuration.content }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
        }
    }
}

/// SwiftUI's macOS segmented picker hugs its labels. AppKit can distribute every segment equally
/// across the full proposed width while preserving native keyboard and accessibility behavior.
struct SettingsSegmentedPicker<Value: Hashable>: NSViewRepresentable {
    let title: String
    @Binding var selection: Value
    let options: [(Value, String)]

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: options.map(\.1), trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.choose(_:)))
        control.segmentDistribution = .fillEqually
        control.controlSize = .regular
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updateNSView(control, context: context)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.segmentCount = options.count
        for (index, option) in options.enumerated() { control.setLabel(option.1, forSegment: index) }
        control.selectedSegment = options.firstIndex { $0.0 == selection } ?? -1
        control.isEnabled = context.environment.isEnabled
        control.selectedSegmentBezelColor = NSColor(IvyTheme.leaf)
        control.setAccessibilityLabel(title)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 280, height: 28)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: SettingsSegmentedPicker
        init(parent: SettingsSegmentedPicker) { self.parent = parent }

        @objc func choose(_ sender: NSSegmentedControl) {
            guard parent.options.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.options[sender.selectedSegment].0
        }
    }
}

struct SettingsToggle: View {
    let title: String
    var detail: String = ""
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                if !detail.isEmpty {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .frame(minHeight: 40)
    }
}

/// Pickers and sliders share a label column; narrow containers reflow to stacked controls.
struct SettingsControlRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                Text(title).frame(width: 140, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                content.frame(minWidth: 220, maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                content
            }
        }
        .font(.body)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
    }
}
