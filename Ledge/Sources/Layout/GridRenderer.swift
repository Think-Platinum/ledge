import SwiftUI

/// Pure math for converting grid coordinates to pixel positions.
struct GridMetrics {
    let columns: Int
    let rows: Int
    let totalWidth: CGFloat
    let totalHeight: CGFloat
    let outerPadding: CGFloat
    let gap: CGFloat

    /// The width of a single grid cell.
    var cellWidth: CGFloat {
        let usableWidth = totalWidth - (outerPadding * 2) - (CGFloat(columns - 1) * gap)
        return usableWidth / CGFloat(columns)
    }

    /// The height of a single grid cell.
    var cellHeight: CGFloat {
        let usableHeight = totalHeight - (outerPadding * 2) - (CGFloat(rows - 1) * gap)
        return usableHeight / CGFloat(rows)
    }

    /// Returns the pixel frame for a widget placement.
    func frame(for placement: WidgetPlacement) -> CGRect {
        let x = outerPadding + CGFloat(placement.column) * (cellWidth + gap)
        let y = outerPadding + CGFloat(placement.row) * (cellHeight + gap)
        let width = CGFloat(placement.columnSpan) * cellWidth + CGFloat(placement.columnSpan - 1) * gap
        let height = CGFloat(placement.rowSpan) * cellHeight + CGFloat(placement.rowSpan - 1) * gap
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Renders all widgets in a layout using absolute positioning.
///
/// Uses a GeometryReader to get the available size, calculates GridMetrics,
/// then positions each WidgetContainer at its computed frame.
///
/// Supports three background modes:
/// - Theme colour (default solid background from the active theme)
/// - Background image (custom wallpaper behind the widget grid)
///
/// Widget backgrounds can independently be solid, blur, or transparent.
struct GridRenderer: View {
    @Environment(\.theme) private var theme
    @Environment(ThemeManager.self) private var themeManager
    let layout: WidgetLayout
    let configStore: WidgetConfigStore
    let registry: WidgetRegistry
    var outerPadding: CGFloat = 12
    var gap: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            let metrics = GridMetrics(
                columns: layout.columns,
                rows: layout.rows,
                totalWidth: geometry.size.width,
                totalHeight: geometry.size.height,
                outerPadding: outerPadding,
                gap: gap
            )

            ZStack(alignment: .topLeading) {
                // Background layer
                dashboardBackground(size: geometry.size)

                // Widgets
                ForEach(layout.placements) { placement in
                    let frame = metrics.frame(for: placement)
                    WidgetContainer(
                        placement: placement,
                        configStore: configStore,
                        registry: registry
                    )
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.origin.x, y: frame.origin.y)
                    .transition(
                        .asymmetric(
                            insertion: .scale(scale: 0.85).combined(with: .opacity),
                            removal: .scale(scale: 0.85).combined(with: .opacity)
                        )
                    )
                }
                .animation(.easeInOut(duration: 0.3), value: layout.placements.map(\.id))
            }
            .environment(\.widgetBackgroundStyle,
                         theme.preferredBackgroundStyle ?? themeManager.widgetBackgroundStyle)
        }
    }

    @ViewBuilder
    private func dashboardBackground(size: CGSize) -> some View {
        // Respect theme's preferred background style (e.g. Liquid Glass → blur)
        let bgStyle = theme.preferredBackgroundStyle ?? themeManager.widgetBackgroundStyle

        // Per-page background overrides the global setting
        let pageImage: NSImage? = {
            if let pagePath = layout.backgroundImagePath, !pagePath.isEmpty {
                return NSImage(contentsOfFile: pagePath)
            }
            return nil
        }()

        if let pageImage {
            // Per-page background takes priority
            Image(nsImage: pageImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            switch themeManager.dashboardBackgroundMode {
            case .themeColor:
                if bgStyle == .solid {
                    theme.dashboardBackground
                } else if let wallpaper = themeManager.desktopWallpaper {
                    // In fullscreen mode the desktop is hidden. When using blur/transparent
                    // backgrounds, show the macOS wallpaper so widgets have something to blur
                    // against (otherwise it's just black).
                    Image(nsImage: wallpaper)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    Color.clear
                }

            case .image:
                if let nsImage = themeManager.backgroundImage {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else if let wallpaper = themeManager.desktopWallpaper {
                    // Fall back to macOS desktop wallpaper (captured from the Edge screen).
                    // In fullscreen mode the desktop is hidden, so we reproduce it here.
                    Image(nsImage: wallpaper)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                } else {
                    if bgStyle == .solid {
                        theme.dashboardBackground
                    } else {
                        Color.clear
                    }
                }
            }
        }
    }
}
