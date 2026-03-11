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

    /// Launch water settling animation progress (0 = start, 1 = settled).
    @State private var launchProgress: CGFloat = 0

    // MARK: Visual Effect State
    @State private var effectTimer: Timer?
    /// Light Wave
    @State private var lightWaveAngle: Double = 0
    @State private var lightWaveProgress: CGFloat = -0.3
    @State private var lightWaveActive = false
    /// Water Drop
    @State private var waterDropCenter: CGPoint = .zero
    @State private var waterDropStartTime: Date = .now
    @State private var waterDropActive = false
    /// Twinkle
    @State private var twinkleSparkles: [TwinkleSparkle] = []
    @State private var twinkleStartTime: Date = .now

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

            // Launch water settling effect
            if launchProgress < 1.0 {
                LaunchWaveOverlay(progress: launchProgress)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            // Periodic visual effects
            if waterDropActive {
                WaterDropOverlay(dropCenter: waterDropCenter, startTime: waterDropStartTime)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            if lightWaveActive {
                LightWaveOverlay(angle: lightWaveAngle, progress: lightWaveProgress)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

            if !twinkleSparkles.isEmpty {
                TwinkleOverlay(sparkles: twinkleSparkles, startTime: twinkleStartTime)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }

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
        .environment(\.showTouchSurfaces, displayManager.showTouchSurfaces)
        .ignoresSafeArea()
        .onChange(of: layoutManager.activeLayout.id) { _, _ in
            flashPageIndicator()
        }
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
            withAnimation(.easeOut(duration: 1.5)) {
                launchProgress = 1.0
            }
            startEffectTimerIfNeeded()
        }
        .onChange(of: themeManager.visualEffect) { _, _ in
            startEffectTimerIfNeeded()
        }
        .onChange(of: themeManager.visualEffectInterval) { _, _ in
            startEffectTimerIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ledgePreviewVisualEffect)) { _ in
            triggerEffect()
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

    // MARK: - Visual Effect Timer

    private func startEffectTimerIfNeeded() {
        effectTimer?.invalidate()
        effectTimer = nil
        guard themeManager.visualEffect != .off else { return }

        // Trigger immediately when enabled
        triggerEffect()

        effectTimer = Timer.scheduledTimer(
            withTimeInterval: themeManager.visualEffectInterval,
            repeats: true
        ) { _ in
            Task { @MainActor in
                triggerEffect()
            }
        }
    }

    private func triggerEffect() {
        switch themeManager.visualEffect {
        case .off: break
        case .lightWave: triggerLightWave()
        case .waterDrop: triggerWaterDrop()
        case .twinkle: triggerTwinkle()
        }
    }

    private func triggerLightWave() {
        lightWaveAngle = Double.random(in: -30...30)
        lightWaveProgress = -0.3
        lightWaveActive = true
        withAnimation(.easeInOut(duration: 2.0)) {
            lightWaveProgress = 1.3
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.1) {
            lightWaveActive = false
        }
    }

    private func triggerWaterDrop() {
        // Random center in the middle 60% of the screen
        let screenSize = displayManager.xeneonScreen?.frame.size ?? CGSize(width: 2560, height: 720)
        waterDropCenter = CGPoint(
            x: CGFloat.random(in: screenSize.width * 0.2 ... screenSize.width * 0.8),
            y: CGFloat.random(in: screenSize.height * 0.2 ... screenSize.height * 0.8)
        )
        waterDropStartTime = .now
        waterDropActive = true
        DispatchQueue.main.asyncAfter(deadline: .now() + WaterDropOverlay.duration + 0.1) {
            waterDropActive = false
        }
    }

    private func triggerTwinkle() {
        let layout = layoutManager.activeLayout
        let placements = layout.placements
        guard !placements.isEmpty else { return }

        // Use the Xeneon Edge resolution as default, actual size doesn't matter
        // too much since GeometryReader isn't available here — but the panel
        // is always fullscreen on the Edge so we can use the screen size.
        let screenSize = displayManager.xeneonScreen?.frame.size ?? CGSize(width: 2560, height: 720)
        let metrics = GridMetrics(
            columns: layout.columns,
            rows: layout.rows,
            totalWidth: screenSize.width,
            totalHeight: screenSize.height,
            outerPadding: 12,
            gap: 8
        )

        // Compute all widget frames
        let widgetFrames = placements.map { metrics.frame(for: $0) }

        // Generate 6-10 sparkles across random widget edges
        let sparkleCount = Int.random(in: 6...10)
        var sparkles: [TwinkleSparkle] = []
        for i in 0..<sparkleCount {
            let frame = widgetFrames.randomElement()!
            sparkles.append(TwinkleSparkle(
                id: UUID(),
                widgetFrame: frame,
                edge: TwinkleEdge.allCases.randomElement()!,
                startFraction: Double.random(in: 0.0...0.7),
                travelFraction: Double.random(in: 0.15...0.35),
                delay: Double(i) * Double.random(in: 0.15...0.3),
                duration: Double.random(in: 0.5...0.9),
                size: CGFloat.random(in: 5...10),
                tiltDegrees: Double.random(in: -15...15)
            ))
        }

        twinkleStartTime = .now
        twinkleSparkles = sparkles

        // Clear after all sparkles have finished
        let totalDuration = sparkles.map { $0.delay + $0.duration }.max() ?? 2.0
        DispatchQueue.main.asyncAfter(deadline: .now() + totalDuration + 0.2) {
            twinkleSparkles = []
        }
    }
}

// MARK: - Launch Wave Overlay

/// A one-time ripple/wave animation that plays when the dashboard first appears.
/// Several horizontal sine-wave bands oscillate and flatten as `progress` → 1.
struct LaunchWaveOverlay: View {
    let progress: CGFloat

    var body: some View {
        Canvas { context, size in
            let prog = Double(progress)
            let amplitude = 12.0 * (1.0 - prog)
            guard amplitude > 0.3 else { return }
            let w = Double(size.width)
            let h = Double(size.height)

            for band in 0..<4 {
                let phase = Double(band) * .pi / 2.0
                let yCenter = h * (0.2 + 0.2 * Double(band))
                var path = Path()
                path.move(to: CGPoint(x: 0, y: yCenter))
                for xStep in stride(from: 0.0, through: w, by: 2.0) {
                    let normalizedX = xStep / w
                    let y = yCenter + amplitude * Foundation.sin(normalizedX * .pi * 4.0 + phase)
                    path.addLine(to: CGPoint(x: xStep, y: y))
                }
                context.stroke(
                    path,
                    with: .color(.white.opacity(0.06 * (1.0 - prog))),
                    lineWidth: 2
                )
            }
        }
    }
}

// MARK: - Light Wave Overlay

/// A gradient band that sweeps across the dashboard at a random angle.
struct LightWaveOverlay: View {
    let angle: Double
    let progress: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let bandWidth = geometry.size.width * 0.15
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            .white.opacity(0.04),
                            .white.opacity(0.08),
                            .white.opacity(0.04),
                            .clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: bandWidth * 1.5, height: geometry.size.height * 1.5)
                .rotationEffect(.degrees(angle))
                .offset(x: progress * geometry.size.width - bandWidth / 2)
        }
        .clipped()
    }
}

