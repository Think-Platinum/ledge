import AppKit
import SwiftUI
import Combine
import AVFoundation
import CoreLocation
import EventKit
import os.log

/// Marker subclass for the fullscreen helper window.
/// Used to exclude it from window enumeration in AppDelegate.
class FullscreenHelperWindow: NSWindow {}

/// Manages detection of the Xeneon Edge display and the lifecycle of the LedgePanel.
///
/// DisplayManager watches for display configuration changes (connect/disconnect/rearrange)
/// and automatically creates or repositions the LedgePanel when the Xeneon Edge is found.
@MainActor
class DisplayManager: ObservableObject {

    // MARK: - Published State

    /// The current panel, if the Xeneon Edge is connected and the panel is active.
    @Published private(set) var panel: LedgePanel?

    /// The detected Xeneon Edge screen, if connected.
    @Published private(set) var xeneonScreen: NSScreen?

    /// Whether the panel is currently displayed.
    @Published private(set) var isActive: Bool = false

    /// User intent: "should the panel be visible when the Edge is present?"
    ///
    /// Unlike `isActive` (current runtime state), this tracks intent and
    /// persists across transient disconnects. Set `true` by a successful
    /// `revealPanel`, cleared by an explicit `hidePanel`. `destroyPanel`
    /// deliberately does NOT touch it, because a disconnect is transient
    /// and should not be treated as user intent to hide.
    ///
    /// `handleDisplayChange` uses this to auto-restore the panel after
    /// sleep/wake and cable flaps — so the user doesn't have to press
    /// "Show Panel" every time macOS briefly drops the display.
    @Published private(set) var wasActive: Bool = false

    /// Status message for the settings UI.
    @Published private(set) var statusMessage: String = "Searching for Xeneon Edge..."

    /// Whether the panel is waiting for widget permissions before rendering.
    @Published private(set) var permissionGateActive: Bool = false

    // MARK: - Configuration

    /// Known characteristics of the Xeneon Edge display.
    enum XenonEdgeInfo {
        static let width: CGFloat = 2560
        static let height: CGFloat = 720
        static let displayName = "XENEON EDGE"
    }

    // MARK: - Touch Remapping

    /// The touch remapper that fixes macOS's incorrect touchscreen-to-display mapping.
    let touchRemapper = TouchRemapper()

    /// IOKit HID-based touchscreen detector — identifies the device without manual calibration.
    private let hidDetector = HIDTouchDetector()

    /// Flight recorder capturing recent touch events for diagnostics.
    let flightRecorder = TouchFlightRecorder()

    /// Watchdog timer that monitors CGEventTap health independently of the callback.
    let touchWatchdog = TouchWatchdog()

    /// IOKit HID direct touch reader — reads raw digitizer reports for reliable
    /// touch input, bypassing macOS's broken coordinate mapping.
    let hidTouchReader = HIDTouchReader()

    /// Whether the HID touch reader is active and handling touch delivery.
    @Published private(set) var isHIDTouchReaderActive: Bool = false

    /// Which touch pipeline is currently active.
    enum TouchPipelineMode: String {
        case cgEventTapOnly = "CGEventTap (legacy)"
        case hidWithSuppression = "HID + CGEventTap suppression"
    }
    @Published private(set) var touchPipelineMode: TouchPipelineMode = .cgEventTapOnly

    /// Mouse guard that blocks non-touchscreen mouse events on the Edge display.
    let mouseGuard = MouseGuard()

    /// Whether the mouse guard is enabled. Persisted in UserDefaults.
    @Published var isMouseGuardEnabled: Bool = UserDefaults.standard.bool(forKey: "mouseGuardEnabled") {
        didSet {
            UserDefaults.standard.set(isMouseGuardEnabled, forKey: "mouseGuardEnabled")
            updateMouseGuardState()
        }
    }

