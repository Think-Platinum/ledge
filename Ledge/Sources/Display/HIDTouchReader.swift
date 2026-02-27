@preconcurrency import AppKit
import CoreGraphics
import IOKit
import IOKit.hid
import os.log

/// Reads raw HID digitizer reports directly from the Xeneon Edge touchscreen.
///
/// This bypasses macOS's broken USB touchscreen → primary display mapping by
/// reading the 54-byte touch reports from the Digitizer interface
/// (UsagePage=0x0D, Usage=4) and converting raw coordinates directly to the
/// Xeneon Edge's screen position.
///
/// ## How It Works
///
/// 1. Opens the Digitizer HID interface (non-exclusively) via `IOHIDManager`
/// 2. Receives raw input reports on a **dedicated background thread** with its
///    own CFRunLoop — NOT the main run loop, to avoid starving CGEventTap
///    and UI rendering
/// 3. Parses contacts via `HIDReportParser`
/// 4. Constructs NSEvents at the correct window-local coordinates
/// 5. Delivers directly to `LedgePanel.sendEvent()` via main queue dispatch
///
/// macOS still generates wrongly-mapped mouse events from the same touch data.
/// `TouchRemapper` runs in suppression-only mode to return `nil` for those,
/// preventing cursor movement on the primary display.
///
/// This class is `nonisolated` because IOHIDManager callbacks run on the
/// dedicated HID thread and cannot be confined to MainActor.
nonisolated class HIDTouchReader {

    let logger = Logger(subsystem: "com.ledge.app", category: "HIDTouchReader")

    // MARK: - Device Constants

    /// Known USB identifiers (shared with HIDTouchDetector).
    static let touchVendorID = HIDTouchDetector.touchVendorID      // 0x27C0
    static let touchProductID = HIDTouchDetector.touchProductID    // 0x0859
    static let digitizerUsagePage = HIDTouchDetector.digitizerUsagePage  // 0x0D
    static let touchScreenUsage = HIDTouchDetector.touchScreenUsage      // 4

    // MARK: - Panel & Geometry

    /// The panel to deliver touch events to. Weak to avoid retain cycles.
    weak var panel: LedgePanel?

    /// Panel dimensions for coordinate mapping.
    var panelWidth: CGFloat = 2560
    var panelHeight: CGFloat = 720

    // MARK: - IOKit State

    private var manager: IOHIDManager?
    var digitizerDevice: IOHIDDevice?

    /// Pre-allocated buffer for device-level input report callbacks.
    /// IOHIDDeviceRegisterInputReportCallback requires a persistent buffer
    /// that the system writes report data into before invoking the callback.
    /// Size is determined at runtime from the device's maxInputReportSize.
    var reportBuffer: UnsafeMutablePointer<UInt8>?
    var reportBufferSize: Int = 0

    /// Total reports received — used to confirm the callback is firing
    /// and to rate-limit debug logging.
    var totalReportCount: UInt64 = 0

    /// Dedicated background thread for the HID run loop.
    /// Keeps all HID callbacks off the main run loop to prevent starving
    /// CGEventTap and UI rendering.
    private var hidThread: Thread?

    /// The run loop running on the HID thread.
    private var hidRunLoop: CFRunLoop?

    /// Whether the reader is currently active and listening for reports.
    private(set) var isActive: Bool = false

    // MARK: - Touch State

    /// Per-slot contact state from the previous report (for change detection).
    var previousContacts: [Int: TouchContact] = [:]

    /// Whether we're currently tracking a touch sequence (finger is down).
    var isTrackingTouch: Bool = false

    /// Counter for throttling drag/move log messages.
    private var moveLogCounter: Int = 0

    /// Sequence counter — increments on each touch-down for correlating logs.
    private var touchSequenceID: UInt64 = 0

    // MARK: - Debug

    /// Number of raw reports to hex-dump for format validation. Set > 0 to enable.
    var debugReportLogCount: Int = 0

    /// Counter tracking how many reports have been logged.
    private var debugReportsLogged: Int = 0

    // MARK: - Callbacks

    /// Invoked when a touch event is processed (for flight recorder / diagnostics).
    var onTouchEvent: ((_ contact: TouchContact,
                        _ eventType: TouchEventType,
                        _ sequenceID: UInt64,
                        _ arrivalTime: Date) -> Void)?

    /// Invoked when the HID device disconnects (for fallback handling).
    var onDeviceDisconnected: (() -> Void)?

    // MARK: - Lifecycle

    /// Start listening for digitizer reports.
    ///
    /// - Parameter panelFrame: The panel's frame (Cocoa coordinates) for mapping.
    func start(panelFrame: NSRect) {
        guard !isActive else { return }

        panelWidth = panelFrame.width
        panelHeight = panelFrame.height

        // Capture config values for the thread closure
        let vendorID = Self.touchVendorID
        let productID = Self.touchProductID
        let usagePage = Self.digitizerUsagePage
        let usage = Self.touchScreenUsage

        // ALL IOHIDManager setup happens on the dedicated background thread.
        // This is critical: callback registration, scheduling, and opening must
        // all happen on the same thread whose run loop will service the manager.
        // Registering callbacks on the main thread and scheduling on a background
        // thread causes input report callbacks to never fire.
        let thread = Thread { [weak self] in
            guard let self else { return }
            guard let runLoop = CFRunLoopGetCurrent() else {
                self.logger.error("Failed to get CFRunLoop for HID thread")
                return
            }
            self.hidRunLoop = runLoop

            let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            self.manager = mgr

            // Match specifically the Digitizer interface (not Mouse or Vendor)
            let criteria: [String: Any] = [
                kIOHIDVendorIDKey as String: vendorID,
                kIOHIDProductIDKey as String: productID,
                kIOHIDPrimaryUsagePageKey as String: usagePage,
                kIOHIDPrimaryUsageKey as String: usage,
            ]
            IOHIDManagerSetDeviceMatching(mgr, criteria as CFDictionary)

            // Register device matching/removal at manager level.
            // Input report callback is registered per-device in hidDeviceConnected
            // because IOHIDManagerRegisterInputReportCallback is unreliable —
            // it silently fails to deliver reports for some device types.
            let context = Unmanaged.passUnretained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(mgr, hidDeviceConnected, context)
            IOHIDManagerRegisterDeviceRemovalCallback(mgr, hidDeviceRemoved, context)

            // Schedule on this thread's run loop, then open.
            IOHIDManagerScheduleWithRunLoop(mgr, runLoop,
                                             CFRunLoopMode.defaultMode.rawValue)

            let openResult = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
            guard openResult == kIOReturnSuccess else {
                self.logger.error("Failed to open HID Manager: \(openResult)")
                return
            }

            self.logger.notice("HID run loop started on background thread")

            // Run the loop until stopped. CFRunLoopRun() blocks here.
            CFRunLoopRun()

            self.logger.notice("HID run loop exited")
        }
        thread.name = "com.ledge.hid-touch"
        thread.qualityOfService = .userInteractive as QualityOfService
        hidThread = thread
        thread.start()

        isActive = true
        debugReportsLogged = 0
        logger.notice("HID Touch Reader started — listening for digitizer reports on VID=\(Self.touchVendorID)/PID=\(Self.touchProductID)")
        let debugCount = self.debugReportLogCount
        logger.notice("  Panel: \(Int(self.panelWidth))×\(Int(self.panelHeight)), debug reports: \(debugCount)")
    }

    /// Stop listening and release resources.
    func stop() {
        guard isActive else { return }

        // Deregister the device-level callback before closing/destroying anything.
        // Passing nil callback safely unregisters it.
        if let device = digitizerDevice, let buf = reportBuffer {
            IOHIDDeviceRegisterInputReportCallback(device, buf, CFIndex(reportBufferSize), nil, nil)
        }

        if let manager, let runLoop = hidRunLoop {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, runLoop,
                                               CFRunLoopMode.defaultMode.rawValue)
            CFRunLoopStop(runLoop)
        }
        cleanup()
        logger.notice("HID Touch Reader stopped")
    }

    private func cleanup() {
        manager = nil
        digitizerDevice = nil
        reportBuffer?.deallocate()
        reportBuffer = nil
        reportBufferSize = 0
        totalReportCount = 0
        hidRunLoop = nil
        hidThread = nil
        isActive = false
        previousContacts.removeAll()
        isTrackingTouch = false
        moveLogCounter = 0
    }

    /// Update panel dimensions when display configuration changes.
    func updatePanelFrame(_ frame: NSRect) {
        panelWidth = frame.width
        panelHeight = frame.height
        logger.notice("Panel frame updated: \(Int(frame.width))×\(Int(frame.height))")
    }

    // MARK: - Report Handling

    /// Process a raw HID report from the digitizer.
    ///
    /// This is called from the HID background thread at up to the USB polling rate
    /// (potentially 1000Hz). It MUST be fast — no allocations or logging in the
    /// common path. Only the first few reports are hex-dumped for diagnostics.
    func handleReport(reportID: UInt32, report: UnsafeMutablePointer<UInt8>, length: Int) {
        totalReportCount += 1

        // Log the very first report to confirm the pipeline works,
        // then selectively hex-dump a few more for format validation.
        // Use power-of-2 checks for the "alive" log to avoid flooding.
        if totalReportCount == 1 {
            logger.notice("✅ First HID report received! (id=\(reportID), len=\(length))")
        }

        if debugReportLogCount > 0 && debugReportsLogged < debugReportLogCount {
            debugReportsLogged += 1
            let hex = HIDReportParser.hexDump(report: report, length: length)
            logger.notice("📦 HID report #\(self.debugReportsLogged) (id=\(reportID), len=\(length)): \(hex)")
        } else if totalReportCount == 100 || totalReportCount == 1000 {
            // Periodic "alive" log at milestones — confirms reports keep flowing
            logger.notice("HID report milestone: \(self.totalReportCount) reports received")
        }

        // Only process digitizer reports (report ID 0x0D, 54 bytes)
        guard reportID == UInt32(HIDReportParser.digitizerReportID) else { return }
        guard length == HIDReportParser.expectedReportLength else { return }

        let arrivalTime = Date()

        guard let parsed = HIDReportParser.parse(report: report, length: length) else {
            return  // Silently skip unparseable reports — don't log in hot path
        }

        processContactChanges(parsed: parsed, arrivalTime: arrivalTime)
    }

    // MARK: - Contact State Machine

    /// Compare current report against previous state and generate events.
    private func processContactChanges(parsed: HIDReportParser.ParseResult, arrivalTime: Date) {
        // For now, process only the primary contact (slot 0).
        // Multi-touch contacts are parsed but not delivered as NSEvents.
        // Future: gesture recognition from multi-contact state.

        guard let primary = parsed.contacts.first else {
            // No contacts in report
            if isTrackingTouch {
                deliverTouchUp(contact: previousContacts[0], arrivalTime: arrivalTime)
            }
            previousContacts.removeAll()
            return
        }

        if !parsed.fingersDown {
            // Finger-up frame
            if isTrackingTouch {
                deliverTouchUp(contact: primary, arrivalTime: arrivalTime)
            }
            previousContacts.removeAll()
            return
        }

        if !isTrackingTouch {
            // New touch down
            touchSequenceID += 1
            moveLogCounter = 0
            isTrackingTouch = true
            deliverTouchDown(contact: primary, arrivalTime: arrivalTime)
        } else {
            // Ongoing drag
            deliverTouchDrag(contact: primary, arrivalTime: arrivalTime)
        }

        // Store current contacts for next comparison
        previousContacts.removeAll()
        for contact in parsed.contacts {
            previousContacts[contact.slot] = contact
        }
    }

    // MARK: - Event Delivery

    private func deliverTouchDown(contact: TouchContact, arrivalTime: Date) {
        logger.notice("🔽 [seq \(self.touchSequenceID)] HID DOWN raw=(\(contact.rawX),\(contact.rawY)) → display=(\(Int(contact.displayX)),\(Int(contact.displayY)))")
        deliverNSEvent(type: .leftMouseDown, contact: contact, clickCount: 1)
        onTouchEvent?(contact, .down, touchSequenceID, arrivalTime)
    }

    private func deliverTouchDrag(contact: TouchContact, arrivalTime: Date) {
        moveLogCounter += 1
        if moveLogCounter % 30 == 1 {
            logger.notice("↔ [seq \(self.touchSequenceID)] HID DRAG #\(self.moveLogCounter) raw=(\(contact.rawX),\(contact.rawY))")
        }
        deliverNSEvent(type: .leftMouseDragged, contact: contact, clickCount: 0)
        onTouchEvent?(contact, .moved, touchSequenceID, arrivalTime)
    }

    private func deliverTouchUp(contact: TouchContact?, arrivalTime: Date) {
        let logX = contact?.rawX ?? 0
        let logY = contact?.rawY ?? 0
        logger.notice("🔼 [seq \(self.touchSequenceID)] HID UP raw=(\(logX),\(logY)) dragEvents=\(self.moveLogCounter)")

        if let contact {
            deliverNSEvent(type: .leftMouseUp, contact: contact, clickCount: 1)
            onTouchEvent?(contact, .up, touchSequenceID, arrivalTime)
        }

        isTrackingTouch = false
        moveLogCounter = 0
    }

    /// Construct an NSEvent and deliver to the panel on the main thread.
    ///
    /// Coordinate mapping is direct: raw HID coordinates (0-65535) scale to
    /// panel dimensions, then Y is flipped for Cocoa (origin bottom-left).
    /// No CG↔Cocoa conversion needed since we own the coordinate space.
    ///
    /// Called from the HID background thread — dispatches to main queue for
    /// NSEvent creation and panel delivery.
    private func deliverNSEvent(type: NSEvent.EventType, contact: TouchContact, clickCount: Int) {
        guard let panel = self.panel else {
            logger.warning("⚠ [seq \(self.touchSequenceID)] No panel — cannot deliver \(type.rawValue)")
            return
        }

        let windowPoint = contact.windowPoint(panelWidth: panelWidth, panelHeight: panelHeight)
        let pressure: Float = (type == .leftMouseUp) ? 0.0 : 1.0
        let capturedPanel = panel

        // Dispatch to main queue — NSEvent creation needs MainActor context
        // (panel.windowNumber), and panel.sendEvent() must run on main thread.
        DispatchQueue.main.async {
            let windowNumber = capturedPanel.windowNumber

            guard let nsEvent = NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: clickCount,
                pressure: pressure
            ) else {
                return
            }

            NSApp.preventWindowOrdering()
            if !capturedPanel.isKeyWindow {
                capturedPanel.makeKey()
            }
            capturedPanel.sendEvent(nsEvent)
        }
    }
}