// MARK: - Water Drop Overlay

/// Concentric ripple rings expanding from a random point, drawn as a Canvas overlay.
/// Uses TimelineView for reliable per-frame animation. Safe — no Metal shaders,
/// no .drawingGroup(), no rasterisation of the widget hierarchy.
struct WaterDropOverlay: View {
    let dropCenter: CGPoint
    let startTime: Date
    static let duration: Double = 2.0
    /// Maximum ripple radius — kept smaller for a tighter, more realistic look.
    static let maxRadiusFraction: Double = 0.35

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startTime)
            let prog = min(max(elapsed / Self.duration, 0), 1)

            Canvas { context, size in
                guard prog < 1.0 else { return }
                let maxRadius = max(size.width, size.height) * Self.maxRadiusFraction

                // Central flash at impact (fades in first 20% of animation)
                if prog < 0.2 {
                    let flashT = prog / 0.2
                    let flashOpacity = (1.0 - flashT) * 0.3
                    let flashRadius = flashT * 30.0
                    let flashRect = CGRect(
                        x: dropCenter.x - flashRadius,
                        y: dropCenter.y - flashRadius,
                        width: flashRadius * 2,
                        height: flashRadius * 2
                    )
                    context.fill(
                        Path(ellipseIn: flashRect),
                        with: .radialGradient(
                            Gradient(colors: [
                                .white.opacity(flashOpacity),
                                .white.opacity(flashOpacity * 0.3),
                                .clear
                            ]),
                            center: dropCenter,
                            startRadius: 0,
                            endRadius: flashRadius
                        )
                    )
                }

                // 4 concentric ripple rings, staggered outward
                for ring in 0..<4 {
                    let ringDelay = Double(ring) * 0.1
                    let ringProg = max(0, min(1, (prog - ringDelay) / (1.0 - ringDelay)))
                    guard ringProg > 0 else { continue }

                    let radius = ringProg * maxRadius
                    let fade = Foundation.pow(1.0 - ringProg, 1.8)
                    guard fade > 0.01 else { continue }

                    let rect = CGRect(
                        x: dropCenter.x - radius,
                        y: dropCenter.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                    let path = Path(ellipseIn: rect)

                    // Soft outer glow
                    context.stroke(
                        path,
                        with: .color(.white.opacity(0.10 * fade)),
                        lineWidth: 6 * fade + 1
                    )

                    // Bright core ring
                    context.stroke(
                        path,
                        with: .color(.white.opacity(0.22 * fade)),
                        lineWidth: 1.5 * fade + 0.5
                    )

                    // Inner dark ring (refraction depth)
                    if radius > 8 {
                        let innerRect = CGRect(
                            x: dropCenter.x - (radius - 3),
                            y: dropCenter.y - (radius - 3),
                            width: (radius - 3) * 2,
                            height: (radius - 3) * 2
                        )
                        context.stroke(
                            Path(ellipseIn: innerRect),
                            with: .color(.black.opacity(0.06 * fade)),
                            lineWidth: 2.0 * fade
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Twinkle Overlay

enum TwinkleEdge: CaseIterable {
    case top, bottom, leading, trailing
}

/// A sparkle that sweeps along a widget edge like light reflecting off glass.
struct TwinkleSparkle: Identifiable {
    let id: UUID
    /// The widget frame (computed from GridMetrics)
    let widgetFrame: CGRect
    /// Which edge to travel along
    let edge: TwinkleEdge
    /// Start position along the edge (0-1)
    let startFraction: Double
    /// Travel distance as fraction of edge length (0.15-0.4)
    let travelFraction: Double
    /// Delay before this sparkle starts (seconds)
    let delay: Double
    /// Duration of the sweep (seconds)
    let duration: Double
    /// Size of the sparkle highlight
    let size: CGFloat
    /// Angle of the streak relative to the edge (slight tilt)
    let tiltDegrees: Double
}

/// Animated sparkle reflections that sweep along widget edges like light on glass.
struct TwinkleOverlay: View {
    let sparkles: [TwinkleSparkle]
    let startTime: Date

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSince(startTime)

            Canvas { context, size in
                for sparkle in sparkles {
                    let localTime = elapsed - sparkle.delay
                    guard localTime > 0 && localTime < sparkle.duration else { continue }

                    let t = localTime / sparkle.duration  // 0→1 over the sweep
                    // Smooth fade in/out envelope
                    let envelope = Foundation.sin(t * .pi)  // peaks at 0.5
                    let brightness = envelope * envelope  // sharper peak
                    guard brightness > 0.01 else { continue }

                    // Current position along the edge
                    let fraction = sparkle.startFraction + sparkle.travelFraction * t
                    let pos = sparkle.positionOnEdge(fraction: fraction)

                    // Streak direction: along the edge with slight tilt
                    let isHorizontal = sparkle.edge == .top || sparkle.edge == .bottom
                    let streakLength = sparkle.size * 3.0
                    let streakWidth = sparkle.size * 0.8

                    // Draw the sparkle as an elongated bright streak
                    context.drawLayer { ctx in
                        // Translate to sparkle position and rotate
                        let baseAngle = isHorizontal ? 0.0 : 90.0
                        let angle = Angle.degrees(baseAngle + sparkle.tiltDegrees)

                        // Core bright streak (additive-look via high opacity white)
                        let streakRect = CGRect(
                            x: -streakLength / 2,
                            y: -streakWidth / 2,
                            width: streakLength,
                            height: streakWidth
                        )

                        var transform = CGAffineTransform.identity
                        transform = transform.translatedBy(x: pos.x, y: pos.y)
                        transform = transform.rotated(by: CGFloat(angle.radians))

                        // Outer glow
                        let glowRect = streakRect.insetBy(dx: -streakWidth, dy: -streakWidth * 0.5)
                        let glowPath = Path(ellipseIn: glowRect).applying(transform)
                        let glowGradient = Gradient(colors: [
                            .white.opacity(0.4 * brightness),
                            .white.opacity(0.1 * brightness),
                            .clear
                        ])
                        ctx.fill(
                            glowPath,
                            with: .radialGradient(
                                glowGradient,
                                center: pos,
                                startRadius: 0,
                                endRadius: streakLength * 0.5
                            )
                        )

                        // Bright inner core
                        let corePath = Path(ellipseIn: streakRect).applying(transform)
                        let coreGradient = Gradient(colors: [
                            .white.opacity(0.9 * brightness),
                            .white.opacity(0.5 * brightness),
                            .clear
                        ])
                        ctx.fill(
                            corePath,
                            with: .radialGradient(
                                coreGradient,
                                center: pos,
                                startRadius: 0,
                                endRadius: streakLength * 0.3
                            )
                        )

                        // Tiny bright centre point
                        let dotSize = sparkle.size * 0.3
                        let dotRect = CGRect(
                            x: pos.x - dotSize / 2,
                            y: pos.y - dotSize / 2,
                            width: dotSize,
                            height: dotSize
                        )
                        ctx.fill(
                            Path(ellipseIn: dotRect),
                            with: .color(.white.opacity(brightness))
                        )
                    }
                }
            }
        }
    }
}

extension TwinkleSparkle {
    /// Compute the pixel position for a given fraction along this sparkle's edge.
    func positionOnEdge(fraction: Double) -> CGPoint {
        let f = CGFloat(max(0, min(1, fraction)))
        switch edge {
        case .top:
            return CGPoint(x: widgetFrame.minX + widgetFrame.width * f, y: widgetFrame.minY)
        case .bottom:
            return CGPoint(x: widgetFrame.minX + widgetFrame.width * f, y: widgetFrame.maxY)
        case .leading:
            return CGPoint(x: widgetFrame.minX, y: widgetFrame.minY + widgetFrame.height * f)
        case .trailing:
            return CGPoint(x: widgetFrame.maxX, y: widgetFrame.minY + widgetFrame.height * f)
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