    /// Whether to show a visual ripple indicator at touch points.
    @Published var showTouchIndicator: Bool = UserDefaults.standard.object(forKey: "showTouchIndicator") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showTouchIndicator, forKey: "showTouchIndicator")
        }
    }

    /// Whether to show debug borders around interactive touch surfaces.
    @Published var showTouchSurfaces: Bool = false

    /// Whether Accessibility permissions have been granted (required for CGEventTap).
    @Published private(set) var accessibilityPermission: AccessibilityPermission = .unknown

    /// Whether the touch remapper event tap is active.
    @Published private(set) var isTouchRemapperActive: Bool = false

    /// Whether the touchscreen device has been identified via calibration.
    @Published private(set) var calibrationState: CalibrationState = .notStarted

    /// The learned HID device ID for the touchscreen (nil until calibrated).
    @Published private(set) var learnedDeviceID: Int64? = nil

    /// Info about the most recent touch event (for debug overlay).
    @Published private(set) var lastTouchInfo: TouchEventInfo? = nil

    /// Number of times the IOKit registry IDs reported by `HIDTouchDetector`
    /// have changed since the touch remapper started. Edge re-enumerations
    /// across sleep/wake bump this — see `refreshTouchDeviceIDs(reason:)`.
    @Published private(set) var deviceIDChangeCount: Int = 0

    /// Timestamp of the most recent device-ID change, if any.
    @Published private(set) var lastDeviceIDChangeAt: Date? = nil

    /// Why the most recent device-ID refresh fired (e.g. `"system woke"`,
    /// `"periodic"`, `"user"`). Only set when the IDs actually changed.
    @Published private(set) var lastDeviceIDChangeReason: String? = nil

    /// Derived status string for the settings UI.
    var touchStatus: String {
        switch accessibilityPermission {
        case .unknown:
            return "Not started"
        case .waiting:
            return "Waiting for Accessibility permission..."
        case .granted:
            if !isTouchRemapperActive {
                return "Event tap failed to start"
            }
            switch calibrationState {
            case .notStarted:
                return "Active — waiting for calibration"
            case .learning:
                return "Calibrating — touch the Xeneon Edge screen..."
            case .calibrated:
                if let id = learnedDeviceID {
                    return "Active — device \(id)"
                }
                return "Active — calibrated"
            case .autoDetected:
                if let id = learnedDeviceID {
                    return "Active — auto-detected device \(id)"
                }
                return "Active — auto-detected"
            }
        }
    }

    // MARK: - Touch Types

    enum AccessibilityPermission: String {
        case unknown = "Unknown"
        case waiting = "Waiting for grant..."
        case granted = "Granted"
    }

    enum CalibrationState: String {
        case notStarted = "Not started"
        case learning = "Touch the Xeneon Edge..."
        case calibrated = "Calibrated"
        case autoDetected = "Auto-detected"
    }

    struct TouchEventInfo {
        let deviceID: Int64
        let originalPoint: CGPoint
        let remappedPoint: CGPoint?
        let timestamp: Date
    }

    // MARK: - Display Security

    /// Whether the panel is currently blanked due to screen lock, sleep, or screensaver.
    @Published private(set) var isDisplayBlanked: Bool = false

    /// Reason for the most recent `blankDisplay(reason:)` call.
    @Published private(set) var lastBlankReason: String?

    /// Timestamp of the most recent `blankDisplay(reason:)` call.
    @Published private(set) var lastBlankTimestamp: Date?

    /// Reason for the most recent `unblankDisplay(reason:)` call.
    @Published private(set) var lastUnblankReason: String?

    /// Timestamp of the most recent `unblankDisplay(reason:)` call.
    @Published private(set) var lastUnblankTimestamp: Date?

    /// Running counts of every sleep/lock/screensaver system event observed.
    /// Exposed in Developer Settings so stuck-blank recurrences are diagnosable
    /// without attaching a debugger.
    struct SecurityEventCounts: Equatable {
        var screensDidSleep: Int = 0
        var screensDidWake: Int = 0
        var willSleep: Int = 0
        var didWake: Int = 0
        var screenLocked: Int = 0
        var screenUnlocked: Int = 0
        var screensaverStart: Int = 0
        var screensaverStop: Int = 0
    }

    @Published private(set) var securityEventCounts = SecurityEventCounts()

    // MARK: - Private

    private let logger = Logger(subsystem: "com.ledge.app", category: "DisplayManager")
    private var displayReconfigurationToken: Any?
    private var permissionPollTimer: Timer?
    private var appActivationObserver: Any?
    /// A helper window that enters macOS native fullscreen on the Edge display.
    /// This creates a fullscreen Space which auto-hides the menu bar per-display.
    /// The LedgePanel (with .fullScreenAuxiliary) renders on top of it.
    private var fullscreenHelper: FullscreenHelperWindow?
    /// Observer for fullscreen entry to show the panel once the Space is ready.
    private var fullscreenObserver: Any?
    /// Cancellable timeout paired with `fullscreenObserver`. Stored as a
    /// `DispatchWorkItem` (not a plain `asyncAfter`) so a rapid rebuild
    /// cycle can cancel the previous timer before installing a new one —
    /// otherwise the stale timer fires against the new observer and calls
    /// completion prematurely. See the architect-flagged race in
    /// `observeFullscreenEntry`.
    private var fullscreenEntryTimeout: DispatchWorkItem?
    /// Permission gate: timer, retained objects, and completion for pre-panel permission requests.
    private var permissionGateTimer: Timer?
    private var gateLocationManager: CLLocationManager?
    private var gateEventStore: EKEventStore?
    private var gatedPermissions: Set<WidgetPermission> = []
    private var onPermissionsResolved: (() -> Void)?
    /// Observers for sleep/lock/screensaver events.
    private var securityObservers: [Any] = []
    /// Callback invoked once Accessibility permission is granted (pre-fullscreen gate).
    private var accessibilityPermissionCompletion: (() -> Void)?
    /// Timer polling for Accessibility permission before fullscreen.
    private var accessibilityGateTimer: Timer?

    /// Periodic safety-net timer that calls `refreshTouchDeviceIDs(reason:)`
    /// while the remapper is active. Catches Edge re-enumerations that happen
    /// without a wake / display-change notification (some unplug-replug cases,
    /// USB hub flaps). Started by `proceedWithTouchRemapper`, stopped by
    /// `stopTouchRemapper`.
    private var deviceIDRefreshTimer: Timer?

    /// Observer for `NSWindow.didChangeScreenNotification` on the fullscreen
    /// helper. AppKit silently migrates the helper to a different display when
    /// the topology shifts under it (the wake bug — helper created at Edge@(0,0)
    /// gets stranded on LG when LG re-joins and Edge moves to (548,-720)).
    /// Catches the migration in real time and triggers a sanity rebuild.
    private var helperScreenObserver: Any?

    /// Lifecycle phase of the fullscreen helper.
    ///
    /// Architect-flagged: replaces the previous timer-cascade
    /// (`tearDown` + `asyncAfter(0.5)` + `ensureFullscreenHelper`) with
    /// explicit state so reentrant `handleDisplayChange` calls can be
    /// queued instead of stacking conflicting transitions. The wake bug
    /// reproduction showed three timers (2s entry timeout, 0.5s rebuild
    /// delay, 2s exit timeout) interleaving and producing an orphan
    /// helper. With explicit state we can refuse to start a new transition
    /// until the previous one settles, and queue any change request that
    /// arrives during a transition for re-evaluation when it completes.
    enum HelperState: Equatable {
        /// No helper exists.
        case none
        /// `ensureFullscreenHelper` is in progress for `displayID`.
        /// Further change requests are queued via `pendingRebuildDisplayID`.
        case building(displayID: CGDirectDisplayID)
        /// Helper is in fullscreen on `displayID`.
        case ready(displayID: CGDirectDisplayID)
        /// Helper is exiting fullscreen and being torn down.
        /// Further change requests are queued via `pendingRebuildDisplayID`.
        case tearing(fromDisplayID: CGDirectDisplayID)
    }
    private var helperState: HelperState = .none

    /// If a rebuild is requested while `helperState` is `.building` or
    /// `.tearing`, the target displayID is stashed here. When the in-flight
    /// transition completes, this is consulted and triggers the next rebuild.
    private var pendingRebuildDisplayID: CGDirectDisplayID?

    /// Set true while a `CGDisplayBeginConfiguration` is in flight and
    /// cleared on the matching completion callback. While set,
    /// `handleDisplayChange` defers — `NSScreen.screens` may be stale
    /// during the transition window, and acting on stale data is what
    /// produced the wake bug (helper built at Edge@(0,0) just before
    /// LG joined and Edge moved). Set/cleared on the main actor only.
    private var isTopologyTransitioning: Bool = false

    /// CoreGraphics reconfiguration callback. Defined as a property (not
    /// inline) so the same function pointer can be passed to both
    /// `CGDisplayRegisterReconfigurationCallback` and the matching
    /// `CGDisplayRemoveReconfigurationCallback` in `deinit` — the OS uses
    /// the callback pointer + userInfo as the lookup key for unregistration.
    private let cgReconfigCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard let userInfo = userInfo else { return }
        let dm = Unmanaged<DisplayManager>.fromOpaque(userInfo).takeUnretainedValue()
        let flagsValue = flags.rawValue
        Task { @MainActor in
            dm.handleCGDisplayReconfiguration(displayID: displayID, rawFlags: flagsValue)
        }
    }

    /// Periodic device-ID refresh interval. 60 s is a deliberate balance:
    /// short enough that a missed wake notification still self-heals within a
    /// minute, long enough that the IOKit enumeration cost is negligible.
    private static let deviceIDRefreshInterval: TimeInterval = 60.0

    // MARK: - Display-Change Debounce
    //
    // A single user action (toggle fullscreen, Hide/Show Panel, sleep/wake)
    // produces 4-6 `didChangeScreenParametersNotification` events in rapid
    // succession. Without coalescing, each re-entry of `handleDisplayChange`
    // independently decides to tear down and rebuild the fullscreen helper,
    // which amplifies races between panel/helper lifecycle and produces
    // stuck-black panels, orphaned helpers, and incorrect `isActive` state.
    //
    // Self-induced bursts (helper teardown → rebuild triggers more
    // notifications) are expected — they coalesce into one final call
    // after the topology settles, which is the desired behaviour.

    /// Debounce window for coalescing display-change notifications.
    /// Shorter than the ~300-500 ms bursts produced by fullscreen
    /// transitions so that legitimate rapid reconfigurations (plug in
    /// then out within ~150 ms) still get handled reasonably.
    private static let displayChangeDebounceMs = 150

    /// Pending debounced invocation of `handleDisplayChange`. Cancelled
    /// and replaced on each incoming notification — only the final one
    /// executes.
    private var pendingDisplayChange: DispatchWorkItem?

    /// Number of notifications coalesced into the currently-pending
    /// invocation. Reset to zero once `handleDisplayChange` runs.
    private var coalescedDisplayChangeCount: Int = 0

    /// Invoked every time `showPanel()` creates a new `LedgePanel` instance.
    ///
    /// AppDelegate wires this to re-attach the dashboard content view and
    /// re-apply panel transparency. Without it, a rebuild after sleep/wake
    /// or Force Unblank produces a panel with no content — opaque black
    /// because `LedgePanel.backgroundColor = .black`.
    var onPanelCreated: (@MainActor () -> Void)?

    // MARK: - Lifecycle

    init() {
        guard !AppEnvironment.isTesting else { return }
        registerForDisplayChanges()
        registerForSecurityEvents()
        detectXenonEdge()
    }

    deinit {
        for observer in securityObservers {
            NotificationCenter.default.removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        // Match the CGDisplayRegisterReconfigurationCallback in
        // registerForDisplayChanges. The OS uses (callback, userInfo) as
        // the lookup key for unregistration. We're allowed to compute
        // Unmanaged.passUnretained(self).toOpaque() inside deinit because
        // `passUnretained` doesn't touch the reference count.
        let context = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(cgReconfigCallback, context)
    }

    // MARK: - Display Detection

    /// Scan connected screens to find the Xeneon Edge.
    func detectXenonEdge() {
        let screens = NSScreen.screens

        logger.info("Scanning \(screens.count) connected screen(s) for Xeneon Edge...")

        // Strategy 1: Match by resolution (2560×720 is very distinctive)
        if let match = screens.first(where: { isXenonEdgeByResolution($0) }) {
            foundXenonEdge(match, method: "resolution")
            return
        }

        // Strategy 2: Match by display name (from IOKit display info)
        if let match = screens.first(where: { isXenonEdgeByName($0) }) {
            foundXenonEdge(match, method: "name")
            return
        }

        // Not found
        xeneonScreen = nil
        isActive = false
        statusMessage = "Xeneon Edge not detected. Connect the display and it will be detected automatically."
        logger.warning("Xeneon Edge not found among \(screens.count) screen(s)")

        // Log available screens for debugging
        for (index, screen) in screens.enumerated() {
            let frame = screen.frame
            let name = screen.localizedName
            logger.info("  Screen \(index, privacy: .public): \(name, privacy: .public) — \(Int(frame.width), privacy: .public)×\(Int(frame.height), privacy: .public) at (\(Int(frame.origin.x), privacy: .public),\(Int(frame.origin.y), privacy: .public))")
        }
    }

    /// Manually select a screen to use (fallback when auto-detection fails).
    func selectScreen(_ screen: NSScreen) {
        foundXenonEdge(screen, method: "manual selection")
    }

    // MARK: - Panel Management

    /// Show the panel on the Xeneon Edge.
    ///
    /// Uses a fullscreen helper window to create a dedicated fullscreen Space on the Edge,
    /// which auto-hides the menu bar — the same mechanism Safari, Chrome, and Parallels use.
    /// With "Displays have separate Spaces" enabled, each display manages its own Spaces
    /// independently so this does NOT affect Space switching on the primary display.
    func showPanel() {
        logSnapshot("showPanel-entry")
        guard let screen = xeneonScreen else {
            logger.error("Cannot show panel: no Xeneon Edge screen detected")
            return
        }

        // Intentional reveal — clear any stuck blanking state. If the system is
        // still locked, `screenIsLocked` has already re-blanked (or will).
        unblankDisplay(reason: "panel shown")

        if panel == nil {
            panel = LedgePanel(on: screen)
            touchRemapper.panel = panel
            hidTouchReader.panel = panel

            // Wire delivery confirmation for latency tracking.
            // When the panel receives a touch event via sendEvent(), record the
            // delivery timestamp and update the flight recorder entry.
            panel?.onEventReceived = { [weak self] _ in
                let deliveryTime = Date()
                guard let self else { return }
                // The most recent flight recorder entry corresponds to this delivery.
                // Compute latency = delivery time - event arrival time.
                if let lastEntry = self.flightRecorder.recentEntries(count: 1).last,
                   lastEntry.deliveryLatencyMs == nil {
                    let latencyMs = deliveryTime.timeIntervalSince(lastEntry.timestamp) * 1000.0
                    self.flightRecorder.updateLatency(sequenceID: lastEntry.sequenceID, latencyMs: latencyMs)
                }
            }

            // Re-snap the panel onto the Edge if AppKit silently migrates it
            // to another display during a topology shift. Architect-flagged
            // recovery path — pairs with installHelperScreenObserver for the
            // helper. Only the DisplayManager knows which screen *should*
            // host the panel, so the panel just notifies us and we decide.
            panel?.onScreenMigrated = { [weak self] newScreen in
                guard let self, let edge = self.xeneonScreen else { return }
                if newScreen?.displayID != edge.displayID {
                    self.logger.warning("Panel migrated off Edge — re-snapping. panel.screen.displayID=\(newScreen?.displayID.map(String.init) ?? "nil", privacy: .public), xeneonScreen.displayID=\(edge.displayID.map(String.init) ?? "nil", privacy: .public)")
                    self.panel?.reposition(on: edge)
                    self.logSnapshot("panelMigrationRecovery")
                }
            }

            logger.notice("Created LedgePanel on Xeneon Edge")

            // A fresh panel has no contentView. Ask the owner (AppDelegate)
            // to re-attach the dashboard and re-apply transparency. Without
            // this, the first-launch content-attach path is the only one
            // that runs, so any rebuild after sleep/wake or Force Unblank
            // produces a content-less black panel.
            onPanelCreated?()
        }

        // Enter fullscreen on the Edge to auto-hide the menu bar via the
        // fullscreen helper. The LedgePanel's .fullScreenAuxiliary collection
        // behavior makes it render on top of the fullscreen Space.
        //
        // The fullscreen transition is async (~1-2s). During that window macOS
        // may rearrange displays (sleep/wake, cable hot-plug), leaving the
        // captured `screen` reference with stale coordinates. Re-fetch
        // `xeneonScreen` inside the completion so revealPanel works with the
        // current Edge frame, not the one we saw when showPanel was called.
        ensureFullscreenHelper(on: screen) { [weak self] in
            guard let self else { return }
            let latestScreen = self.xeneonScreen ?? screen
            self.revealPanel(on: latestScreen)
        }
    }

    /// Actually make the panel visible. Called directly (no fullscreen helper needed)
    /// or after the fullscreen helper finishes its transition.
    private func revealPanel(on screen: NSScreen) {
        logSnapshot("revealPanel-entry")

        // If we reach here without a panel the caller has raced us — typically
        // a display-change notification rebuilt the fullscreen helper after a
        // disconnect destroyed the panel. Never claim the panel is visible
        // when it isn't: tear the orphaned helper down and surface the state.
        guard let panel else {
            logger.error("revealPanel called with no panel — tearing down orphaned helper")
            tearDownFullscreenHelper()
            isActive = false
            statusMessage = "Panel lost — press Show Panel to recover"
            logSnapshot("revealPanel-exit-noPanel")
            return
        }

        // The panel is about to be made visible — ensure its contentView isn't
        // still hidden from an earlier blank that never unblanked cleanly.
        unblankDisplay(reason: "panel revealed")

        // Always trust `xeneonScreen` over the captured `screen`. `screen` is
        // captured at showPanel time into the fullscreen-helper completion
        // closure, then used ~1–2s later after the fullscreen transition
        // completes. If macOS moved the Edge during that window (sleep/wake,
        // display rearrangement), the captured NSScreen holds stale coords
        // and the panel would reveal at the old position — shifted off the
        // current Edge. Re-fetching closes the race.
        let effectiveFrame = xeneonScreen?.frame ?? screen.frame
        panel.setFrame(effectiveFrame, display: true, animate: false)

        // Use orderFrontRegardless + makeKey separately instead of makeKeyAndOrderFront.
        // makeKeyAndOrderFront can trigger app activation even on .nonactivatingPanel.
        // orderFrontRegardless brings the panel forward without activating the app.
        NSApp.preventWindowOrdering()
        panel.orderFrontRegardless()
        panel.makeKey()
        isActive = true
        // Record user intent — set AFTER the nil-guard and the ordering
        // calls, so failed reveals do not flip the flag. `hidePanel` clears
        // it; `destroyPanel` deliberately does not (disconnect is transient).
        wasActive = true
        statusMessage = "Active on \(screen.localizedName)"
        logger.notice("Panel is now visible on Xeneon Edge")

        // If the fullscreen helper briefly activated the app, yield focus back.
        // NSApp.deactivate() lets the previously active app regain focus.
        if fullscreenHelper != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.deactivate()
            }
        }

        logSnapshot("revealPanel-exit")
    }

    /// Lightweight panel re-assertion — restores window level and ordering
    /// without rebuilding the fullscreen helper. Safe to call after activation
    /// policy changes because it avoids `toggleFullScreen` which can trigger
    /// macOS window management on the main display.
    func reassertPanelPosition(on screen: NSScreen) {
        panel?.level = .screenSaver
        panel?.setFrame(screen.frame, display: true, animate: false)
        panel?.orderFrontRegardless()
    }

    /// Re-assert the fullscreen helper and panel positioning after an event
    /// that may have destabilized the fullscreen Space (e.g., activation policy
    /// switch from `.regular` to `.accessory` when the settings window closes).
    func reassertFullscreen(on screen: NSScreen) {
        if let helper = fullscreenHelper, !helper.styleMask.contains(.fullScreen) {
            // Helper lost fullscreen state — rebuild it
            logger.info("Fullscreen helper lost fullscreen state — rebuilding")
            tearDownFullscreenHelper()
            ensureFullscreenHelper(on: screen) { [weak self] in
                self?.revealPanel(on: screen)
            }
        } else if fullscreenHelper == nil && isActive {
            // Helper was destroyed — recreate it
            logger.info("Fullscreen helper missing — recreating")
            ensureFullscreenHelper(on: screen) { [weak self] in
                self?.revealPanel(on: screen)
            }
        } else {
            // Helper is fine — just re-assert panel position and window level
            panel?.level = .screenSaver
            panel?.setFrame(screen.frame, display: true, animate: false)
            panel?.orderFrontRegardless()
        }
    }

    /// Hide the panel (but keep the screen reference).
    func hidePanel() {
        logSnapshot("hidePanel-entry")
        let hadPanel = panel != nil
        panel?.orderOut(nil)
        isActive = false
        // Explicit user dismiss — clear intent so reconnects don't auto-restore.
        wasActive = false
        tearDownFullscreenHelper()
        statusMessage = "Panel hidden (Xeneon Edge still connected)"
        logger.notice("hidePanel: orderOut called (hadPanel=\(hadPanel, privacy: .public))")
        logSnapshot("hidePanel-exit")
    }

    /// Completely tear down the panel.
    func destroyPanel() {
        logSnapshot("destroyPanel-entry")
        panel?.orderOut(nil)
        touchRemapper.panel = nil
        // Previously only `touchRemapper.panel` was cleared. The hid reader's
        // strong reference kept the LedgePanel alive after `panel = nil`, so
        // its screen-change observer continued firing — logs showed "Panel
        // changed screen → XENEON EDGE" events arriving *after* destroyPanel
        // completed. Clearing both references ensures the panel actually
        // deallocates when we ask it to.
        hidTouchReader.panel = nil
        panel = nil
        isActive = false
        tearDownFullscreenHelper()
        logger.notice("Panel destroyed")
        logSnapshot("destroyPanel-exit")
    }

    /// Set the SwiftUI content view on the panel.
    func setPanelContent<Content: View>(_ content: Content) {
        guard let panel else {
            logger.error("Cannot set content: panel not created")
            return
        }

        let hostingView = NSHostingView(rootView: content)
        panel.contentView = hostingView
    }

    // MARK: - Display Change Notifications

    private func registerForDisplayChanges() {
        // CoreGraphics-level reconfiguration callback — architect-flagged.
        //
        // Fires DURING topology reconfiguration (not after, like
        // didChangeScreenParametersNotification), with per-display flags
        // telling us exactly what's happening:
        //
        //   kCGDisplayBeginConfigurationFlag — reconfiguration starting;
        //       NSScreen.screens may still hold stale data. Set our
        //       isTopologyTransitioning flag so handleDisplayChange refuses
        //       to act on intermediate state.
        //   (zero flags after kCGDisplayBeginConfigurationFlag)
        //       — reconfiguration complete; clear the flag and trigger a
        //       fresh handleDisplayChange.
        //   kCGDisplayMovedFlag — display's frame.origin changed (the
        //       "Edge moved from (0,0) to (548,-720)" signal we couldn't
        //       see before). Logged for diagnostics.
        //   kCGDisplayAddFlag / kCGDisplayRemoveFlag — display attached/
        //       detached. Logged.
        //   kCGDisplayDesktopShapeChangedFlag — overall desktop bounds
        //       changed. Logged.
        //
        // Threading: callback fires on a private CG thread, NOT the main
        // thread. The Task @MainActor hop is mandatory.
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = CGDisplayRegisterReconfigurationCallback(cgReconfigCallback, context)
        if status == .success {
            logger.info("CGDisplay reconfiguration callback registered")
        } else {
            logger.error("CGDisplayRegisterReconfigurationCallback returned \(status.rawValue, privacy: .public) — falling back to NSApplication notifications only")
        }

        // Watch for screen configuration changes (connect/disconnect/rearrange).
        // Notifications arrive in bursts — see the debounce note above.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hop back to MainActor to satisfy Swift 6 concurrency
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Diagnostic: log every RAW notification before the debounce
                // collapses bursts. Lets us prove whether a wake actually
                // produces a screen-parameters notification at all, and how
                // many it produces in a burst.
                let allScreens = NSScreen.screens.map { s -> String in
                    let id = s.displayID.map(String.init) ?? "?"
                    return "\(s.localizedName)#\(id)@\(NSStringFromRect(s.frame))"
                }.joined(separator: " | ")
                self.logger.notice("RAW didChangeScreenParameters fired — screens=[\(allScreens, privacy: .public)]")
                self.logSnapshot("rawScreenChange")
                self.scheduleDisplayChange()
            }
        }
    }

    /// Process a CoreGraphics display reconfiguration callback (architect-
    /// flagged early signal). See `registerForDisplayChanges` for context.
    ///
    /// The flag set determines what we do:
    ///   - `kCGDisplayBeginConfigurationFlag` present → reconfiguration is
    ///     starting, set `isTopologyTransitioning = true` so handleDisplay-
    ///     Change refuses to act on intermediate state.
    ///   - flags with NO `kCGDisplayBeginConfigurationFlag` → reconfiguration
    ///     for this display is complete. Clear the flag and trigger a fresh
    ///     handleDisplayChange.
    func handleCGDisplayReconfiguration(displayID: CGDirectDisplayID, rawFlags: UInt32) {
        let flags = CGDisplayChangeSummaryFlags(rawValue: rawFlags)
        let beginning = flags.contains(.beginConfigurationFlag)

        // Build a human-readable description of the flags for the log.
        var parts: [String] = []
        if flags.contains(.addFlag) { parts.append("add") }
        if flags.contains(.removeFlag) { parts.append("remove") }
        if flags.contains(.movedFlag) { parts.append("moved") }
        if flags.contains(.setMainFlag) { parts.append("setMain") }
        if flags.contains(.setModeFlag) { parts.append("setMode") }
        if flags.contains(.desktopShapeChangedFlag) { parts.append("desktopShape") }
        if flags.contains(.enabledFlag) { parts.append("enabled") }
        if flags.contains(.disabledFlag) { parts.append("disabled") }
        if flags.contains(.mirrorFlag) { parts.append("mirror") }
        if flags.contains(.unMirrorFlag) { parts.append("unmirror") }
        let flagDesc = parts.isEmpty ? "none" : parts.joined(separator: "+")

        if beginning {
            isTopologyTransitioning = true
            logger.notice("CG reconfig BEGIN — displayID=\(displayID, privacy: .public) flags=[\(flagDesc, privacy: .public)]")
        } else {
            isTopologyTransitioning = false
            logger.notice("CG reconfig COMPLETE — displayID=\(displayID, privacy: .public) flags=[\(flagDesc, privacy: .public)]")
            // Trigger a debounced handleDisplayChange so we re-evaluate
            // topology with `NSScreen.screens` now in its post-transition
            // state.
            scheduleDisplayChange()
        }
    }

    /// Coalesce bursts of `didChangeScreenParametersNotification` into a
    /// single `handleDisplayChange` invocation once the burst settles.
    ///
    /// `DispatchWorkItem` over `Timer` is deliberate — reliable across
    /// run-loop modes and does not retain `self` via the block.
    private func scheduleDisplayChange() {
        coalescedDisplayChangeCount += 1
        pendingDisplayChange?.cancel()

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let coalesced = self.coalescedDisplayChangeCount
            self.coalescedDisplayChangeCount = 0
            self.pendingDisplayChange = nil
            self.handleDisplayChange(coalescedEvents: coalesced)
        }
        pendingDisplayChange = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.displayChangeDebounceMs),
            execute: work
        )
    }

    private func handleDisplayChange(coalescedEvents: Int = 1) {
        logger.info("Display configuration changed (coalesced \(coalescedEvents, privacy: .public) events), re-scanning...")

        // Architect-flagged: defer if a CG reconfiguration is in flight.
        // NSScreen.screens may hold stale data during the transition window;
        // acting on it produces the wake bug (helper built at Edge@(0,0)
        // just before LG joined). The CG completion callback will fire
        // scheduleDisplayChange() once the transition settles, so dropping
        // this invocation is safe — we'll re-enter cleanly.
        if isTopologyTransitioning {
            logger.notice("handleDisplayChange deferred — CG reconfiguration in flight")
            logSnapshot("handleDisplayChange-deferred")
            return
        }

        logSnapshot("handleDisplayChange-entry")

        let previousScreen = xeneonScreen
        let previousFrame = previousScreen?.frame
        let previousDisplayID = previousScreen?.displayID
        let previousIdentity = previousScreen.map { ObjectIdentifier($0).hashValue }

        detectXenonEdge()

        // Diagnostic — emit BEFORE we branch so the log records exactly what
        // changed (or didn't) between previous and current Edge state. Three
        // independent change axes:
        //   - identity:  NSScreen pointer reused vs new instance
        //   - frame:     global-coordinate frame shifted (topology)
        //   - displayID: physical display swapped (CGDirectDisplayID)
        // Today's branch only fires on identity change — so if frame or
        // displayID change without identity changing, we silently no-op.
        let currentFrame = xeneonScreen?.frame
        let currentDisplayID = xeneonScreen?.displayID
        let currentIdentity = xeneonScreen.map { ObjectIdentifier($0).hashValue }
        let identityChanged = currentIdentity != previousIdentity
        let frameChanged    = currentFrame != previousFrame
        let displayIDChanged = currentDisplayID != previousDisplayID
        logger.notice("handleDisplayChange diff: identity changed=\(identityChanged, privacy: .public) (\(previousIdentity.map(String.init) ?? "nil", privacy: .public)→\(currentIdentity.map(String.init) ?? "nil", privacy: .public)) | frame changed=\(frameChanged, privacy: .public) (\(previousFrame.map(NSStringFromRect) ?? "nil", privacy: .public)→\(currentFrame.map(NSStringFromRect) ?? "nil", privacy: .public)) | displayID changed=\(displayIDChanged, privacy: .public) (\(previousDisplayID.map(String.init) ?? "nil", privacy: .public)→\(currentDisplayID.map(String.init) ?? "nil", privacy: .public))")

        if let currentScreen = xeneonScreen {
            // Topology comparison — frame OR displayID, NOT NSScreen identity.
            //
            // Earlier we included `identityChanged` in this OR, but log
            // evidence showed AppKit oscillates the NSScreen instance
            // pointer across helper build/teardown cycles even when the
            // physical topology is unchanged: the identity hash flipped
            // between two stable values (6729052564448237736 and
            // 6233674584976057384) on every fullscreen transition we
            // initiated ourselves. That kicked off a self-induced feedback
            // loop:
            //
            //   helper teardown → didChangeScreenParameters → identityChanged
            //     → "Xeneon Edge repositioned" → rebuild helper → didChange…
            //     → identityChanged → … (forever, plus a HID device-ID leak
            //     because each pass pumps refreshTouchDeviceIDs)
            //
            // Frame and displayID are the only axes that mean "the physical
            // topology actually changed". NSScreen identity churn is AppKit-
            // internal noise and must NOT trigger a rebuild — otherwise we
            // become our own perpetual-motion machine.
            //
            // The frame check still catches the original Bug 2 (Edge moved
            // (0,0)→(548,-720) when LG re-joined). The displayID check
            // catches a physical-display swap. Identity is preserved in
            // diagnostic logs only.
            let topologyChanged = frameChanged || displayIDChanged
            if topologyChanged {
                // Screen changed (e.g., rearranged, or Edge returned after disconnect).
                logger.info("Xeneon Edge repositioned, updating panel frame and touch target")
                // Display topology changed — clear any stuck blanking so the
                // rebuilt panel renders widgets instead of a black rectangle.
                unblankDisplay(reason: "display topology changed")

                // These updates are safe whether or not a panel currently exists —
                // they prime the touch pipeline for the current Edge geometry.
                touchRemapper.updateTargetScreen(currentScreen)
                hidTouchReader.updatePanelFrame(currentScreen.frame)
                mouseGuard.updateEdgeScreen(currentScreen)

                // Display-topology changes (attach/detach of any monitor)
                // can cause the Edge to re-enumerate too — not just sleep.
                // Refresh the touch device IDs so the filter doesn't go
                // stale silently.
                refreshTouchDeviceIDs(reason: "display change")

                if panel == nil && wasActive {
                    // Transient disconnect (sleep/wake, cable flap) destroyed
                    // the panel — but the user wanted it visible. Restore it.
                    // `showPanel()` creates the panel, builds a new fullscreen
                    // helper, and re-attaches content via `onPanelCreated`.
                    logger.notice("handleDisplayChange: panel missing, wasActive=true — auto-restoring via showPanel")
                    showPanel()
                } else {
                    // Panel survived (or user had dismissed it) — reposition
                    // what we have and rebuild the helper's Space for the new
                    // screen frame.
                    panel?.reposition(on: currentScreen)

                    // State-machine-gated rebuild — architect-flagged.
                    //
                    // If we're mid-transition (`.building` or `.tearing`),
                    // queue this displayID and bail. The in-flight transition's
                    // completion handler will drain the queue and re-enter.
                    // This prevents the timer-cascade race that produced the
                    // wake-orphan bug (concurrent tearDown + asyncAfter rebuild
                    // + 2s fullscreen-entry timeout all firing against
                    // overlapping helper instances).
                    if fullscreenHelper != nil {
                        switch helperState {
                        case .building, .tearing:
                            if let id = currentScreen.displayID {
                                pendingRebuildDisplayID = id
                                logger.info("Queued rebuild for displayID=\(id, privacy: .public) — helper transition in flight")
                            }
                        case .none, .ready:
                            logger.info("Rebuilding fullscreen helper for new screen frame")
                            // Sequential: tearDown → ensureFullscreenHelper →
                            // revealPanel. The `then:` callback fires off the
                            // actual didExitFullScreen notification (or its
                            // cancellable fallback), not a fragile 0.5s timer.
                            tearDownFullscreenHelper { [weak self] in
                                guard let self, let screen = self.xeneonScreen else { return }
                                self.ensureFullscreenHelper(on: screen) { [weak self] in
                                    guard let self, let screen = self.xeneonScreen else { return }
                                    self.revealPanel(on: screen)
                                }
                            }
                        }
                    }
                }
            }
        } else if previousScreen != nil {
            // Xeneon Edge was disconnected
            logger.info("Xeneon Edge disconnected")
            destroyPanel()
            statusMessage = "Xeneon Edge disconnected. Waiting for reconnection..."
        }

        logSnapshot("handleDisplayChange-exit")
    }

    // MARK: - Touch Remapper Management

    /// Start the touch remapper. Requests Accessibility permissions if needed
    /// and polls until granted, then automatically starts the event tap and calibration.
    /// Request Accessibility permission upfront and call completion when granted.
    /// This must happen BEFORE the fullscreen helper covers the Edge display,
    /// otherwise the system permission dialog gets hidden behind the fullscreen Space.
    func ensureAccessibilityPermission(then completion: @escaping () -> Void) {
        // Skip permission checks in test environment
        guard !AppEnvironment.isTesting else {
            completion()
            return
        }

        if touchRemapper.checkAccessibilityPermissions() {
            accessibilityPermission = .granted
            completion()
            return
        }

        // Request — this shows the system dialog
        touchRemapper.requestAccessibilityPermissions()
        accessibilityPermission = .waiting
        logger.info("Accessibility permission requested — waiting before fullscreen")

        // Store the completion to call after permission is granted
        accessibilityPermissionCompletion = completion

        // Poll until granted
        beginAccessibilityPermissionPolling()

        // Timeout: if permission isn't granted within 8 seconds, proceed anyway.
        // This handles the case where the binary has changed (e.g., during
        // development) and macOS has a stale Accessibility entry — the system
        // won't prompt again, so we'd wait forever. The panel and widgets work
        // fine without Accessibility; only touch remapping is affected.
        // We continue polling in the background so touch remapping starts
        // automatically once the user fixes the permission.
        DispatchQueue.main.asyncAfter(deadline: .now() + 8.0) { [weak self] in
            guard let self, self.accessibilityPermissionCompletion != nil else { return }
            self.logger.warning("Accessibility permission timeout — proceeding without touch remapping. The user may need to remove and re-add Ledge in System Settings > Privacy > Accessibility")
            let cb = self.accessibilityPermissionCompletion
            self.accessibilityPermissionCompletion = nil
            cb?()
            // Keep polling — when permission is eventually granted,
            // startTouchRemapper() can be called from Settings or the
            // polling callback will update the state.
        }
    }

    func startTouchRemapper() {
        // Never attempt CGEventTap / Accessibility in test environment
        guard !AppEnvironment.isTesting else { return }

        guard xeneonScreen != nil else {
            accessibilityPermission = .unknown
            logger.warning("Cannot start touch remapper: Xeneon Edge not detected")
            return
        }

        if !touchRemapper.checkAccessibilityPermissions() {
            touchRemapper.requestAccessibilityPermissions()
            accessibilityPermission = .waiting
            beginPermissionPolling()
            logger.info("Accessibility permission requested — polling for grant")
            return
        }

        accessibilityPermission = .granted
        proceedWithTouchRemapper()
    }

    /// Stop the touch remapper and reset all touch state.
    func stopTouchRemapper() {
        // Stop HID reader first, then CGEventTap
        hidTouchReader.stop()
        isHIDTouchReaderActive = false
        touchPipelineMode = .cgEventTapOnly
        touchRemapper.suppressionOnly = false

        touchRemapper.stop()
        touchWatchdog.stop()
        mouseGuard.stop()
        tearDownPermissionPolling()
        stopDeviceIDRefreshTimer()
        isTouchRemapperActive = false
        calibrationState = .notStarted
        learnedDeviceID = nil
        lastTouchInfo = nil
        logger.info("Touch remapper stopped")
    }

    /// Start or stop the mouse guard based on current state.
    ///
    /// The mouse guard requires: (1) the toggle is enabled, (2) the touch device
    /// IDs are known (calibrated/auto-detected), and (3) the Edge screen is detected.
    private func updateMouseGuardState() {
        guard isMouseGuardEnabled,
              !touchRemapper.touchDeviceIDs.isEmpty,
              let screen = xeneonScreen else {
            if mouseGuard.isActive {
                mouseGuard.stop()
            }
            return
        }

        mouseGuard.configure(touchDeviceIDs: touchRemapper.touchDeviceIDs, edgeScreen: screen)
        if !mouseGuard.isActive {
            mouseGuard.start()
        }
    }

    /// Start calibration — the next touch event identifies the touchscreen device.
    func calibrateTouch() {
        guard touchRemapper.isActive else {
            logger.warning("Cannot calibrate: touch remapper not active")
            return
        }

        touchRemapper.startLearning()
        calibrationState = .learning

        touchRemapper.onLearningComplete = { [weak self] in
            Task { @MainActor in
                self?.calibrationState = .calibrated
                self?.learnedDeviceID = self?.touchRemapper.touchDeviceID
                self?.logger.info("Touch calibration complete — device ID: \(self?.touchRemapper.touchDeviceID ?? -1)")
            }
        }
    }

    // MARK: - Accessibility Permission Gate (pre-fullscreen)

    /// Poll for Accessibility permission before entering fullscreen.
    /// Once granted, calls the stored completion and proceeds.
    private func beginAccessibilityPermissionPolling() {
        accessibilityGateTimer?.invalidate()
        accessibilityGateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.touchRemapper.checkAccessibilityPermissions() {
                    self.accessibilityGateTimer?.invalidate()
                    self.accessibilityGateTimer = nil
                    self.accessibilityPermission = .granted

                    if let completion = self.accessibilityPermissionCompletion {
                        // Pre-timeout: fire completion to show panel
                        self.accessibilityPermissionCompletion = nil
                        self.logger.info("Accessibility permission granted — proceeding with panel")
                        completion()
                    } else {
                        // Post-timeout: panel already showing, start touch remapper now
                        self.logger.info("Accessibility permission granted (late) — starting touch remapper")
                        self.startTouchRemapper()
                    }
                }
            }
        }

        // Also check on app activation (user may grant via System Settings and switch back)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.accessibilityPermission != .granted,
                      self.touchRemapper.checkAccessibilityPermissions() else { return }
                self.accessibilityGateTimer?.invalidate()
                self.accessibilityGateTimer = nil
                self.accessibilityPermission = .granted

                if let completion = self.accessibilityPermissionCompletion {
                    self.accessibilityPermissionCompletion = nil
                    self.logger.info("Accessibility permission granted (on activation) — proceeding with panel")
                    completion()
                } else {
                    self.logger.info("Accessibility permission granted (on activation, late) — starting touch remapper")
                    self.startTouchRemapper()
                }
            }
        }
    }

    // MARK: - Permission Polling

    /// Called once Accessibility permission is confirmed granted.
    private func proceedWithTouchRemapper() {
        guard let screen = xeneonScreen else { return }

        // Auto-detect the touchscreen device via IOKit HID.
        // This identifies the exact USB touch controller by VID/PID, eliminating
        // the need for manual calibration (which was unreliable — it often
        // captured the mouse instead of the touchscreen).
        if let result = hidDetector.detect() {
            touchRemapper.setTouchDeviceIDs(result.allDeviceIDs)
            calibrationState = .autoDetected
            learnedDeviceID = result.allDeviceIDs.sorted().last  // show highest ID in UI (likely the event driver)
            logger.info("Auto-detected touchscreen: \(result.product ?? "unknown") (\(result.allDeviceIDs.count) possible IDs)")
        } else {
            logger.warning("Could not auto-detect touchscreen — manual calibration available via Settings")
            calibrationState = .notStarted
        }

        // Wire up the diagnostics event callback — feeds both lastTouchInfo (UI) and flight recorder
        touchRemapper.onEventProcessed = { [weak self] deviceID, original, remapped, eventTypeRaw, delivered, seqID, arrivalTime in
            // Record in flight recorder (thread-safe, fast)
            let entry = TouchFlightRecorder.Entry(
                timestamp: arrivalTime,
                sequenceID: seqID,
                deviceID: deviceID,
                originalPoint: original,
                remappedPoint: remapped,
                eventType: .init(cgEventType: eventTypeRaw),
                deliveryStatus: delivered ? .delivered : .dropped,
                deliveryLatencyMs: nil  // Updated by panel delivery confirmation
            )
            self?.flightRecorder.append(entry)

            // Notify watchdog of event activity (heartbeat for dead tap detection)
            Task { @MainActor in
                self?.touchWatchdog.recordEventActivity()

                // Track touch sequence lifecycle so the watchdog only flags
                // stalls during active sequences, not idle periods.
                let eventKind = TouchFlightRecorder.EventKind(cgEventType: eventTypeRaw)
                if eventKind == .down {
                    self?.touchWatchdog.touchSequenceStarted()
                } else if eventKind == .up {
                    self?.touchWatchdog.touchSequenceEnded()
                }
            }

            // Update UI state on MainActor
            Task { @MainActor in
                self?.lastTouchInfo = TouchEventInfo(
                    deviceID: deviceID,
                    originalPoint: original,
                    remappedPoint: remapped,
                    timestamp: arrivalTime
                )
            }
        }

        touchRemapper.start(targetScreen: screen)
        isTouchRemapperActive = touchRemapper.isActive

        // Start the watchdog to monitor event tap health
        if let tap = touchRemapper.eventTap {
            touchWatchdog.start(tap: tap)
            
            // Wire watchdog callbacks for enhanced monitoring
            touchWatchdog.getLastEventTimestamp = { [weak self] in
                self?.flightRecorder.recentEntries(count: 1).last?.timestamp
            }
            touchWatchdog.getTotalEventCount = { [weak self] in
                self?.flightRecorder.totalRecorded ?? 0
            }

            // Wire tap recreation for when re-enable fails repeatedly
            touchWatchdog.onTapRecreatNeeded = { [weak self] in
                guard let self else { return nil }
                self.touchRemapper.recreateTap()
                return self.touchRemapper.eventTap
            }
        }

        // Start the mouse guard if enabled and device IDs are known
        updateMouseGuardState()

        // HID Touch Reader is DISABLED by default. It requires Input Monitoring
        // permission (separate from Accessibility) and the callback never fires
        // without it. When it fails, suppressionOnly mode causes a touch deadlock
        // for 5 seconds until the fallback kicks in. CGEventTap remapping works
        // reliably, so we skip HID entirely until Input Monitoring is confirmed.
        // TODO: Re-enable when Input Monitoring permission flow is implemented.
        if touchRemapper.isActive {
            // startHIDTouchReader(screen: screen)

            if calibrationState == .autoDetected {
                logger.info("Event tap active — touchscreen auto-detected, ready for input")
            } else {
                logger.info("Event tap active — use Settings to calibrate touch device")
            }

            // Arm the periodic device-ID refresh as a safety net for
            // re-enumerations that arrive without a wake/screen-change
            // notification. Wake/display-change traps still do the prompt
            // self-heal; this just bounds the worst case.
            startDeviceIDRefreshTimer()
        } else {
            logger.error("Event tap failed to start")
        }
    }

    // MARK: - Touch Device ID Refresh
    //
    // The Xeneon Edge re-enumerates on the USB bus across sleep/wake (and
    // on some display reconfigurations). macOS hands fresh IOKit registry
    // entry IDs to its IOService descendants. CGEvent field 87 reports
    // those IDs, so the cached `touchRemapper.touchDeviceIDs` set goes
    // stale and every touch event silently passes through unmodified.
    //
    // The CGEventTap is healthy and the events are flowing — they just
    // don't match the filter — so neither the tap-disabled paths nor
    // `TouchWatchdog`'s heartbeat (which only fires after the filter
    // passes) catch this. The refresh below is the targeted fix: re-run
    // IOKit enumeration, diff against the current set, swap in-place.
    // No tap teardown.

    /// Re-enumerate the Edge via IOKit and update `touchRemapper.touchDeviceIDs`
    /// in place if the set has changed. Lightweight — safe to call frequently
    /// (called from wake / display-change traps and a 60s timer).
    ///
    /// On a real change: bumps `deviceIDChangeCount`, sets
    /// `lastDeviceIDChangeAt` / `lastDeviceIDChangeReason`, and writes a
    /// single `notice`-level log entry with old + new sets. On no change:
    /// silent (avoid log spam from the periodic timer).
    ///
    /// `reason` is for telemetry — typical values: `"system woke"`,
    /// `"displays woke"`, `"display change"`, `"periodic"`, `"user"`.
    func refreshTouchDeviceIDs(reason: String) {
        guard !AppEnvironment.isTesting else { return }
        guard isTouchRemapperActive else { return }

        guard let result = hidDetector.detect() else {
            // Common during transient disconnects — Edge briefly absent
            // from IOKit. Don't touch the cached IDs; the next refresh
            // will pick the device up when it re-appears.
            logger.info("Device ID refresh (\(reason, privacy: .public)) — Edge not currently visible to IOKit")
            return
        }

        let oldIDs = touchRemapper.touchDeviceIDs
        let newIDs = result.allDeviceIDs

        guard oldIDs != newIDs else { return }

        touchRemapper.setTouchDeviceIDs(newIDs)
        // Refresh the UI-facing learned ID — show the highest registry
        // entry, matching the convention used at proceedWithTouchRemapper.
        learnedDeviceID = newIDs.sorted().last
        // If we'd previously fallen through to manual calibration mode,
        // the auto-detect just succeeded again — reflect that.
        calibrationState = .autoDetected

        deviceIDChangeCount += 1
        lastDeviceIDChangeAt = Date()
        lastDeviceIDChangeReason = reason

        logger.notice("Touch device IDs refreshed (reason=\(reason, privacy: .public), change #\(self.deviceIDChangeCount, privacy: .public)) old=\(oldIDs.sorted(), privacy: .public) new=\(newIDs.sorted(), privacy: .public)")

        // The mouse guard's filter set must track the touch IDs too,
        // otherwise it'd let a re-enumerated touch through as a mouse.
        updateMouseGuardState()
    }

    /// Start the periodic device-ID refresh timer. Idempotent.
    private func startDeviceIDRefreshTimer() {
        guard deviceIDRefreshTimer == nil else { return }
        deviceIDRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: Self.deviceIDRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTouchDeviceIDs(reason: "periodic")
            }
        }
        logger.info("Device ID refresh timer armed (every \(Int(Self.deviceIDRefreshInterval), privacy: .public)s)")
    }

    /// Stop the periodic device-ID refresh timer. Idempotent.
    private func stopDeviceIDRefreshTimer() {
        deviceIDRefreshTimer?.invalidate()
        deviceIDRefreshTimer = nil
    }

    // MARK: - HID Touch Reader Management

    /// Attempt to start the IOKit HID direct touch reader.
    ///
    /// When successful, `TouchRemapper` switches to suppression-only mode:
    /// it still intercepts and drops the wrongly-mapped mouse events, but
    /// `HIDTouchReader` handles actual touch delivery from raw reports.
    private func startHIDTouchReader(screen: NSScreen) {
        hidTouchReader.panel = panel
        // Set debug count BEFORE start() so it's visible in the startup log
        hidTouchReader.debugReportLogCount = 10
        hidTouchReader.start(panelFrame: screen.frame)

        guard hidTouchReader.isActive else {
            // HID reader failed — fall back to CGEventTap remapping
            touchRemapper.suppressionOnly = false
            isHIDTouchReaderActive = false
            touchPipelineMode = .cgEventTapOnly
            logger.warning("HID Touch Reader failed to start — falling back to CGEventTap remapping")
            return
        }

        // HID reader is active — switch TouchRemapper to suppression-only
        touchRemapper.suppressionOnly = true
        isHIDTouchReaderActive = true
        touchPipelineMode = .hidWithSuppression
        touchWatchdog.isHIDReaderActive = true

        // Wire diagnostics to flight recorder and watchdog
        hidTouchReader.onTouchEvent = { [weak self] contact, eventType, seqID, arrivalTime in
            guard let self else { return }

            let flightEventKind: TouchFlightRecorder.EventKind
            switch eventType {
            case .down:  flightEventKind = .down
            case .moved: flightEventKind = .drag
            case .up:    flightEventKind = .up
            }

            let entry = TouchFlightRecorder.Entry(
                timestamp: arrivalTime,
                sequenceID: seqID,
                deviceID: 0,  // HID reader doesn't use CGEvent device IDs
                originalPoint: CGPoint(x: CGFloat(contact.rawX), y: CGFloat(contact.rawY)),
                remappedPoint: CGPoint(x: contact.displayX, y: contact.displayY),
                eventType: flightEventKind,
                deliveryStatus: .delivered,
                deliveryLatencyMs: nil
            )
            self.flightRecorder.append(entry)

            Task { @MainActor in
                self.touchWatchdog.recordEventActivity()
                if eventType == .down {
                    self.touchWatchdog.touchSequenceStarted()
                } else if eventType == .up {
                    self.touchWatchdog.touchSequenceEnded()
                }
            }

            Task { @MainActor in
                self.lastTouchInfo = TouchEventInfo(
                    deviceID: 0,
                    originalPoint: CGPoint(x: CGFloat(contact.rawX), y: CGFloat(contact.rawY)),
                    remappedPoint: CGPoint(x: contact.displayX, y: contact.displayY),
                    timestamp: arrivalTime
                )
            }
        }

        // Handle device disconnection — revert to CGEventTap
        hidTouchReader.onDeviceDisconnected = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.logger.warning("HID touchscreen disconnected — reverting to CGEventTap remapping")
                self.touchRemapper.suppressionOnly = false
                self.isHIDTouchReaderActive = false
                self.touchPipelineMode = .cgEventTapOnly
                self.touchWatchdog.isHIDReaderActive = false
            }
        }

        logger.info("HID Touch Reader active — TouchRemapper in suppression-only mode")

        // Fallback: if HID reader hasn't received ANY reports after 5 seconds,
        // it's not working (callback registered but never fires). Revert to
        // CGEventTap remapping so touch isn't completely dead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self,
                  self.isHIDTouchReaderActive,
                  self.hidTouchReader.totalReportCount == 0 else { return }

            self.logger.warning("⚠ HID Touch Reader received 0 reports after 5s — falling back to CGEventTap remapping")
            self.touchRemapper.suppressionOnly = false
            self.isHIDTouchReaderActive = false
            self.touchPipelineMode = .cgEventTapOnly
            self.touchWatchdog.isHIDReaderActive = false
            self.hidTouchReader.stop()
        }
    }

    /// Start polling for Accessibility permission grant (timer + app activation observer).
    private func beginPermissionPolling() {
        tearDownPermissionPolling()

        // Poll every 2 seconds
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAndProceedIfPermitted()
            }
        }

        // Also check when the user switches back to Ledge (common flow: grant in System Settings → switch back)
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
            Task { @MainActor [weak self] in
                self?.checkAndProceedIfPermitted()
            }
        }
    }

    /// Check if permission was granted and proceed if so.
    private func checkAndProceedIfPermitted() {
        guard accessibilityPermission == .waiting else {
            tearDownPermissionPolling()
            return
        }

        if touchRemapper.checkAccessibilityPermissions() {
            logger.info("Accessibility permission granted")
            accessibilityPermission = .granted
            tearDownPermissionPolling()
            proceedWithTouchRemapper()
        }
    }

    /// Clean up permission polling resources.
    private func tearDownPermissionPolling() {
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil

        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
    }

    // MARK: - Widget Permission Gate
    //
    // Before showing the panel, check if active widgets need permissions that
    // would trigger system dialogs (camera, location, calendar). Request them
    // upfront so dialogs are dismissed before the fullscreen transition starts.

    /// Show the panel only after all required widget permissions are resolved.
    ///
    /// "Resolved" means the user has responded to the dialog (granted or denied).
    /// We don't block on denied — the widget degrades gracefully. We only wait
    /// for `.notDetermined` permissions that would produce a system dialog.
    func showPanelWhenReady(requiredPermissions: Set<WidgetPermission>, then completion: @escaping () -> Void) {
        guard xeneonScreen != nil else {
            logger.error("Cannot show panel: no Xeneon Edge screen detected")
            return
        }

        // Filter to permissions the user hasn't responded to yet
        let unresolved = requiredPermissions.filter { !isPermissionResolved($0) }

        if unresolved.isEmpty {
            logger.info("All widget permissions resolved — proceeding with panel")
            permissionGateActive = false
            showPanel()
            completion()
        } else {
            logger.info("Waiting for \(unresolved.count) permission(s): \(unresolved.map(\.rawValue).joined(separator: ", "))")
            permissionGateActive = true
            gatedPermissions = unresolved
            statusMessage = "Waiting for permissions..."
            onPermissionsResolved = { [weak self] in
                self?.permissionGateActive = false
                self?.showPanel()
                completion()
            }

            // Request each unresolved permission (triggers system dialogs)
            for perm in unresolved {
                requestPermission(perm)
            }

            // Poll until all dialogs are dismissed
            beginPermissionGatePolling()
        }
    }

    /// Check if a permission has been resolved (user responded — granted or denied).
    private func isPermissionResolved(_ permission: WidgetPermission) -> Bool {
        switch permission {
        case .camera:
            return AVCaptureDevice.authorizationStatus(for: .video) != .notDetermined
        case .location:
            return CLLocationManager().authorizationStatus != .notDetermined
        case .calendar:
            return EKEventStore.authorizationStatus(for: .event) != .notDetermined
        }
    }

    /// Request a specific permission (shows system dialog if not determined).
    private func requestPermission(_ permission: WidgetPermission) {
        switch permission {
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { _ in }
        case .location:
            if gateLocationManager == nil {
                gateLocationManager = CLLocationManager()
            }
            gateLocationManager?.requestWhenInUseAuthorization()
        case .calendar:
            if gateEventStore == nil {
                gateEventStore = EKEventStore()
            }
            gateEventStore?.requestFullAccessToEvents { _, _ in }
        }
    }

    private func beginPermissionGatePolling() {
        permissionGateTimer?.invalidate()
        permissionGateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPermissionGate()
            }
        }
    }

    private func checkPermissionGate() {
        let stillUnresolved = gatedPermissions.filter { !isPermissionResolved($0) }

        if stillUnresolved.isEmpty {
            logger.info("All widget permissions resolved — showing panel")
            permissionGateTimer?.invalidate()
            permissionGateTimer = nil
            gateLocationManager = nil
            gateEventStore = nil
            gatedPermissions = []
            onPermissionsResolved?()
            onPermissionsResolved = nil
        }
    }

    // MARK: - Fullscreen Helper (Menu Bar Hiding)

    /// If a topology change request arrived while the helper was mid-transition,
    /// it was queued via `pendingRebuildDisplayID`. Now that we're in a stable
    /// state, drain the queue by re-entering `handleDisplayChange` indirectly
    /// (via `scheduleDisplayChange` so the debounce kicks in and collapses any
    /// further bursts).
    private func checkPendingRebuild() {
        guard let _ = pendingRebuildDisplayID else { return }
        pendingRebuildDisplayID = nil
        logger.info("Draining queued rebuild — re-evaluating topology")
        scheduleDisplayChange()
    }

    /// Watch for AppKit silently migrating the fullscreen helper to a different
    /// display. This is the architect-flagged orphan-detection path.
    ///
    /// When the topology shifts under a window with `.fullScreenPrimary`
    /// collection behaviour, AppKit may relocate it to a different screen
    /// rather than dragging it to follow the original screen's new position.
    /// In the wake-then-LG-rejoin reproduction, the helper was created at
    /// Edge@(0,0), then LG joined and Edge moved to (548,-720), and the
    /// helper ended up stranded inside LG's bounds — a black rectangle on
    /// the user's main display.
    ///
    /// On migration: if the helper's new screen no longer matches
    /// `xeneonScreen` (by `displayID`), tear down and rebuild via the normal
    /// `handleDisplayChange` recovery path. Comparing by `displayID` rather
    /// than NSScreen reference identity is intentional — same physical Edge
    /// often gets a fresh NSScreen pointer across topology shifts.
    private func installHelperScreenObserver(on helper: FullscreenHelperWindow) {
        if let existing = helperScreenObserver {
            NotificationCenter.default.removeObserver(existing)
            helperScreenObserver = nil
        }
        helperScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeScreenNotification,
            object: helper,
            queue: .main
        ) { [weak self, weak helper] _ in
            Task { @MainActor [weak self, weak helper] in
                guard let self, let helper = helper else { return }
                let helperDisplayID = helper.screen?.displayID
                let edgeDisplayID = self.xeneonScreen?.displayID
                if helperDisplayID != edgeDisplayID {
                    self.logger.warning("Fullscreen helper migrated to wrong screen — helper.displayID=\(helperDisplayID.map(String.init) ?? "nil", privacy: .public), xeneonScreen.displayID=\(edgeDisplayID.map(String.init) ?? "nil", privacy: .public). Tearing down for rebuild.")
                    self.logSnapshot("helperScreenMigration")
                    self.tearDownFullscreenHelper()
                    // Re-trigger the normal recovery path. handleDisplayChange
                    // is debounced and idempotent — calling it directly here
                    // (rather than waiting for a notification) closes the
                    // window where the helper sits orphan with no event to
                    // pull it back.
                    self.scheduleDisplayChange()
                }
            }
        }
    }

    /// Create a helper window that enters native macOS fullscreen on the Edge display.
    ///
    /// When a window goes fullscreen on a secondary display, macOS creates a dedicated
    /// fullscreen Space for that display and auto-hides the menu bar. This is the same
    /// mechanism used by Safari, Chrome, etc. when you click "Full Screen > Entire Screen".
    ///
    /// The LedgePanel (with `.fullScreenAuxiliary` + `.canJoinAllSpaces`) renders on top
    /// of the fullscreen helper, receiving all touch/mouse input as before.
    private func ensureFullscreenHelper(on screen: NSScreen, completion: @escaping () -> Void) {
        // If helper already exists and is in fullscreen on the *target*
        // display, proceed immediately. The target check is critical — a
        // helper fullscreen on the wrong display is just as bad as no
        // helper at all (architect-flagged orphan case).
        if let helper = fullscreenHelper,
           helper.styleMask.contains(.fullScreen),
           helper.screen?.displayID == screen.displayID {
            helperState = .ready(displayID: screen.displayID ?? 0)
            completion()
            return
        }

        // If helper exists on the WRONG display, force a teardown then rebuild.
        // This is the recovery path the helperScreenObserver triggers via
        // scheduleDisplayChange — but we also handle it defensively here.
        if let helper = fullscreenHelper,
           helper.screen?.displayID != screen.displayID {
            tearDownFullscreenHelper { [weak self] in
                guard let self else { return }
                // Re-fetch xeneonScreen in case it shifted during teardown.
                guard let latest = self.xeneonScreen else { return }
                self.ensureFullscreenHelper(on: latest, completion: completion)
            }
            return
        }

        // If helper exists but mid-transition, wait for it
        if fullscreenHelper != nil {
            observeFullscreenEntry(completion: completion)
            return
        }

        if let id = screen.displayID {
            helperState = .building(displayID: id)
        }

        // The helper needs .titled for toggleFullScreen to work. fullSizeContentView +
        // transparent titlebar makes the titlebar invisible. The window is entirely black
        // and serves only to create the fullscreen Space on the Edge display.
        //
        // This is the same mechanism used by Safari, Chrome, Parallels, etc.
        // With "Displays have separate Spaces" enabled, the fullscreen Space on the
        // Edge is completely independent of the primary display's Spaces.
        let helper = FullscreenHelperWindow(
            contentRect: screen.frame,
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        helper.titleVisibility = .hidden
        helper.titlebarAppearsTransparent = true
        helper.backgroundColor = .black
        helper.isReleasedWhenClosed = false
        helper.hasShadow = false
        helper.collectionBehavior = [.fullScreenPrimary]
        helper.setFrame(screen.frame, display: false)

        fullscreenHelper = helper
        installHelperScreenObserver(on: helper)

        // Observe fullscreen entry BEFORE triggering the transition
        observeFullscreenEntry(completion: completion)

        // toggleFullScreen requires the window to be visible and the app to be
        // momentarily active. We activate briefly, trigger fullscreen, then
        // deactivate so the user's foreground app regains focus.
        let previousApp = NSWorkspace.shared.frontmostApplication
        helper.makeKeyAndOrderFront(nil)
        helper.toggleFullScreen(nil)

        // Re-activate the previous app after a short delay to let the fullscreen
        // transition begin. The transition runs asynchronously.
        if let prevApp = previousApp, prevApp.bundleIdentifier != Bundle.main.bundleIdentifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                prevApp.activate()
            }
        }

        logger.info("Fullscreen helper created — entering fullscreen on \(screen.localizedName)")
    }

    /// Wait for the fullscreen helper to finish entering fullscreen, then call completion.
    ///
    /// Architect-flagged race: the previous implementation's 2-second timeout
    /// was a non-cancellable `asyncAfter`. When a rapid rebuild re-installed a
    /// new observer (and a new 2s timer) before the *previous* timer fired,
    /// the old timer would see `fullscreenObserver != nil` (now belonging to
    /// the new observer), remove the *new* observer, and call completion
    /// prematurely. This was the smoking gun in the wake reproduction at
    /// 08:28:14.893 ("Fullscreen entry timed out — showing panel anyway").
    ///
    /// Fix: store the timeout as a `DispatchWorkItem` so we can cancel it
    /// when the notification arrives, when a new observer takes over, or
    /// when the helper is torn down. No more zombie timers.
    private func observeFullscreenEntry(completion: @escaping () -> Void) {
        // Clean up any previous observer + cancel any pending timeout —
        // both belong to the previous observation cycle and must not fire
        // against the new one.
        if let obs = fullscreenObserver {
            NotificationCenter.default.removeObserver(obs)
            fullscreenObserver = nil
        }
        fullscreenEntryTimeout?.cancel()
        fullscreenEntryTimeout = nil

        fullscreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: fullscreenHelper,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let obs = self.fullscreenObserver {
                    NotificationCenter.default.removeObserver(obs)
                    self.fullscreenObserver = nil
                }
                self.fullscreenEntryTimeout?.cancel()
                self.fullscreenEntryTimeout = nil
                // Mark the helper as ready on the display it's now on.
                if let id = self.fullscreenHelper?.screen?.displayID {
                    self.helperState = .ready(displayID: id)
                }
                self.checkPendingRebuild()
                completion()
            }
        }

        // Fallback timeout — cancellable. Fires once, only if the entry
        // notification didn't arrive first AND the timeout wasn't cancelled
        // by a new observation cycle starting up.
        let timeout = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Re-check that the observer this timeout was paired with is
            // still active. If a new observation cycle has started, this
            // timeout is stale and must do nothing.
            guard self.fullscreenEntryTimeout != nil else { return }
            if let obs = self.fullscreenObserver {
                NotificationCenter.default.removeObserver(obs)
                self.fullscreenObserver = nil
            }
            self.fullscreenEntryTimeout = nil
            self.logger.warning("Fullscreen entry timed out — showing panel anyway")
            completion()
        }
        fullscreenEntryTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: timeout)
    }

    /// Exit fullscreen and clean up the helper window.
    ///
    /// `toggleFullScreen(nil)` is asynchronous — the fullscreen exit animates
    /// over ~0.5s. If we `orderOut(nil)` immediately, the black helper window
    /// is still visible mid-transition, leaving a black screen on the Edge.
    ///
    /// Fix: make the helper transparent immediately so the exit animation is
    /// invisible, then observe `didExitFullScreen` to clean up properly.
    ///
    /// - Parameter then: invoked after teardown has settled (either on
    ///   `didExitFullScreen` arrival or fallback timeout). Replaces the
    ///   previous `asyncAfter(0.5)` rebuild trick — chains the next
    ///   transition off the actual teardown completion instead of guessing.
    ///   Architect-flagged: the timer-stacking pattern was a key contributor
    ///   to the wake-orphan bug.
    private func tearDownFullscreenHelper(then completion: (() -> Void)? = nil) {
        if let observer = fullscreenObserver {
            NotificationCenter.default.removeObserver(observer)
            fullscreenObserver = nil
        }
        // Cancel any pending entry timeout so it can't fire against the
        // window we're about to tear down.
        fullscreenEntryTimeout?.cancel()
        fullscreenEntryTimeout = nil
        if let observer = helperScreenObserver {
            NotificationCenter.default.removeObserver(observer)
            helperScreenObserver = nil
        }
        guard let helper = fullscreenHelper else {
            // Nothing to tear down — settle state and fire completion synchronously.
            helperState = .none
            completion?()
            return
        }

        // Move to .tearing so any concurrent change requests get queued
        // rather than starting a fresh transition mid-exit.
        let fromID: CGDirectDisplayID? = {
            if case let .ready(id) = helperState { return id }
            if case let .building(id) = helperState { return id }
            return helper.screen?.displayID
        }()
        if let fromID = fromID {
            helperState = .tearing(fromDisplayID: fromID)
        }

        // Make the helper invisible immediately so the user doesn't see
        // a black screen during the async fullscreen exit animation.
        helper.alphaValue = 0

        // Single-shot guard so completion fires exactly once even if both
        // the notification AND the fallback timer race in.
        var didFinish = false
        let finish: () -> Void = { [weak self] in
            guard !didFinish else { return }
            didFinish = true
            self?.helperState = .none
            completion?()
        }

        if helper.styleMask.contains(.fullScreen) {
            // Observe the exit completion to clean up
            let exitObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: helper,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                Task { @MainActor [weak self] in
                    window.orderOut(nil)
                    if self?.fullscreenHelper === window {
                        self?.fullscreenHelper = nil
                    }
                    finish()
                }
            }

            helper.toggleFullScreen(nil)

            // Fallback: if the notification never fires, force cleanup after 2s.
            // No cancellation needed — `didFinish` inside `finish()` makes a
            // second invocation a no-op, so the timer firing after a fast
            // notification is harmless. Avoiding mutable cross-actor captures
            // (DispatchWorkItem isn't Sendable in strict-concurrency mode).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                NotificationCenter.default.removeObserver(exitObserver)
                helper.orderOut(nil)
                if self?.fullscreenHelper === helper {
                    self?.fullscreenHelper = nil
                }
                finish()
            }
        } else {
            helper.orderOut(nil)
            fullscreenHelper = nil
            finish()
        }

        logger.info("Fullscreen helper tear-down initiated")
    }

    // MARK: - Display Security (Sleep / Lock / Screensaver)
    //
    // The Xeneon Edge must not leak widget content when the system is locked,
    // sleeping, or showing the screensaver. We observe all relevant system
    // notifications and blank the panel until the user unlocks/wakes.

    /// Register for all system events that should cause the panel to blank.
    private func registerForSecurityEvents() {
        let ws = NSWorkspace.shared.notificationCenter
        let dc = DistributedNotificationCenter.default()

        // Display sleep/wake
        securityObservers.append(
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.securityEventCounts.screensDidSleep += 1
                    self.logSnapshot("screensDidSleep-entry")
                    self.blankDisplay(reason: "displays slept")
                    self.logSnapshot("screensDidSleep-exit")
                }
            }
        )
        securityObservers.append(
            ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.securityEventCounts.screensDidWake += 1
                    self.logSnapshot("screensDidWake-entry")
                    self.unblankDisplay(reason: "displays woke")
                    // Edge often re-enumerates across a screen-sleep — refresh
                    // the touch device IDs so post-wake events match the filter.
                    self.refreshTouchDeviceIDs(reason: "displays woke")
                    self.logSnapshot("screensDidWake-exit")
                    self.scheduleWakeDiagnosticSnapshots(source: "screensDidWake")
                }
            }
        )

        // System sleep/wake (covers lid close, sleep menu, idle sleep)
        securityObservers.append(
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.securityEventCounts.willSleep += 1
                    self.logSnapshot("willSleep-entry")
                    self.blankDisplay(reason: "system sleeping")
                    self.logSnapshot("willSleep-exit")
                }
            }
        )
        securityObservers.append(
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                // Unblank unconditionally on wake. Lock-screen info-leak protection is
                // re-asserted by the separate `screenIsLocked` observer if the user
                // configured a password lock — so removing the "wait for unlock" gate
                // here does not weaken security but does prevent the stuck-blank
                // state when `screensDidWake` / `screenIsUnlocked` miss.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.securityEventCounts.didWake += 1
                    self.logSnapshot("didWake-entry")
                    self.unblankDisplay(reason: "system woke")
                    // System sleep also re-enumerates the Edge — refresh now,
                    // not 60s later, so touch is restored before the user
                    // notices it dropped.
                    self.refreshTouchDeviceIDs(reason: "system woke")
                    self.logSnapshot("didWake-exit")
                    self.scheduleWakeDiagnosticSnapshots(source: "didWake")
                }
            }
        )

        // Screen lock/unlock (requires login to dismiss)
        securityObservers.append(
            dc.addObserver(forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.securityEventCounts.screenLocked += 1
                    self?.blankDisplay(reason: "screen locked")
                }
            }
        )
        securityObservers.append(
            dc.addObserver(forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.securityEventCounts.screenUnlocked += 1
                    self?.unblankDisplay(reason: "screen unlocked")
                }
            }
        )

        // Screensaver start/stop
        securityObservers.append(
            dc.addObserver(forName: NSNotification.Name("com.apple.screensaver.didStart"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.securityEventCounts.screensaverStart += 1
                    self?.blankDisplay(reason: "screensaver started")
                }
            }
        )
        securityObservers.append(
            dc.addObserver(forName: NSNotification.Name("com.apple.screensaver.didStop"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.securityEventCounts.screensaverStop += 1
                    self?.unblankDisplay(reason: "screensaver stopped")
                }
            }
        )

        logger.info("Registered for sleep/lock/screensaver security events")
    }

    /// Hide panel content — shows black to prevent information leakage.
    func blankDisplay(reason: String) {
        lastBlankReason = reason
        lastBlankTimestamp = Date()
        guard !isDisplayBlanked else { return }
        isDisplayBlanked = true
        panel?.contentView?.isHidden = true
        logger.info("Display blanked: \(reason)")
    }

    /// Restore panel content. Safe to call from any recovery path (user toggle,
    /// display-topology change, wake). Always resets `contentView.isHidden` so
    /// a stuck-blank panel recovers even if internal state was already `false`.
    func unblankDisplay(reason: String) {
        lastUnblankReason = reason
        lastUnblankTimestamp = Date()
        let wasBlanked = isDisplayBlanked
        isDisplayBlanked = false
        panel?.contentView?.isHidden = false
        if wasBlanked {
            logger.info("Display unblanked: \(reason)")
        }
    }

    /// Debug / recovery action — clear blanking state AND re-assert panel
    /// position, level, ordering, and fullscreen helper. Exposed via Developer
    /// Settings so a stuck panel can be recovered without restarting Ledge.
    ///
    /// Previously this only toggled `contentView.isHidden`, which was useless
    /// when the panel had drifted to the wrong screen or been destroyed during
    /// a sleep/wake storm. Now it's a proper recovery path: it rebuilds the
    /// panel if missing and re-seats everything on the Edge.
    func forceUnblank() {
        logger.info("Force unblank requested from Settings")
        logSnapshot("forceUnblank-entry")

        unblankDisplay(reason: "force unblank (Settings)")

        guard let screen = xeneonScreen else {
            logger.warning("Force unblank: no Xeneon Edge detected — nothing to recover")
            logSnapshot("forceUnblank-exit-noScreen")
            return
        }

        if panel == nil {
            logger.warning("Force unblank: panel missing — rebuilding via showPanel")
            showPanel()
            logSnapshot("forceUnblank-exit-rebuilt")
            return
        }

        // Panel exists: re-assert frame, level, and ordering so a drifted
        // panel snaps back to the Edge. Then re-assert the fullscreen helper
        // in case its Space was torn down.
        panel?.setFrame(screen.frame, display: true, animate: false)
        panel?.level = .screenSaver
        panel?.orderFrontRegardless()
        reassertFullscreen(on: screen)

        logSnapshot("forceUnblank-exit-reasserted")
    }

    // MARK: - Detection Helpers

    private func isXenonEdgeByResolution(_ screen: NSScreen) -> Bool {
        let size = screen.frame.size
        // Check for the Xeneon Edge's distinctive 2560×720 resolution
        return size.width == XenonEdgeInfo.width && size.height == XenonEdgeInfo.height
    }

    private func isXenonEdgeByName(_ screen: NSScreen) -> Bool {
        let name = screen.localizedName
        return name.localizedCaseInsensitiveContains(XenonEdgeInfo.displayName)
    }

    private func foundXenonEdge(_ screen: NSScreen, method: String) {
        // SAFETY GUARD — refuse to claim a screen that is the macOS main display.
        //
        // The Edge is meant to be a *secondary* display alongside the user's
        // primary workspace screen. If detection lands on the main display we
        // would either:
        //   (a) cover the user's only screen with widgets (Edge-only / lid-
        //       closed setups where Edge is the sole display), or
        //   (b) silently render on the wrong screen because detection was
        //       confused mid-topology-flux (the bug seen on wake when the
        //       Edge briefly sits at (0,0) before LG re-joins and shifts it
        //       to its real position).
        //
        // Both axes are checked: AppKit's `NSScreen.main` and CoreGraphics'
        // `CGMainDisplayID()`. They agree, but CG works even before AppKit
        // finishes updating its screen list, which matters during topology
        // transitions.
        let isMainAppKit = (screen == NSScreen.main)
        let isMainCG = (screen.displayID == CGMainDisplayID())
        if isMainAppKit || isMainCG {
            xeneonScreen = nil
            isActive = false
            statusMessage = "Detection rejected: candidate Edge is the main display. Ledge will not render on the user's primary workspace."
            logger.warning("Xeneon Edge detection via \(method, privacy: .public) REJECTED — candidate screen is the main display (NSScreen.main=\(isMainAppKit, privacy: .public), CGMainDisplayID=\(isMainCG, privacy: .public)). Frame=\(NSStringFromRect(screen.frame), privacy: .public). Refusing to render.")
            return
        }

        xeneonScreen = screen
        let frame = screen.frame
        statusMessage = "Found: \(screen.localizedName) (\(Int(frame.width))×\(Int(frame.height)))"
        logger.info("Xeneon Edge detected via \(method, privacy: .public): \(screen.localizedName, privacy: .public) at \(Int(frame.origin.x), privacy: .public),\(Int(frame.origin.y), privacy: .public) size=\(Int(frame.width), privacy: .public)×\(Int(frame.height), privacy: .public)")
    }

    // MARK: - Diagnostics

    /// Schedule snapshots after a wake to catch state drift that occurs
    /// without a corresponding `didChangeScreenParameters` notification.
    /// If the panel ends up `isActive=false` at +2s with no `rawScreenChange`
    /// log between wake and that point, the wake produced no display-change
    /// notification at all — which means the existing auto-restore branch
    /// in `handleDisplayChange` never gets a chance to run.
    private func scheduleWakeDiagnosticSnapshots(source: String) {
        for delay in [2.0, 5.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.logSnapshot("postWake+\(Int(delay))s(\(source))")
            }
        }
    }

    /// Log a single-line snapshot of the panel / helper / screen state.
    ///
    /// Call at every major transition so the log tells you which of the four
    /// overlapping state sources (panel visibility, contentView.isHidden,
    /// fullscreenHelper, isActive) disagree after a race.
    private func logSnapshot(_ tag: String) {
        let panelDesc: String
        if let panel {
            panelDesc = "visible=\(panel.isVisible) key=\(panel.isKeyWindow) frame=\(NSStringFromRect(panel.frame)) screen=\(panel.screen?.localizedName ?? "nil") hidden=\(panel.contentView?.isHidden ?? false)"
        } else {
            panelDesc = "nil"
        }
        let helperDesc: String
        if let helper = fullscreenHelper {
            helperDesc = "fs=\(helper.styleMask.contains(.fullScreen)) frame=\(NSStringFromRect(helper.frame))"
        } else {
            helperDesc = "nil"
        }
        let screenDesc = xeneonScreen.map { "\($0.localizedName) frame=\(NSStringFromRect($0.frame))" } ?? "nil"

        // .notice level — macOS purges .info under memory pressure, which
        // silently destroys the diagnostic trail we need. Snapshot is the
        // primary audit artefact, so it must persist.
        logger.notice("SNAPSHOT[\(tag, privacy: .public)] isActive=\(self.isActive, privacy: .public) wasActive=\(self.wasActive, privacy: .public) blanked=\(self.isDisplayBlanked, privacy: .public) panel=[\(panelDesc, privacy: .public)] helper=[\(helperDesc, privacy: .public)] edge=[\(screenDesc, privacy: .public)]")
    }

    // MARK: - Self-Check
    //
    // Structured evaluation of the core display invariants. The Developer
    // Settings view renders these as a pass/fail list so the user can see
    // at a glance which of the overlapping state sources have drifted,
    // without reading logs or attaching a debugger.

    enum SelfCheckStatus: Equatable {
        case pass
        case fail
        case skipped  // precondition not met (e.g. panel nil); not a failure
    }

    struct SelfCheckResult: Identifiable, Equatable {
        let id: UUID
        let name: String
        let status: SelfCheckStatus
        /// Optional human-readable explanation shown alongside the dot.
        /// Populated for failures and skips; nil for passes.
        let detail: String?

        init(name: String, status: SelfCheckStatus, detail: String? = nil) {
            self.id = UUID()
            self.name = name
            self.status = status
            self.detail = detail
        }
    }

    /// Evaluate the core display invariants and return a structured result
    /// list. Also writes a snapshot to `os.log` so the outcome is preserved.
    ///
    /// Invariants checked:
    /// - (a) `xeneonScreen` matches a currently connected Edge.
    /// - (b) `panel != nil` iff `isActive`.
    /// - (c) `panel.screen === xeneonScreen` (identity check).
    /// - (d) `panel.frame == xeneonScreen.frame`.
    /// - (e) `fullscreenHelper == nil` OR `helper.screen === xeneonScreen`.
    /// - (f) `panel` is above `fullscreenHelper` in window order.
    ///
    /// When the Edge is not connected, a single "skipped" row is returned
    /// rather than failing every check — per the spec in #181, that state
    /// is reported explicitly.
    func runSelfCheck() -> [SelfCheckResult] {
        var results: [SelfCheckResult] = []

        let connectedEdge = NSScreen.screens.first { isXenonEdgeByResolution($0) || isXenonEdgeByName($0) }

        // (a) xeneonScreen matches a currently connected Edge
        let aPassed = xeneonScreen != nil && connectedEdge != nil
            && (isXenonEdgeByResolution(xeneonScreen!) || isXenonEdgeByName(xeneonScreen!))
        var aDetail: String? = nil
        if xeneonScreen == nil && connectedEdge == nil {
            aDetail = "Edge not connected"
        } else if xeneonScreen == nil {
            aDetail = "xeneonScreen is nil but an Edge is connected (\(connectedEdge!.localizedName))"
        } else if !aPassed {
            aDetail = "xeneonScreen=\(xeneonScreen!.localizedName) does not match Edge criteria"
        }
        results.append(SelfCheckResult(
            name: "xeneonScreen matches connected Edge",
            status: aPassed ? .pass : .fail,
            detail: aDetail
        ))

        // If no Edge is connected, skip the panel-level checks rather than
        // failing each row. The user will fix the missing Edge first.
        guard connectedEdge != nil else {
            results.append(SelfCheckResult(
                name: "Panel & helper checks",
                status: .skipped,
                detail: "Connect the Xeneon Edge to run the full self-check."
            ))
            logger.notice("Self-check: Edge not connected — skipped detailed checks")
            logSnapshot("self-check-no-edge")
            return results
        }

        // (b) panel != nil iff isActive
        let bAligned = (panel != nil) == isActive
        results.append(SelfCheckResult(
            name: "panel != nil iff isActive",
            status: bAligned ? .pass : .fail,
            detail: bAligned ? nil : "panel=\(panel == nil ? "nil" : "non-nil"), isActive=\(isActive)"
        ))

        // (c) panel.screen === xeneonScreen
        if let panel {
            let cMatches = panel.screen === xeneonScreen
            results.append(SelfCheckResult(
                name: "panel.screen === xeneonScreen",
                status: cMatches ? .pass : .fail,
                detail: cMatches ? nil : "panel.screen=\(panel.screen?.localizedName ?? "nil"), xeneonScreen=\(xeneonScreen?.localizedName ?? "nil")"
            ))
        } else {
            results.append(SelfCheckResult(
                name: "panel.screen === xeneonScreen",
                status: .skipped,
                detail: "panel is nil"
            ))
        }

        // (d) panel.frame == xeneonScreen.frame
        if let panel, let edge = xeneonScreen {
            let dMatches = panel.frame == edge.frame
            results.append(SelfCheckResult(
                name: "panel.frame == xeneonScreen.frame",
                status: dMatches ? .pass : .fail,
                detail: dMatches ? nil : "panel=\(NSStringFromRect(panel.frame)), edge=\(NSStringFromRect(edge.frame))"
            ))
        } else {
            results.append(SelfCheckResult(
                name: "panel.frame == xeneonScreen.frame",
                status: .skipped,
                detail: "panel or xeneonScreen missing"
            ))
        }

        // (e) fullscreenHelper.screen === xeneonScreen (or helper is nil)
        if let helper = fullscreenHelper {
            let eMatches = helper.screen === xeneonScreen
            results.append(SelfCheckResult(
                name: "fullscreenHelper on Edge (or absent)",
                status: eMatches ? .pass : .fail,
                detail: eMatches ? nil : "helper.screen=\(helper.screen?.localizedName ?? "nil"), xeneonScreen=\(xeneonScreen?.localizedName ?? "nil")"
            ))
        } else {
            results.append(SelfCheckResult(
                name: "fullscreenHelper on Edge (or absent)",
                status: .pass,
                detail: nil
            ))
        }

        // (f) panel is above fullscreenHelper in window order
        if let panel, let helper = fullscreenHelper {
            // `NSApp.orderedWindows` returns windows front-to-back.
            // A lower index means closer to the front.
            let ordered = NSApp.orderedWindows
            let panelIdx = ordered.firstIndex(of: panel)
            let helperIdx = ordered.firstIndex(of: helper)
            let fPassed: Bool
            let fDetail: String?
            if let pi = panelIdx, let hi = helperIdx {
                fPassed = pi < hi
                fDetail = fPassed ? nil : "panel at z-index \(pi), helper at z-index \(hi) (lower = frontmost)"
            } else {
                fPassed = false
                fDetail = "one or both windows not in NSApp.orderedWindows (panel=\(panelIdx.map(String.init) ?? "—"), helper=\(helperIdx.map(String.init) ?? "—"))"
            }
            results.append(SelfCheckResult(
                name: "panel above fullscreenHelper in z-order",
                status: fPassed ? .pass : .fail,
                detail: fDetail
            ))
        } else {
            results.append(SelfCheckResult(
                name: "panel above fullscreenHelper in z-order",
                status: .skipped,
                detail: "panel or helper missing"
            ))
        }

        // Log the aggregate outcome so the result is persisted and visible
        // alongside the state snapshot that generated it.
        let passCount = results.filter { $0.status == .pass }.count
        let failCount = results.filter { $0.status == .fail }.count
        let skipCount = results.filter { $0.status == .skipped }.count
        logger.notice("Self-check: \(passCount, privacy: .public) pass, \(failCount, privacy: .public) fail, \(skipCount, privacy: .public) skipped")
        logSnapshot("self-check")

        return results
    }

    // MARK: - Debug Info

    /// Returns info about all connected screens (for the settings UI).
    var allScreensInfo: [(name: String, resolution: String, isXenonEdge: Bool)] {
        NSScreen.screens.map { screen in
            let frame = screen.frame
            let resolution = "\(Int(frame.width))×\(Int(frame.height))"
            let isXeneon = isXenonEdgeByResolution(screen) || isXenonEdgeByName(screen)
            return (name: screen.localizedName, resolution: resolution, isXenonEdge: isXeneon)
        }
    }
}

// MARK: - NSScreen helpers

extension NSScreen {
    /// The CoreGraphics `CGDirectDisplayID` for this screen, if available.
    /// Stable across NSScreen instance churn — same physical display gets
    /// the same `displayID` even when AppKit hands out a fresh NSScreen
    /// pointer. Used for diagnostic comparison alongside frame and identity.
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
