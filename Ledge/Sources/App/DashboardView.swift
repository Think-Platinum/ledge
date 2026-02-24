import SwiftUI

/// The root view displayed on the Xeneon Edge panel.
///
/// This view hosts the grid layout and renders all active widgets.
/// Observes ThemeManager directly so the dashboard updates live when
/// the user switches themes in Settings.
///
/// Supports swipe gestures to switch between saved layouts (pages)
/// and displays a subtle page indicator when multiple pages exist.
struct DashboardView: View {
    @Environment(ThemeManager.self) private var themeManager
    @EnvironmentObject var displayManager: DisplayManager
    let layoutManager: LayoutManager
    let configStore: WidgetConfigStore
    let registry: WidgetRegistry

    /// Tracks the horizontal drag distance for swipe gesture.
    @State private var dragOffset: CGFloat = 0
    /// Briefly shows the page indicator after a page switch.
    @State private var showPageIndicator = false
    /// Direction of the last page transition (for slide animation).
    @State private var transitionDirection: TransitionDirection = .none

    var body: some View {
        ZStack(alignment: .bottom) {
            GridRenderer(
                layout: layoutManager.activeLayout,
                configStore: configStore,
                registry: registry
            )
            .id(layoutManager.activeLayout.id)
            .transition(pageTransition)
            .offset(x: dragOffset)
            .gesture(swipeGesture)

            // Touch visual indicator (ripples at touch points)
            TouchVisualIndicator()

            // Page indicator (only shown when multiple pages exist)
            if layoutManager.pageCount > 1 {
                PageIndicator(
                    pageCount: layoutManager.pageCount,
                    activeIndex: layoutManager.activePageIndex
                )
                .opacity(showPageIndicator ? 1.0 : 0.3)
                .padding(.bottom, 4)
                .animation(.easeInOut(duration: 0.3), value: showPageIndicator)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: layoutManager.activeLayout.id)
        .environment(\.theme, themeManager.resolvedTheme)
        .ignoresSafeArea()
        .onChange(of: layoutManager.activeLayout.id) { _, _ in
            flashPageIndicator()
        }
        // Keep panel transparency in sync with the effective background style.
        // When Blur or Transparent, the panel must be non-opaque so the desktop
        // wallpaper (or background image) shows through gaps between widgets.
        // Themes with a preferredBackgroundStyle (e.g. Liquid Glass → blur) also
        // need the panel to be transparent.
        .onChange(of: themeManager.widgetBackgroundStyle) { _, _ in
            updatePanelTransparency()
        }
        .onChange(of: themeManager.dashboardBackgroundMode) { _, _ in
            updatePanelTransparency()
        }
        .onChange(of: themeManager.mode) { _, _ in
            updatePanelTransparency()
        }
        .onAppear {
            updatePanelTransparency()
        }
    }

    // MARK: - Panel Transparency

    /// Determines whether the panel needs to be transparent based on the
    /// effective background style (user setting or theme override).
    private func updatePanelTransparency() {
        let effectiveStyle = themeManager.resolvedTheme.preferredBackgroundStyle
            ?? themeManager.widgetBackgroundStyle
        displayManager.panel?.setTransparent(effectiveStyle != .solid)
    }

    // MARK: - Page Transition

    /// Tracks whether the user swiped left or right for directional animation.
    private enum TransitionDirection { case none, forward, backward }

    /// Asymmetric slide transition based on swipe direction.
    private var pageTransition: AnyTransition {
        switch transitionDirection {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        case .none:
            return .opacity
        }
    }

    // MARK: - Swipe Gesture

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 50)
            .onChanged { value in
                // Only respond to horizontal drags
                if abs(value.translation.width) > abs(value.translation.height) {
                    dragOffset = value.translation.width * 0.3  // dampened drag
                }
            }
            .onEnded { value in
                let threshold: CGFloat = 100
                withAnimation(.easeOut(duration: 0.25)) {
                    dragOffset = 0
                }

                if value.translation.width < -threshold {
                    transitionDirection = .forward
                    withAnimation(.easeInOut(duration: 0.35)) {
                        layoutManager.nextPage()
                    }
                    layoutManager.resetAutoRotationTimer()
                } else if value.translation.width > threshold {
                    transitionDirection = .backward
                    withAnimation(.easeInOut(duration: 0.35)) {
                        layoutManager.previousPage()
                    }
                    layoutManager.resetAutoRotationTimer()
                }
            }
    }

    /// Briefly flash the page indicator to full opacity after a page switch.
    private func flashPageIndicator() {
        showPageIndicator = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            showPageIndicator = false
        }
    }
}

// MARK: - Page Indicator

/// A row of dots indicating the current page, similar to iOS home screen dots.
struct PageIndicator: View {
    let pageCount: Int
    let activeIndex: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<pageCount, id: \.self) { index in
                Circle()
                    .fill(index == activeIndex ? Color.white : Color.white.opacity(0.35))
                    .frame(width: index == activeIndex ? 8 : 6,
                           height: index == activeIndex ? 8 : 6)
                    .animation(.easeInOut(duration: 0.2), value: activeIndex)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(.black.opacity(0.3))
        )
    }
}