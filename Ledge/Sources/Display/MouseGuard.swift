import AppKit
import CoreGraphics
import os.log

/// Blocks non-touchscreen mouse events from interacting with the Xeneon Edge display.
///
/// When enabled, this creates a CGEventTap that suppresses mouse events whose
/// device ID does NOT match the known touchscreen device IDs, but whose location
/// falls within the Edge display bounds. This prevents accidental mouse interaction
/// with widgets when the cursor drifts onto the Edge.
///
/// Touch events (matching the learned device IDs) always pass through — they're
/// handled by `TouchRemapper`.
///
/// Like `TouchRemapper`, this class is nonisolated because the CGEventTap callback
/// runs on the system's event tap thread.
nonisolated class MouseGuard {

    private let logger = Logger(subsystem: "com.ledge.app", category: "MouseGuard")

    /// The known touchscreen device IDs — events from these devices are always allowed.
    private var touchDeviceIDs: Set<Int64> = []

    /// The Xeneon Edge screen rect in CG coordinates (origin top-left, Y down).
    private var edgeRect: CGRect = .zero

    /// The CGEventTap Mach port.
    /// `private(set)` because the callback function needs read access to re-enable the tap.
    private(set) var eventTap: CFMachPort?

    /// The run loop source for the event tap.
    private var runLoopSource: CFRunLoopSource?

    /// Whether the guard is currently active.
    private(set) var isActive: Bool = false

    // MARK: - Configuration

    /// Configure the guard with the touchscreen device IDs and Edge screen geometry.
    ///
    /// Must be called before `start()`. Can be called again if devices change or
    /// the display is rearranged.
    func configure(touchDeviceIDs: Set<Int64>, edgeScreen: NSScreen) {
        self.touchDeviceIDs = touchDeviceIDs

        // Convert NSScreen frame (Cocoa coords) to CG coords
        let primaryHeight = NSScreen.screens.first?.frame.height ?? edgeScreen.frame.height
        self.edgeRect = TouchCoordinateMath.cocoaToCGRect(edgeScreen.frame, primaryHeight: primaryHeight)

        logger.notice("Configured — \(touchDeviceIDs.count) touch device(s), edge rect: (\(Int(self.edgeRect.origin.x)),\(Int(self.edgeRect.origin.y))) \(Int(self.edgeRect.width))×\(Int(self.edgeRect.height))")
    }

    /// Update the Edge screen geometry (e.g. after display rearrangement).
    func updateEdgeScreen(_ screen: NSScreen) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        self.edgeRect = TouchCoordinateMath.cocoaToCGRect(screen.frame, primaryHeight: primaryHeight)
        logger.notice("Edge rect updated: (\(Int(self.edgeRect.origin.x)),\(Int(self.edgeRect.origin.y))) \(Int(self.edgeRect.width))×\(Int(self.edgeRect.height))")
    }

    // MARK: - Lifecycle

    /// Start blocking non-touch mouse events on the Edge display.
    func start() {
        guard !isActive else { return }
        guard !touchDeviceIDs.isEmpty else {
            logger.warning("Cannot start — no touch device IDs configured")
            return
        }
        guard edgeRect != .zero else {
            logger.warning("Cannot start — edge screen rect not configured")
            return
        }

        let eventMask: CGEventMask = (
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.leftMouseUp.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.rightMouseUp.rawValue) |
            (1 << CGEventType.scrollWheel.rawValue)
        )

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: mouseGuardCallback,
            userInfo: userInfo
        ) else {
            logger.error("Failed to create CGEventTap for MouseGuard")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)

        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        }

        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        logger.notice("Mouse guard started — blocking non-touch events on Edge")
    }

    /// Stop the mouse guard.
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
        logger.notice("Mouse guard stopped")
    }

    // MARK: - Event Processing

    /// Process an event — suppress if it's a non-touch event landing on the Edge.
    func processEvent(_ event: CGEvent) -> CGEvent? {
        let deviceID = event.getIntegerValueField(CGEventField(rawValue: 87)!)
        let location = event.location

        // Always allow events from the touchscreen device(s)
        if touchDeviceIDs.contains(deviceID) {
            return event
        }

        // If the event lands within the Edge display bounds, suppress it
        if edgeRect.contains(location) {
            return nil
        }

        // Event is outside the Edge — allow it
        return event
    }
}

// MARK: - C Callback

/// The CGEventTap callback for MouseGuard.
nonisolated private func mouseGuardCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // Handle tap disabled events
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo {
            let guard_ = Unmanaged<MouseGuard>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = guard_.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let guard_ = Unmanaged<MouseGuard>.fromOpaque(userInfo).takeUnretainedValue()

    if let processed = guard_.processEvent(event) {
        return Unmanaged.passUnretained(processed)
    }

    // processEvent returned nil → suppress the event
    return nil
}
