import SwiftUI

/// SwiftUI wrapper that renders a single widget within the grid.
///
/// Provides the standard widget chrome: background (solid, blur, or transparent),
/// rounded corners, border, and optional Liquid Glass effects (inner glow,
/// specular highlight, drop shadow). Shows an error placeholder for
/// unknown or failed widget types.
struct WidgetContainer: View {
    @Environment(\.theme) private var theme
    @Environment(\.widgetBackgroundStyle) private var backgroundStyle
    let placement: WidgetPlacement
    let configStore: WidgetConfigStore
    let registry: WidgetRegistry

    private var cornerRadius: CGFloat { theme.widgetCornerRadius }

    var body: some View {
        Group {
            if let descriptor = registry.registeredTypes[placement.widgetTypeID] {
                descriptor.viewFactory(placement.id, configStore)
            } else {
                errorPlaceholder
            }
        }
        .background(widgetBackground)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(glassOverlay)
        .shadow(
            color: theme.glassShadowRadius > 0 ? theme.glassShadowColor : .clear,
            radius: theme.glassShadowRadius,
            x: 0, y: 4
        )
    }

    // MARK: - Glass Overlay

    /// Multi-layer overlay: outer border + optional inner highlight for glass effect.
    private var glassOverlay: some View {
        ZStack {
            // Primary border
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(theme.widgetBorderColor, lineWidth: theme.widgetBorderWidth)

            // Inner glow — a second, brighter stroke inset slightly
            // Creates the "light catching the edge" look of real glass
            if theme.glassInnerGlow {
                RoundedRectangle(cornerRadius: cornerRadius - 1, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassHighlightColor,
                                theme.glassHighlightColor.opacity(0.02),
                                .clear,
                                .clear
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: theme.glassHighlightWidth
                    )
                    .padding(theme.widgetBorderWidth)
            }
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var widgetBackground: some View {
        let effectiveStyle = theme.preferredBackgroundStyle ?? backgroundStyle

        switch effectiveStyle {
        case .solid:
            theme.widgetBackground
        case .blur:
            ZStack {
                VisualEffectBlur(
                    material: .hudWindow,
                    blendingMode: .withinWindow,
                    state: .active
                )
                // Tinted overlay to give the glass a subtle colour wash
                theme.widgetBackground
            }
        case .transparent:
            Color.clear
        }
    }

    // MARK: - Error Placeholder

    private var errorPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24))
                .foregroundStyle(.orange)
            Text("Unknown Widget")
                .font(.caption)
                .foregroundStyle(theme.secondaryText)
            Text(placement.widgetTypeID)
                .font(.caption2.monospaced())
                .foregroundStyle(theme.tertiaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Widget Background Style Environment Key

private struct WidgetBackgroundStyleKey: EnvironmentKey {
    static let defaultValue: WidgetBackgroundStyle = .solid
}

extension EnvironmentValues {
    var widgetBackgroundStyle: WidgetBackgroundStyle {
        get { self[WidgetBackgroundStyleKey.self] }
        set { self[WidgetBackgroundStyleKey.self] = newValue }
    }
}
