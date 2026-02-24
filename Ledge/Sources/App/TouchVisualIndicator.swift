import SwiftUI

/// Overlay that shows an expanding ripple at each touch point on the dashboard.
///
/// This view is placed in the DashboardView's ZStack with `.allowsHitTesting(false)`
/// so it doesn't intercept any touches. It listens to `displayManager.lastTouchInfo`
/// and spawns a brief ripple animation at each new touch coordinate.
///
/// The touch coordinates arrive in CG space (origin top-left, Y down) from the
/// flight recorder. We convert them to view-local coordinates using a GeometryReader
/// that captures the dashboard's global frame.
struct TouchVisualIndicator: View {
    @EnvironmentObject var displayManager: DisplayManager

    /// Active ripple effects currently animating.
    @State private var ripples: [Ripple] = []

    /// Tracks the last touch timestamp to detect new touches.
    @State private var lastTouchTimestamp: Date?

    struct Ripple: Identifiable {
        let id = UUID()
        let position: CGPoint  // in view-local coordinates
        let color: Color
        var scale: CGFloat = 0.2
        var opacity: Double = 0.5
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ForEach(ripples) { ripple in
                    Circle()
                        .stroke(ripple.color, lineWidth: 2)
                        .frame(width: 60, height: 60)
                        .scaleEffect(ripple.scale)
                        .opacity(ripple.opacity)
                        .position(ripple.position)
                }
            }
            .onChange(of: displayManager.lastTouchInfo?.timestamp) { _, newTimestamp in
                guard displayManager.showTouchIndicator,
                      let info = displayManager.lastTouchInfo,
                      let remapped = info.remappedPoint,
                      newTimestamp != lastTouchTimestamp else { return }

                lastTouchTimestamp = newTimestamp

                // Convert CG coordinates to view-local coordinates.
                // The remapped point is in absolute CG screen space (origin top-left, Y down).
                // The panel covers the full Edge screen, so we subtract the Edge screen's
                // CG origin to get window-local coordinates (which equals view-local for
                // a fullscreen panel).
                guard let edgeScreen = displayManager.xeneonScreen else { return }
                let primaryHeight = NSScreen.screens.first?.frame.height ?? edgeScreen.frame.height
                let edgeCGRect = TouchCoordinateMath.cocoaToCGRect(edgeScreen.frame, primaryHeight: primaryHeight)

                let viewX = remapped.x - edgeCGRect.origin.x
                let viewY = remapped.y - edgeCGRect.origin.y

                let ripple = Ripple(
                    position: CGPoint(x: viewX, y: viewY),
                    color: .white
                )

                ripples.append(ripple)

                // Animate expansion and fade
                withAnimation(.easeOut(duration: 0.45)) {
                    if let index = ripples.firstIndex(where: { $0.id == ripple.id }) {
                        ripples[index].scale = 1.0
                        ripples[index].opacity = 0.0
                    }
                }

                // Remove after animation completes
                let rippleID = ripple.id
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    ripples.removeAll { $0.id == rippleID }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
