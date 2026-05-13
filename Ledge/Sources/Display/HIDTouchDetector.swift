import Foundation
import IOKit
import IOKit.hid
import os.log

/// Detects the Xeneon Edge USB touchscreen via IOKit HID Manager.
///
/// macOS provides no built-in way to associate a USB touch digitiser with a specific display.
/// This class identifies the touchscreen hardware by its USB vendor/product ID, then walks
/// the IOKit service tree to find ALL descendant registry entry IDs. CGEvent field 87
/// (`mouseEventDeviceID`) uses the registry entry ID of an IOService *descendant* of the
/// IOHIDDevice (e.g. IOHIDEventDriver or IOHIDPointing), not the IOHIDDevice itself.
///
/// The touchscreen USB device exposes 3 HID interfaces:
/// 1. Digitizer (UsagePage=0x0D, Usage=4) — raw touch digitizer reports
/// 2. Vendor-specific (UsagePage=65290) — proprietary
/// 3. GenericDesktop/Mouse (UsagePage=1, Usage=2) — macOS routes touch-as-mouse here
///
/// We match by VID/PID, confirm the Digitizer interface exists (proving it's a touchscreen),
/// then collect registry entry IDs from ALL interfaces AND their IOService tree descendants.
/// TouchRemapper checks incoming CGEvents against this full set.
nonisolated class HIDTouchDetector {

    private let logger = Logger(subsystem: "com.ledge.app", category: "HIDTouchDetector")

    /// Known USB identifiers for the Xeneon Edge touchscreen controller.
    static let touchVendorID = 10176     // 0x27C0
    static let touchProductID = 2137     // 0x0859

    // HID usage constants
    static let digitizerUsagePage = 13   // kHIDPage_Digitizer (0x0D)
    static let touchScreenUsage = 4      // kHIDUsage_Dig_TouchScreen

    /// Result of detection, including all possible device IDs.
    struct DetectionResult {
        /// All registry entry IDs that might appear as CGEvent field 87.
        /// Includes the IOHIDDevice interfaces AND their IOService tree descendants
        /// (IOHIDEventDriver, IOHIDPointing, etc.).
        let allDeviceIDs: Set<Int64>
        let product: String?
    }

    /// Detect the Xeneon Edge touchscreen and return all possible device IDs.
    ///
    /// Enumerates all HID interfaces for VID/PID, confirms a Digitizer interface
    /// exists, then walks the IOKit service tree to collect all descendant registry
    /// entry IDs. No special permissions required for enumeration.
    func detect() -> DetectionResult? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        // Match by VID/PID only — enumerate ALL interfaces for this device
        let matching: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.touchVendorID,
            kIOHIDProductIDKey as String: Self.touchProductID,
        ]

        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            logger.error("Failed to open HID Manager: \(openResult)")
            return nil
        }

        defer {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        }

        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            logger.info("No HID devices matched touchscreen VID/PID")
            return nil
        }

        logger.info("Found \(devices.count) HID interface(s) for VID=\(Self.touchVendorID)/PID=\(Self.touchProductID)")

        // Verify a Digitizer interface exists (confirms this is actually a touchscreen)
        var hasDigitizer = false
        var product: String?
        var allIDs: Set<Int64> = []

        for device in devices {
            let usagePage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int ?? 0
            let usage = IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int ?? 0
            let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String

            if product == nil { product = name }

            if usagePage == Self.digitizerUsagePage && usage == Self.touchScreenUsage {
                hasDigitizer = true
            }

            // Add the interface's own registry entry ID
            if let regID = registryEntryID(for: device) {
                allIDs.insert(Int64(regID))
                logger.info("  Interface: UsagePage=\(usagePage) Usage=\(usage) RegistryID=\(regID) (\(name ?? "unnamed"))")
            }

            // Walk the IOService tree descendants and add their IDs too.
            // CGEvent field 87 uses the ID of a descendant (e.g. IOHIDEventDriver),
            // not the IOHIDDevice itself.
            //
            // Bug B fix: dedupe by className keeping the HIGHEST registry ID
            // per class. IOKit doesn't always release stale IOService entries
            // from previous IOHIDManagerOpen cycles immediately — they linger
            // in the kIOServicePlane until the kernel garbage-collects them.
            // Each enumeration sees old+new entries side-by-side, so the raw
            // descendant list grew monotonically (16 → 210+ in 50 detect()
            // cycles in the user's reproduction), pumping up `touchDeviceIDs`
            // and slowing CGEvent matching for every event.
            //
            // The live entry for any given class is always the most recently
            // created — i.e. the highest registry ID. Older entries are dead
            // proxies that won't ever generate events. Taking only the
            // highest-per-class:
            //   - bounds the descendant set to ~one entry per distinct class
            //     per interface (typically <10 classes total),
            //   - is stable across enumerations once IOKit settles,
            //   - still includes the active IOHIDEventDriver / IOHIDEvent-
            //     Service whose ID lands in mouseEventDeviceID.
            let descendants = descendantRegistryIDs(for: device)
            var liveByClass: [String: UInt64] = [:]
            for (className, regID) in descendants {
                if let existing = liveByClass[className] {
                    if regID > existing { liveByClass[className] = regID }
                } else {
                    liveByClass[className] = regID
                }
            }
            for (className, regID) in liveByClass {
                allIDs.insert(Int64(regID))
                logger.info("    └─ \(className) RegistryID=\(regID)")
            }
            if descendants.count > liveByClass.count {
                logger.info("    (filtered \(descendants.count - liveByClass.count) stale IOKit registry entries)")
            }
        }

        guard hasDigitizer else {
            logger.warning("VID/PID matched but no Digitizer interface found — not a touchscreen")
            return nil
        }

        logger.info("Touchscreen detected: \(product ?? "unknown")")
        logger.info("  All possible device IDs for CGEvent matching: \(allIDs.sorted())")

        return DetectionResult(
            allDeviceIDs: allIDs,
            product: product
        )
    }

    // MARK: - IOKit Tree Walking

    /// Walk the IOService tree descendants of an IOHIDDevice and collect all
    /// registry entry IDs with their class names.
    private func descendantRegistryIDs(for device: IOHIDDevice) -> [(className: String, registryID: UInt64)] {
        let service = IOHIDDeviceGetService(device)
        guard service != MACH_PORT_NULL else { return [] }

        var results: [(String, UInt64)] = []
        walkChildren(of: service, depth: 0, maxDepth: 4, results: &results)
        return results
    }

    /// Recursively walk children in the IOService plane.
    private func walkChildren(
        of entry: io_registry_entry_t,
        depth: Int,
        maxDepth: Int,
        results: inout [(String, UInt64)]
    ) {
        guard depth < maxDepth else { return }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }

        var child = IOIteratorNext(iterator)
        while child != MACH_PORT_NULL {
            // Get class name
            var classNameBuf = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(child, &classNameBuf)
            let className = String(cString: classNameBuf)

            // Get registry entry ID
            var entryID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(child, &entryID) == KERN_SUCCESS {
                results.append((className, entryID))
            }

            // Recurse into children
            walkChildren(of: child, depth: depth + 1, maxDepth: maxDepth, results: &results)

            IOObjectRelease(child)
            child = IOIteratorNext(iterator)
        }
    }

    // MARK: - Helpers

    /// Get the IOKit registry entry ID for an IOHIDDevice.
    private func registryEntryID(for device: IOHIDDevice) -> UInt64? {
        let service = IOHIDDeviceGetService(device)
        guard service != MACH_PORT_NULL else { return nil }
        var entryID: UInt64 = 0
        let result = IORegistryEntryGetRegistryEntryID(service, &entryID)
        return result == KERN_SUCCESS ? entryID : nil
    }
}
