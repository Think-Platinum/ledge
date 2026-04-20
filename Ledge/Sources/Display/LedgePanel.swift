import AppKit
import SwiftUI
import os.log

/// A non-activating panel that displays the widget dashboard on the Xeneon Edge.
///
/// This NSPanel subclass is the core of Ledge's focus management. By using the
/// `.nonactivatingPanel` style mask (set at init time — this is critical due to
/// an AppKit bug), the panel can receive touch/mouse input without activating
/// the Ledge application or stealing focus from the user's foreground app.
///
/// See docs/FOCUS_MANAGEMENT.md for the full rationale.
class LedgePanel: NSPanel {

    private let logger = Logger(subsystem: "com.ledge.app", category: "LedgePanel")

    /// Observer token for `NSWindow.didChangeScreenNotification` on this panel.
    /// Used to detect AppKit silently relocating the panel to the wrong display
    /// (e.g. when the Edge's NSScreen becomes invalid during sleep/wake).
    private var screenChangeObserver: Any?

    /// Creates a new LedgePanel covering the given screen.
    ///
    /// - Parameter screen: The NSScreen to display the panel on (should be the Xeneon Edge).
    convenience init(on screen: NSScreen) {
        // CRITICAL: .nonactivatingPanel MUST be set here at init time.
        // Setting it later causes a known AppKit bug where kCGSPreventsActivationTagBit
        // is not properly toggled. See: https://philz.blog/nspanel-nonactivating-style-mask-flag/
        self.init(
            contentRect: screen.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        configurePanel(on: screen)
        observeScreenChanges()
        // .notice level — macOS purges .info under memory pressure, which
        // destroys the diagnostic trail at the worst possible moment.
        logger.notice("init on \(screen.localizedName, privacy: .public) frame=\(NSStringFromRect(screen.frame), privacy: .public)")
    }

    deinit {
        if let obs = screenChangeObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    private func observeScreenChanges() {
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let name = self.screen?.localizedName ?? "nil"
            self.logger.warning("Panel changed screen → \(name, privacy: .public) frame=\(NSStringFromRect(self.frame), privacy: .public)")
        }
    }

    private func configurePanel(on screen: NSScreen) {
        // Screen-saver level (1000) places the panel above standard UI chrome.
        // CGShieldingWindowLevel was too aggressive and caused input issues.
        level = .screenSaver
        isFloatingPanel = true

        // Don't hide when the app loses focus — the whole point is to always be visible
        hidesOnDeactivate = false

        // Visual properties
        hasShadow = false
        isOpaque = true
        backgroundColor = .black

        // Accept mouse/touch movement events
        acceptsMouseMovedEvents = true

        // Don't allow dragging the panel by its background
        isMovableByWindowBackground = false
        isMovable = false

        // Appear on all Spaces, stay put during Space switches, and sit alongside
        // fullscreen apps. `.ignoresCycle` keeps the panel out of Cmd+` window cycling.
        // `.stationary` prevents the sliding animation when switching Spaces.
        collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        // Ensure no title bar at all
        titleVisibility = .hidden
        titlebarAppearsTransparent = true

        // Pin to the screen frame — use setFrame to bypass any content insets
        setFrame(screen.frame, display: false)
    }

    // MARK: - Frame Constraints

    /// Prevent macOS from constraining the panel frame to the "visible" area
    /// (which excludes the menu bar region). We want full coverage.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        return frameRect
    }

    // MARK: - State-change logging
    //
    // These overrides exist so the Developer log filter "LedgePanel" actually
    // shows panel-level activity. Without them, every state change is only
    // visible through DisplayManager's perspective — which hides cases where
    // the two disagree.

    override func setFrame(_ frameRect: NSRect, display flag: Bool, animate animationFlag: Bool) {
        logger.notice("setFrame \(NSStringFromRect(frameRect), privacy: .public) display=\(flag, privacy: .public) animate=\(animationFlag, privacy: .public) screen=\(self.screen?.localizedName ?? "nil", privacy: .public)")
        super.setFrame(frameRect, display: flag, animate: animationFlag)
    }

    override func orderFront(_ sender: Any?) {
        logger.notice("orderFront (currently visible=\(self.isVisible, privacy: .public))")
        super.orderFront(sender)
    }

    override func orderFrontRegardless() {
        logger.notice("orderFrontRegardless (currently visible=\(self.isVisible, privacy: .public))")
        super.orderFrontRegardless()
    }

    override func orderOut(_ sender: Any?) {
        logger.notice("orderOut (was visible=\(self.isVisible, privacy: .public))")
        super.orderOut(sender)
    }

    // MARK: - Focus Management

    /// Allow the panel to become the key window so it can receive keyboard/touch input.
    override var canBecomeKey: Bool { true }

    /// Prevent the panel from becoming the main window — this is what stops focus stealing.
    override var canBecomeMain: Bool { false }

    /// Accept first responder for touch/mouse events.
    override var acceptsFirstResponder: Bool { true }

    /// Guard against focus stealing whenever the panel becomes key.
    /// This catches all code paths — mouseDown, TouchRemapper delivery,
    /// SwiftUI internal calls — ensuring we never reorder windows.
    override func becomeKey() {
        NSApp.preventWindowOrdering()
        super.becomeKey()
    }

    // MARK: - Delivery Confirmation

    /// Number of touch events received by the panel (mouseDown + mouseDragged + mouseUp).
    /// Compare with TouchRemapper's delivery count to detect drops.
    private(set) var receivedEventCount: Int = 0

    /// Callback invoked when a touch event is received. Used by the flight recorder
    /// to confirm delivery and measure latency.
    var onEventReceived: ((_ type: NSEvent.EventType) -> Void)?

    // MARK: - Event Handling

    /// Ensure the panel becomes key when clicked/touched so that SwiftUI's
    /// gesture recognisers are active. With .nonactivatingPanel this won't
    /// steal focus from the foreground app — it only makes this panel the
    /// key window (receives input) without becoming the main window.
    override func mouseDown(with event: NSEvent) {
        receivedEventCount += 1
        onEventReceived?(.leftMouseDown)
        // Prevent macOS from reordering windows — without this, AppKit may
        // bring the Ledge app forward in the window list, stealing focus.
        NSApp.preventWindowOrdering()
        if !isKeyWindow {
            makeKey()
        }
        // Let NSPanel's default dispatch handle hit-testing and routing
        // to the NSHostingView (SwiftUI). Do NOT manually forward to contentView
        // — that bypasses the responder chain and breaks gesture recognisers.
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        receivedEventCount += 1
        onEventReceived?(.leftMouseDragged)
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        receivedEventCount += 1
        onEventReceived?(.leftMouseUp)
        super.mouseUp(with: event)
    }

    // MARK: - Transparency

    /// Enable transparent panel background for blur/image effects.
    /// When enabled, the panel's background becomes clear so that
    /// `NSVisualEffectView` blur and background images work correctly.
    func setTransparent(_ transparent: Bool) {
        if transparent {
            isOpaque = false
            backgroundColor = .clear
        } else {
            isOpaque = true
            backgroundColor = .black
        }
    }

    // MARK: - Lifecycle

    /// Reposition the panel when the target screen's frame changes
    /// (e.g., resolution change, display rearrangement).
    func reposition(on screen: NSScreen) {
        setFrame(screen.frame, display: true, animate: false)
    }
}
