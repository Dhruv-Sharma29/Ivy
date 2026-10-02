import SwiftUI

/// A shared opaque preview mode. System accessibility preferences always take precedence.
private struct IvyOpaqueSurfacesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var ivyOpaqueSurfaces: Bool {
        get { self[IvyOpaqueSurfacesKey.self] }
        set { self[IvyOpaqueSurfacesKey.self] = newValue }
    }
}

/// Shared native glass surfaces, with opaque replacements for accessibility preferences.
struct IvyGlass: ViewModifier {
    let cornerRadius: CGFloat
    var tinted = false
    var forceOpaque = false
    var interactive = false
    var enabled = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.ivyOpaqueSurfaces) private var opaqueSurfaces

    @ViewBuilder
    func body(content: Content) -> some View {
        if !enabled {
            content
        } else if forceOpaque || opaqueSurfaces || reduceTransparency || contrast == .increased {
            content.background(tinted ? IvyTheme.sprout : IvyTheme.surface,
                               in: RoundedRectangle(cornerRadius: cornerRadius))
        } else if #available(macOS 26.0, *) {
            content.glassEffect((tinted ? Glass.regular.tint(IvyTheme.leaf.opacity(0.16)) : Glass.regular).interactive(interactive),
                                in: .rect(cornerRadius: cornerRadius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    func ivyGlass(cornerRadius: CGFloat = 12, tinted: Bool = false, forceOpaque: Bool = false,
                  interactive: Bool = false, enabled: Bool = true) -> some View {
        modifier(IvyGlass(cornerRadius: cornerRadius, tinted: tinted, forceOpaque: forceOpaque,
                          interactive: interactive, enabled: enabled))
    }

    // Zero keeps unrelated cards distinct; opt into a merge distance only for related controls.
    func ivyGlassGroup(spacing: CGFloat = 0) -> some View {
        modifier(IvyGlassGrouping(spacing: spacing))
    }

    func ivyGlassButtonStyle(prominent: Bool = false) -> some View {
        modifier(IvyGlassButtons(prominent: prominent))
    }

    func ivyWindowBackground() -> some View {
        modifier(IvyWindowBackground())
    }
}

/// Group sibling surfaces so the system can compose their glass without sampling one another.
private struct IvyGlassGrouping: ViewModifier {
    let spacing: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

private struct IvyGlassButtons: ViewModifier {
    let prominent: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.ivyOpaqueSurfaces) private var opaqueSurfaces

    @ViewBuilder
    func body(content: Content) -> some View {
        if !opaqueSurfaces, !reduceTransparency, contrast != .increased, #available(macOS 26.0, *) {
            if prominent { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) } else { content.buttonStyle(.bordered) }
        }
    }
}

/// Let the Mac's wallpaper influence the workspace without making its text or controls transparent.
private struct IvyWindowBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.ivyOpaqueSurfaces) private var opaqueSurfaces

    func body(content: Content) -> some View {
        content.background {
            if opaqueSurfaces || reduceTransparency || contrast == .increased {
                IvyTheme.canvas
            } else {
                IvyWindowMaterial().accessibilityHidden(true)
            }
        }
    }
}

struct IvyWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = IvyWindowEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        // The material is static; AppKit follows the window's appearance and activation automatically.
    }
}

private final class IvyWindowEffectView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct IvySidebarBackground: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content.background(reduceTransparency || contrast == .increased ? IvyTheme.sidebar : Color.clear)
    }
}
