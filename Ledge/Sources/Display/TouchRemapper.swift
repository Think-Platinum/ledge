@preconcurrency import AppKit
import CoreGraphics
import os.log

/// Remaps touch input from the Xeneon Edge touchscreen to the correct display coordinates.
///
/// macOS maps external USB touchscreen input to the primary display — there's no built-in
/// way to associate a USB touch digitiser with a specific secondary display.
///
/// ## Direct Delivery Approach
///
/// This class intercepts ALL mouse events from the touchscreen via a CGEventTap and
/// returns `nil` to completely suppress them from the system. It then constructs NSEvents
/// with the correct Xeneon Edge coordinates and delivers them directly to the LedgePanel
/// via `sendEvent()`.
///
/// Because the original events are fully suppressed and the synthetic NSEvents never
/// enter the window server, this approach:
/// - Does NOT move the cursor (see note: HID may reposition cursor before tap fires)
/// - Does NOT change window ordering or focus
/// - Does NOT activate the Ledge application
///
/// The events exist only within the application — the OS never sees them.
///
/// Requires Accessibility permissions (System Settings > Privacy & Security > Accessibility).
///
/// This class is explicitly nonisolated because the CGEventTap callback runs on
/// the system's event tap thread and cannot be confined to MainActor.
nonisolated class TouchRemapper {

    let logger = Logger(subsystem: "com.ledge.app", category: "TouchRemapper")

    /// The panel to deliver touch events to. Set by DisplayManager.
    /// Weak to avoid retain cycles.
    weak var panel: LedgePanel?

    /// The screen that the touchscreen should map to (the Xeneon Edge).
    private var targetScreen: NSScreen?

    /// The primary screen — macOS maps USB touchscreen absolute coordinates here.
    private var primaryScreen: NSScreen? {
        NSScreen.screens.first
    }

    /// Convert an NSScreen frame from Cocoa coordinates to CG/Quartz coordinates.
    /// Delegates to `TouchCoordinateMath.cocoaToCGRect`.
    private func cgRect(for screen: NSScreen) -> CGRect {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else {
            return screen.frame
        }
        return TouchCoordinateMath.cocoaToCGRect(screen.frame, primaryHeight: primaryHeight)
    }

    /// The CGEventTap Mach port.
    /// `private(set)` because the callback function needs read access to re-enable the tap.
    private(set) var eventTap: CFMachPort?

    /// The run loop source for the event tap.
    private var runLoopSource: CFRunLoopSource?

    /// Whether the remapper is currently active.
    private(set) var isActive: Bool = false

    /// Known device IDs for the touchscreen. CGEvent field 87 may report any of these
    /// depending on which IOService node in the IOKit tree generates the event.
    private(set) var touchDeviceIDs: Set<Int64> = []

    /// Convenience accessor — returns a representative device ID (for display in UI).
    var touchDeviceID: Int64? {
        touchDeviceIDs.first
    }

    /// Whether we're in "learning mode" — waiting to identify the touchscreen device.
    private(set) var isLearning: Bool = false

    /// Callback invoked when learning completes.
    var onLearningComplete: (() -> Void)?

    /// Callback invoked when a touchscreen event is processed (for diagnostics).
    /// Parameters: device ID, original coordinates, remapped coordinates (nil if failed),
    /// event type raw value, delivery status, sequence ID, timestamp of CGEvent arrival.
    var onEventProcessed: ((_ deviceID: Int64,
                            _ original: CGPoint,
                            _ remapped: CGPoint?,
                            _ eventTypeRaw: UInt32,
                            _ delivered: Bool,
                            _ sequenceID: UInt64,
                            _ arrivalTime: Date) -> Void)?

    // MARK: - Touch Sequence State

    /// Whether we're currently tracking a touch sequence (finger is down).
    private var isTrackingTouch: Bool = false

    /// Counter for throttling mouseDragged/mouseMoved logs.
    private var moveLogCounter: Int = 0

    /// Sequence counter — increments on each mouseDown for correlating log entries.
    private var touchSequenceID: UInt64 = 0

    // MARK: - Setup

    /// Start the touch remapper targeting the given screen.
    ///
    /// - Parameter screen: The NSScreen representing the Xeneon Edge.
    func start(targetScreen: NSScreen) {
        self.targetScreen = targetScreen

        guard checkAccessibilityPermissions() else {
            logger.error("Accessibility permissions not granted — cannot remap touch")
            return
        }

        // Create an event tap that intercepts mouse events.
        // Using .defaultTap (active filter) so we can suppress events by returning nil.
        let eventMask: CGEventMask = (
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue)
        )

        // Store self in a pointer so the C callback can access it
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: touchRemapperCallback,
            userInfo: userInfo
        ) else {
            logger.error("Failed to create CGEventTap — check Accessibility permissions")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true

        // Log display geometry in CG coordinates (matching CGEvent.location)
        let sourceCG = cgRect(for: NSScreen.screens.first ?? targetScreen)
        let targetCG = cgRect(for: targetScreen)
        logger.notice("Touch remapper started — targeting \(targetScreen.localizedName)")
        logger.notice("  Source (primary CG): origin=(\(Int(sourceCG.origin.x)),\(Int(sourceCG.origin.y))) size=\(Int(sourceCG.width))×\(Int(sourceCG.height))")
        logger.notice("  Target (edge CG):    origin=(\(Int(targetCG.origin.x)),\(Int(targetCG.origin.y))) size=\(Int(targetCG.width))×\(Int(targetCG.height))")
        for (i, screen) in NSScreen.screens.enumerated() {
            let cg = cgRect(for: screen)
            logger.notice("  Screen \(i) CG: \(screen.localizedName) origin=(\(Int(cg.origin.x)),\(Int(cg.origin.y))) size=\(Int(cg.width))×\(Int(cg.height))")
        }
        logger.notice("  Touch device IDs: \(self.touchDeviceIDs.sorted())")
        logger.notice("  Panel: \(self.panel != nil ? "connected" : "NOT connected")")
        logger.notice("  Thread: \(Thread.isMainThread ? "main" : "background")")
    }

    /// Stop the touch remapper.
    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isActive = false
        isTrackingTouch = false
        moveLogCounter = 0
        logger.notice("Touch remapper stopped")
    }

    /// Enter "learning mode" — the next touch event on the primary display will be
    /// identified as the touchscreen device, and its device ID will be remembered.
    /// This lets us distinguish touchscreen events from trackpad/mouse events.
    func startLearning() {
        isLearning = true
        touchDeviceIDs = []
        logger.notice("Touch remapper learning mode — touch the Xeneon Edge screen")
    }

    /// Set a single touchscreen device ID (manual calibration / learning mode).
    func setTouchDeviceID(_ id: Int64) {
        touchDeviceIDs = [id]
        isLearning = false
        logger.notice("Touch device ID set to \(id)")
    }

    /// Set multiple possible touchscreen device IDs (auto-detection via IOKit).
    /// CGEvent field 87 may report any of these depending on which IOService
    /// node in the IOKit tree generates the event.
    func setTouchDeviceIDs(_ ids: Set<Int64>) {
        touchDeviceIDs = ids
        isLearning = false
        logger.notice("Touch device IDs set: \(ids.sorted())")
    }

    /// Update the target screen reference when the display configuration changes.
    ///
    /// Must be called from `DisplayManager.handleDisplayChange()` after repositioning
    /// the panel. Without this, touch coordinates remap to stale screen geometry.
    func updateTargetScreen(_ screen: NSScreen) {
        let oldTarget = targetScreen.map { cgRect(for: $0) }
        targetScreen = screen
        let newTarget = cgRect(for: screen)
        logger.notice("Target screen updated: \(screen.localizedName) CG origin=(\(Int(newTarget.origin.x)),\(Int(newTarget.origin.y))) size=\(Int(newTarget.width))×\(Int(newTarget.height)) (was \(oldTarget.map { "(\(Int($0.origin.x)),\(Int($0.origin.y)))" } ?? "nil"))")
    }

    // MARK: - Coordinate Remapping

    /// Remap a point from primary display CG coordinates to the target display CG coordinates.
    ///
    /// macOS maps the USB touchscreen digitiser to the primary display's coordinate space.
    /// CGEvent.location uses CG/Quartz coordinates (origin top-left, Y down), but
    /// NSScreen.frame uses Cocoa coordinates (origin bottom-left, Y up). We convert
    /// all frames to CG space before normalising and remapping.
    func remapPoint(_ point: CGPoint) -> CGPoint? {
        guard let primary = primaryScreen,
              let target = targetScreen else {
            return nil
        }

        // Both source and target in CG coordinates (matching CGEvent.location)
        let sourceRect = cgRect(for: primary)
        let targetRect = cgRect(for: target)

        return TouchCoordinateMath.remapPoint(from: sourceRect, to: targetRect, point: point)
    }

    // MARK: - Event Processing

    /// Process a CGEvent from the touchscreen.
    ///
    /// **Direct delivery approach:** For touchscreen events, we SUPPRESS the original
    /// event (return nil) and deliver an NSEvent directly to the LedgePanel via
    /// `sendEvent()`. The event never re-enters the window server, so there is no
    /// cursor movement, focus change, or app activation.
    ///
    /// For non-touchscreen events (trackpad, mouse), we pass through unmodified.
    func processEvent(_ event: CGEvent) -> CGEvent? {
        // mouseEventDeviceID (raw value 87) is not bridged to Swift's CGEventField enum
        let deviceID = event.getIntegerValueField(CGEventField(rawValue: 87)!)
        let eventType = event.type
        let location = event.location
        let typeName = Self.eventTypeName(eventType)

        // Determine if this is a "key" event worth full logging (not move/drag)
        let isKeyEvent = (eventType == .leftMouseDown || eventType == .leftMouseUp)

        // ── Learning mode ──
        // Only capture device ID from mouseDown events to prevent trackpad
        // movement being misidentified as the touchscreen.
        if isLearning {
            if eventType == .leftMouseDown {
                touchDeviceIDs = [deviceID]
                isLearning = false
                logger.notice("⚡ LEARN: captured device=\(deviceID) from \(typeName) at (\(Int(location.x)),\(Int(location.y)))")
                onLearningComplete?()
            } else if isKeyEvent {
                logger.notice("⏳ LEARN: ignoring \(typeName) from device=\(deviceID) at (\(Int(location.x)),\(Int(location.y))) — waiting for mouseDown")
            }
            return event
        }

        // ── Device filtering ──
        guard !touchDeviceIDs.isEmpty else {
            return event  // No device IDs known yet
        }

        guard touchDeviceIDs.contains(deviceID) else {
            return event  // Not from the touchscreen
        }

        // ══════════════════════════════════════════════════════════════════
        // This IS from the touchscreen device — suppress and deliver to panel.
        // ══════════════════════════════════════════════════════════════════

        // Capture arrival time for latency measurement
        let arrivalTime = Date()

        // mouseMoved from the touchscreen is hover noise — touchscreens don't
        // have meaningful hover state. Suppress without delivering.
        // (mouseDragged is different — that's finger-on-screen movement.)
        if eventType == .mouseMoved && !isTrackingTouch {
            onEventProcessed?(deviceID, location, nil, eventType.rawValue, false, touchSequenceID, arrivalTime)
            return nil
        }

        // ── Determine the target position ──
        let targetRect = targetScreen.map { cgRect(for: $0) }
        let isAlreadyOnTarget = targetRect.map { $0.contains(location) } ?? false

        let edgePoint: CGPoint
        if isAlreadyOnTarget {
            edgePoint = location
        } else {
            guard let remapped = remapPoint(location) else {
                if isKeyEvent {
                    logger.warning("⚠ [seq \(self.touchSequenceID)] DROP \(typeName) device=\(deviceID) at (\(Int(location.x)),\(Int(location.y))) — cannot remap")
                }
                onEventProcessed?(deviceID, location, nil, eventType.rawValue, false, touchSequenceID, arrivalTime)
                return nil
            }
            edgePoint = remapped
        }

        // ── Touch sequence lifecycle + logging ──

        switch eventType {
        case .leftMouseDown:
            touchSequenceID += 1
            moveLogCounter = 0
            isTrackingTouch = true
            logger.notice("🔽 [seq \(self.touchSequenceID)] TOUCH DOWN device=\(deviceID) (\(Int(location.x)),\(Int(location.y))) → (\(Int(edgePoint.x)),\(Int(edgePoint.y)))")

        case .leftMouseDragged, .mouseMoved:
            moveLogCounter += 1
            if moveLogCounter % 30 == 1 {
                logger.notice("↔ [seq \(self.touchSequenceID)] DRAG #\(self.moveLogCounter) device=\(deviceID) (\(Int(location.x)),\(Int(location.y))) → (\(Int(edgePoint.x)),\(Int(edgePoint.y)))")
            }

        case .leftMouseUp:
            logger.notice("🔼 [seq \(self.touchSequenceID)] TOUCH UP device=\(deviceID) (\(Int(location.x)),\(Int(location.y))) → (\(Int(edgePoint.x)),\(Int(edgePoint.y)))  dragEvents=\(self.moveLogCounter)")

        default:
            break
        }

        // ── Deliver to panel ──
        deliverEventToPanel(type: eventType, at: edgePoint, originalEvent: event)

        // ── End touch sequence on mouseUp ──
        if eventType == .leftMouseUp {
            isTrackingTouch = false
            moveLogCounter = 0
        }

        onEventProcessed?(deviceID, location, edgePoint, eventType.rawValue, true, touchSequenceID, arrivalTime)

        // Suppress the original event — the OS never sees it
        return nil
    }

    // MARK: - Direct NSEvent Delivery

    /// Convert a CG point to window-local Cocoa coordinates.
    /// Delegates to `TouchCoordinateMath.cgPointToWindowLocal`.
    ///
    /// Uses `MainActor.assumeIsolated` because this is called from the CGEventTap
    /// callback which runs on the main thread's run loop — accessing `window.frame`
    /// is safe, but the compiler can't verify this statically.
    private func cgPointToWindowLocal(_ cgPoint: CGPoint, in window: NSWindow) -> NSPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let windowFrame = MainActor.assumeIsolated { window.frame }
        return TouchCoordinateMath.cgPointToWindowLocal(
            cgPoint,
            windowFrame: windowFrame,
            primaryHeight: primaryHeight
        )
    }

    /// Deliver a touch event directly to the LedgePanel as an NSEvent.
    ///
    /// This bypasses the window server entirely — the event only exists within
    /// the application. No cursor movement, no focus change, no app activation.
    ///
    /// IMPORTANT: We build the NSEvent eagerly (capturing all values from the
    /// CGEvent while it's still valid) but deliver it asynchronously via
    /// `DispatchQueue.main.async`. The CGEventTap callback runs on the main
    /// run loop, and calling `panel.sendEvent()` synchronously inside it would
    /// deadlock if SwiftUI's event handling re-enters the run loop (which it
    /// does for layout, animation, and state updates).
    private func deliverEventToPanel(type: CGEventType, at cgPoint: CGPoint, originalEvent: CGEvent) {
        guard let panel = self.panel else {
            logger.warning("⚠ [seq \(self.touchSequenceID)] No panel — cannot deliver \(Self.eventTypeName(type))")
            return
        }

        // Convert CG coordinates to window-local Cocoa coordinates
        let windowPoint = cgPointToWindowLocal(cgPoint, in: panel)

        // Map CGEventType to NSEvent.EventType
        let nsType: NSEvent.EventType
        switch type {
        case .leftMouseDown:    nsType = .leftMouseDown
        case .leftMouseUp:      nsType = .leftMouseUp
        case .leftMouseDragged: nsType = .leftMouseDragged
        case .mouseMoved:       nsType = .mouseMoved
        default:                return
        }

        // Click count from the original event (for double-tap detection)
        let clickCount: Int
        if type == .leftMouseDown || type == .leftMouseUp {
            clickCount = max(1, Int(originalEvent.getIntegerValueField(.mouseEventClickState)))
        } else {
            clickCount = 0
        }

        // Pressure: 1.0 while touching, 0.0 on release
        let pressure: Float = (type == .leftMouseUp) ? 0.0 : 1.0

        // Convert CGEventFlags to NSEvent.ModifierFlags
        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(originalEvent.flags.rawValue))

        // Build the NSEvent NOW while the CGEvent is still valid.
        // The windowNumber and coordinates are captured eagerly.
        // Uses assumeIsolated because CGEventTap runs on the main thread.
        let windowNumber = MainActor.assumeIsolated { panel.windowNumber }

        guard let nsEvent = NSEvent.mouseEvent(
            with: nsType,
            location: windowPoint,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: pressure
        ) else {
            logger.error("⚠ [seq \(self.touchSequenceID)] Failed to create NSEvent at windowLocal=(\(Int(windowPoint.x)),\(Int(windowPoint.y)))")
            return
        }

        // Deliver asynchronously to avoid deadlocking the run loop.
        // The CGEventTap callback runs inside a run loop source; calling
        // panel.sendEvent() synchronously can block if SwiftUI re-enters
        // the run loop for layout/animation. Async dispatch breaks the cycle.
        //
        // nonisolated(unsafe): NSEvent is non-Sendable but this is safe —
        // we're already on the main thread and dispatching to main.
        let capturedPanel = panel
        nonisolated(unsafe) let capturedEvent = nsEvent
        DispatchQueue.main.async {
            // Prevent any window ordering changes from this event
            NSApp.preventWindowOrdering()

            // Ensure the panel is key so SwiftUI gesture recognizers are active.
            // On a .nonactivatingPanel this does NOT activate the app.
            if !capturedPanel.isKeyWindow {
                capturedPanel.makeKey()
            }

            // Deliver directly to the panel — this goes through NSWindow.sendEvent
            // which does hit testing and routes to the NSHostingView (SwiftUI).
            // The event never enters the window server.
            capturedPanel.sendEvent(capturedEvent)
        }
    }

    /// Human-readable name for a CGEventType.
    private static func eventTypeName(_ type: CGEventType) -> String {
        switch type {
        case .leftMouseDown:    return "mouseDown"
        case .leftMouseUp:      return "mouseUp"
        case .leftMouseDragged: return "mouseDrag"
        case .mouseMoved:       return "mouseMove"
        default:                return "event(\(type.rawValue))"
        }
    }

    // MARK: - Permissions

    /// Check if Accessibility permissions are granted.
    func checkAccessibilityPermissions() -> Bool {
        let trusted = AXIsProcessTrusted()
        if !trusted {
            logger.warning("Accessibility permissions not granted")
        }
        return trusted
    }

    /// Prompt the user to grant Accessibility permissions.
    func requestAccessibilityPermissions() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - C Callback

/// The CGEventTap callback. Must be a plain C function (no captures).
/// Uses the userInfo pointer to access the TouchRemapper instance.
nonisolated private func touchRemapperCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // Handle tap disabled events (system can temporarily disable taps under load)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        // Re-enable the tap
        if let userInfo {
            let remapper = Unmanaged<TouchRemapper>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = remapper.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            remapper.logger.warning("⚠ Event tap was disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input") — re-enabled")
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let remapper = Unmanaged<TouchRemapper>.fromOpaque(userInfo).takeUnretainedValue()

    if let processed = remapper.processEvent(event) {
        return Unmanaged.passUnretained(processed)
    }

    // processEvent returned nil → suppress the event
    return nil
}