// MARK: - IOHIDManager C Callbacks

// These must be nonisolated free functions because:
// 1. IOHIDManager requires @convention(c) function pointers
// 2. The project uses SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, so file-scope
//    functions inherit MainActor unless explicitly marked nonisolated

/// Called when a matching HID device is connected.
nonisolated private func hidDeviceConnected(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let reader = Unmanaged<HIDTouchReader>.fromOpaque(context).takeUnretainedValue()
    reader.digitizerDevice = device

    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String
    let maxReport = IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
    reader.logger.notice("Digitizer device connected: \(name ?? "unknown") (maxInputReport=\(maxReport))")

    // Allocate report buffer based on the ACTUAL device max report size.
    // Using a smaller buffer causes IOKit to write past the end → heap corruption → system lockup.
    let bufferSize = max(maxReport, 256)  // At least 256 for safety
    let reportBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    reportBuf.initialize(repeating: 0, count: bufferSize)

    // Deallocate any previous buffer (shouldn't happen, but be safe)
    reader.reportBuffer?.deallocate()
    reader.reportBuffer = reportBuf
    reader.reportBufferSize = bufferSize
    reader.totalReportCount = 0

    reader.logger.notice("Allocated report buffer: \(bufferSize) bytes")

    // Register device-level input report callback.
    // The manager-level IOHIDManagerRegisterInputReportCallback silently
    // fails to deliver reports for some device types.
    IOHIDDeviceRegisterInputReportCallback(
        device,
        reportBuf,
        CFIndex(bufferSize),
        hidDeviceReportReceived,
        context
    )
    reader.logger.notice("Registered device-level input report callback")
}

/// Called when the matched HID device is disconnected.
nonisolated private func hidDeviceRemoved(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    guard let context else { return }
    let reader = Unmanaged<HIDTouchReader>.fromOpaque(context).takeUnretainedValue()

    // Deregister the input report callback before releasing the device reference.
    if let buf = reader.reportBuffer {
        IOHIDDeviceRegisterInputReportCallback(device, buf, CFIndex(reader.reportBufferSize), nil, nil)
    }

    reader.digitizerDevice = nil
    reader.previousContacts.removeAll()
    reader.isTrackingTouch = false

    reader.logger.notice("Digitizer device disconnected")
    reader.onDeviceDisconnected?()
}

/// Called for every raw HID input report from the matched device.
/// Registered per-device via IOHIDDeviceRegisterInputReportCallback.
nonisolated private func hidDeviceReportReceived(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard let context else { return }
    let reader = Unmanaged<HIDTouchReader>.fromOpaque(context).takeUnretainedValue()
    reader.handleReport(reportID: reportID, report: report, length: Int(reportLength))
}
