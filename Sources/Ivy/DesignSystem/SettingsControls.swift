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
                    .frame(width: 32, height: 32)
                    .background(IvyTheme.sectionAccent.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
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
        .ivyGlass(cornerRadius: IvyTheme.cardRadius)
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

/// Single-choice cards explain a preference without a heavy segmented-control bezel.
struct SettingsChoiceCards<Value: Hashable>: View {
    let title: String
    let detail: String
    @Binding var selection: Value
    let options: [(value: Value, title: String, detail: String)]
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    ForEach(options, id: \.value) { option in
                        optionButton(option).frame(minWidth: 110, maxWidth: .infinity)
                    }
                }
                VStack(spacing: 8) {
                    ForEach(options, id: \.value) { option in optionButton(option) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onKeyPress(.leftArrow) { isEnabled && moveSelection(by: -1) ? .handled : .ignored }
        .onKeyPress(.rightArrow) { isEnabled && moveSelection(by: 1) ? .handled : .ignored }
    }

    private func optionButton(_ option: (value: Value, title: String, detail: String)) -> some View {
        let selected = selection == option.value
        return Button { select(option.value) } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(option.title).font(.body.weight(selected ? .semibold : .medium))
                    Spacer(minLength: 0)
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.callout).foregroundStyle(selected ? IvyTheme.leaf : Color.secondary)
                        .accessibilityHidden(true)
                }
                Text(option.detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12).frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(SettingsChoiceButtonStyle(selected: selected))
        .accessibilityLabel(title + ", " + option.title)
        .accessibilityHint(option.detail)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    func select(_ value: Value) {
        guard options.contains(where: { $0.value == value }) else { return }
        selection = value
    }

    @discardableResult
    func moveSelection(by offset: Int) -> Bool {
        guard !options.isEmpty else { return false }
        let current = options.firstIndex { $0.value == selection } ?? 0
        select(options[min(options.count - 1, max(0, current + offset))].value)
        return true
    }
}

private struct SettingsChoiceButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        SettingsChoiceButtonLabel(configuration: configuration, selected: selected)
    }
}

private struct SettingsChoiceButtonLabel: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(selected ? IvyTheme.leaf.opacity(0.10) : Color.primary.opacity(hovering && isEnabled ? 0.06 : 0.025),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? IvyTheme.leaf : Color.secondary.opacity(contrast == .increased ? 0.8 : 0.18),
                                  lineWidth: selected || contrast == .increased ? 1.5 : 1)
            }
            .opacity(!isEnabled ? 0.5 : configuration.isPressed ? 0.7 : 1)
            .onHover { hovering = $0 }
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
