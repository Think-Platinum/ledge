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
            logger.info("  Screen \(index): \(name) — \(Int(frame.width))×\(Int(frame.height))")
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

            logger.info("Created LedgePanel on Xeneon Edge")
        }

        // Enter fullscreen on the Edge to auto-hide the menu bar via the
        // fullscreen helper. The LedgePanel's .fullScreenAuxiliary collection
        // behavior makes it render on top of the fullscreen Space.
        ensureFullscreenHelper(on: screen) { [weak self] in
            guard let self else { return }
            self.revealPanel(on: screen)
        }
    }

    /// Actually make the panel visible. Called directly (no fullscreen helper needed)
    /// or after the fullscreen helper finishes its transition.
    private func revealPanel(on screen: NSScreen) {
        // The panel is about to be made visible — ensure its contentView isn't
        // still hidden from an earlier blank that never unblanked cleanly.
        unblankDisplay(reason: "panel revealed")

        // Ensure panel is positioned correctly on the target screen
        panel?.setFrame(screen.frame, display: true, animate: false)

        // Use orderFrontRegardless + makeKey separately instead of makeKeyAndOrderFront.
        // makeKeyAndOrderFront can trigger app activation even on .nonactivatingPanel.
        // orderFrontRegardless brings the panel forward without activating the app.
        NSApp.preventWindowOrdering()
        panel?.orderFrontRegardless()
        panel?.makeKey()
        isActive = true
        statusMessage = "Active on \(screen.localizedName)"
        logger.info("Panel is now visible on Xeneon Edge")

        // If the fullscreen helper briefly activated the app, yield focus back.
        // NSApp.deactivate() lets the previously active app regain focus.
        if fullscreenHelper != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.deactivate()
            }
        }
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
        panel?.orderOut(nil)
        isActive = false
        tearDownFullscreenHelper()
        statusMessage = "Panel hidden (Xeneon Edge still connected)"
        logger.info("Panel hidden")
    }

    /// Completely tear down the panel.
    func destroyPanel() {
        panel?.orderOut(nil)
        touchRemapper.panel = nil
        panel = nil
        isActive = false
        tearDownFullscreenHelper()
        logger.info("Panel destroyed")
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
        // Watch for screen configuration changes (connect/disconnect/rearrange)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Hop back to MainActor to satisfy Swift 6 concurrency
            Task { @MainActor [weak self] in
                self?.handleDisplayChange()
            }
        }
    }

    private func handleDisplayChange() {
        logger.info("Display configuration changed, re-scanning...")

        let previousScreen = xeneonScreen
        detectXenonEdge()

        if let currentScreen = xeneonScreen {
            if currentScreen != previousScreen {
                // Screen changed (e.g., rearranged) — reposition panel AND update touch remapper
                logger.info("Xeneon Edge repositioned, updating panel frame and touch target")
                // Display topology changed — clear any stuck blanking so the
                // rebuilt panel renders widgets instead of a black rectangle.
                unblankDisplay(reason: "display topology changed")
                panel?.reposition(on: currentScreen)
                touchRemapper.updateTargetScreen(currentScreen)
                hidTouchReader.updatePanelFrame(currentScreen.frame)
                mouseGuard.updateEdgeScreen(currentScreen)

                // The fullscreen helper's Space was created for the old screen frame.
                // Tear it down and recreate for the new screen position so the
                // fullscreen Space and menu bar hiding follow the display move.
                if fullscreenHelper != nil {
                    logger.info("Rebuilding fullscreen helper for new screen frame")
                    tearDownFullscreenHelper()
                    // Brief delay to let the async fullscreen exit animation begin
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, let screen = self.xeneonScreen else { return }
                        self.ensureFullscreenHelper(on: screen) { [weak self] in
                            guard let self, let screen = self.xeneonScreen else { return }
                            self.revealPanel(on: screen)
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
        } else {
            logger.error("Event tap failed to start")
        }
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

    /// Create a helper window that enters native macOS fullscreen on the Edge display.
    ///
    /// When a window goes fullscreen on a secondary display, macOS creates a dedicated
    /// fullscreen Space for that display and auto-hides the menu bar. This is the same
    /// mechanism used by Safari, Chrome, etc. when you click "Full Screen > Entire Screen".
    ///
    /// The LedgePanel (with `.fullScreenAuxiliary` + `.canJoinAllSpaces`) renders on top
    /// of the fullscreen helper, receiving all touch/mouse input as before.
    private func ensureFullscreenHelper(on screen: NSScreen, completion: @escaping () -> Void) {
        // If helper already exists and is in fullscreen, proceed immediately
        if let helper = fullscreenHelper, helper.styleMask.contains(.fullScreen) {
            completion()
            return
        }

        // If helper exists but mid-transition, wait for it
        if fullscreenHelper != nil {
            observeFullscreenEntry(completion: completion)
            return
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
    private func observeFullscreenEntry(completion: @escaping () -> Void) {
        // Clean up any previous observer
        if let obs = fullscreenObserver {
            NotificationCenter.default.removeObserver(obs)
            fullscreenObserver = nil
        }

        fullscreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didEnterFullScreenNotification,
            object: fullscreenHelper,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                if let obs = self?.fullscreenObserver {
                    NotificationCenter.default.removeObserver(obs)
                    self?.fullscreenObserver = nil
                }
                completion()
            }
        }

        // Fallback: if the notification never fires, show after 2 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard self?.fullscreenObserver != nil else { return }
            if let obs = self?.fullscreenObserver {
                NotificationCenter.default.removeObserver(obs)
                self?.fullscreenObserver = nil
            }
            self?.logger.warning("Fullscreen entry timed out — showing panel anyway")
            completion()
        }
    }

    /// Exit fullscreen and clean up the helper window.
    ///
    /// `toggleFullScreen(nil)` is asynchronous — the fullscreen exit animates
    /// over ~0.5s. If we `orderOut(nil)` immediately, the black helper window
    /// is still visible mid-transition, leaving a black screen on the Edge.
    ///
    /// Fix: make the helper transparent immediately so the exit animation is
    /// invisible, then observe `didExitFullScreen` to clean up properly.
    private func tearDownFullscreenHelper() {
        if let observer = fullscreenObserver {
            NotificationCenter.default.removeObserver(observer)
            fullscreenObserver = nil
        }
        guard let helper = fullscreenHelper else { return }

        // Make the helper invisible immediately so the user doesn't see
        // a black screen during the async fullscreen exit animation.
        helper.alphaValue = 0

        if helper.styleMask.contains(.fullScreen) {
            // Observe the exit completion to clean up
            let exitObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didExitFullScreenNotification,
                object: helper,
                queue: .main
            ) { [weak self] notification in
                // Extract the window reference before crossing the Task boundary
                // (Notification is non-Sendable)
                guard let window = notification.object as? NSWindow else { return }
                Task { @MainActor [weak self] in
                    window.orderOut(nil)
                    if self?.fullscreenHelper === window {
                        self?.fullscreenHelper = nil
                    }
                }
            }

            helper.toggleFullScreen(nil)

            // Fallback: if the notification never fires, force cleanup after 2s
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                NotificationCenter.default.removeObserver(exitObserver)
                helper.orderOut(nil)
                if self?.fullscreenHelper === helper {
                    self?.fullscreenHelper = nil
                }
            }
        } else {
            helper.orderOut(nil)
            fullscreenHelper = nil
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
                    self?.securityEventCounts.screensDidSleep += 1
                    self?.blankDisplay(reason: "displays slept")
                }
            }
        )
        securityObservers.append(
            ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.securityEventCounts.screensDidWake += 1
                    self?.unblankDisplay(reason: "displays woke")
                }
            }
        )

        // System sleep/wake (covers lid close, sleep menu, idle sleep)
        securityObservers.append(
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.securityEventCounts.willSleep += 1
                    self?.blankDisplay(reason: "system sleeping")
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
                    self?.securityEventCounts.didWake += 1
                    self?.unblankDisplay(reason: "system woke")
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

    /// Debug / recovery action — force the panel content visible and reset
    /// blanking state. Exposed via Developer Settings so a stuck panel can be
    /// recovered without restarting Ledge.
    func forceUnblank() {
        logger.info("Force unblank requested from Settings")
        unblankDisplay(reason: "force unblank (Settings)")
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
        xeneonScreen = screen
        let frame = screen.frame
        statusMessage = "Found: \(screen.localizedName) (\(Int(frame.width))×\(Int(frame.height)))"
        logger.info("Xeneon Edge detected via \(method): \(screen.localizedName) at \(Int(frame.origin.x)),\(Int(frame.origin.y))")
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
