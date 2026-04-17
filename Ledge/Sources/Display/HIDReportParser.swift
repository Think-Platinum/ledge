import Foundation

/// A single touch contact point from the Xeneon Edge digitizer.
///
/// Parsed from raw HID reports. Supports up to 5 simultaneous contacts.
nonisolated struct TouchContact: Sendable {
    /// Contact slot index (0-4) within the report.
    let slot: Int

    /// Raw X coordinate from HID report (0-65535).
    let rawX: UInt16

    /// Raw Y coordinate from HID report (0-65535).
    let rawY: UInt16

    /// Whether the finger is currently touching (true) or lifted (false).
    let isDown: Bool

    /// Xeneon Edge display resolution.
    static let displayWidth: CGFloat = 2560
    static let displayHeight: CGFloat = 720
    static let maxRaw: CGFloat = 65535

    /// Display-space X coordinate (mapped to Edge width).
    var displayX: CGFloat { CGFloat(rawX) * Self.displayWidth / Self.maxRaw }

    /// Display-space Y coordinate (mapped to Edge height).
    var displayY: CGFloat { CGFloat(rawY) * Self.displayHeight / Self.maxRaw }

    /// Window-local Cocoa coordinate (origin bottom-left, Y-up).
    /// Assumes a fullscreen panel covering the entire Edge display.
    func windowPoint(panelWidth: CGFloat, panelHeight: CGFloat) -> NSPoint {
        NSPoint(
            x: CGFloat(rawX) * panelWidth / Self.maxRaw,
            y: panelHeight - (CGFloat(rawY) * panelHeight / Self.maxRaw)
        )
    }
}

/// The type of touch event synthesised from HID state changes.
enum TouchEventType: String, Sendable {
    case down  = "down"
    case moved = "moved"
    case up    = "up"
}

/// Pure parser for the Xeneon Edge touchscreen's 54-byte HID digitizer reports.
///
/// The touchscreen (VID=0x27C0, PID=0x0859) sends reports on the Digitizer
/// interface (UsagePage=0x0D, Usage=4) with the following layout:
///
/// ```
/// Byte  0:      Report ID (0x0D)
/// Byte  1:      State — high nibble = contact count (1-5),
///                        low nibble = finger down (1) / up (0)
/// Bytes 2-6:    Contact 0: X_lo, X_hi, Y_lo, Y_hi, flags
/// Bytes 7-11:   Contact 1: same layout
/// Bytes 12-16:  Contact 2: same layout
/// Bytes 17-21:  Contact 3: same layout
/// Bytes 22-26:  Contact 4: same layout
/// Bytes 27-53:  Trailer / padding
/// ```
///
/// **Note**: The per-contact byte layout (5 bytes each) is inferred from
/// observed USB captures and standard HID digitizer conventions. The exact
/// layout should be validated against the 704-byte HID Report Descriptor
/// once captured. The parsing is defensive: it checks bounds and validates
/// expected values before extracting data.
nonisolated enum HIDReportParser {

    /// Expected report ID for touch digitizer reports.
    static let digitizerReportID: UInt8 = 0x0D

    /// Expected report length (bytes, excluding report ID prefix if separate).
    static let expectedReportLength = 54

    /// Maximum number of simultaneous contacts the digitizer supports.
    static let maxContacts = 5

    /// Bytes per contact slot: X(2) + Y(2) + flags(1).
    static let bytesPerContact = 5

    /// Offset of the first contact in the report (after report ID and state byte).
    static let contactBaseOffset = 2

    /// Result of parsing a single HID report.
    struct ParseResult: Sendable {
        /// Number of active contacts reported by the device (0-5).
        let contactCount: Int

        /// Whether any finger is currently touching the screen.
        let fingersDown: Bool

        /// Parsed contacts (up to `contactCount` entries).
        let contacts: [TouchContact]
    }

    /// Parse a 54-byte digitizer report into structured contact data.
    ///
    /// - Parameter report: Raw report bytes. Must be exactly 54 bytes with
    ///   report ID `0x0D` at byte 0.
    /// - Returns: Parsed result, or `nil` if the report is invalid.
    static func parse(report: UnsafeBufferPointer<UInt8>) -> ParseResult? {
        guard report.count == expectedReportLength else { return nil }
        guard report[0] == digitizerReportID else { return nil }

        let stateByte = report[1]
        let contactCount = Int((stateByte >> 4) & 0x0F)
        let fingersDown = (stateByte & 0x0F) != 0

        guard contactCount >= 0, contactCount <= maxContacts else { return nil }

        var contacts: [TouchContact] = []
        contacts.reserveCapacity(contactCount)

        for i in 0..<contactCount {
            let base = contactBaseOffset + (i * bytesPerContact)
            guard base + 4 < report.count else { break }

            let rawX = UInt16(report[base]) | (UInt16(report[base + 1]) << 8)
            let rawY = UInt16(report[base + 2]) | (UInt16(report[base + 3]) << 8)

            contacts.append(TouchContact(
                slot: i,
                rawX: rawX,
                rawY: rawY,
                isDown: fingersDown
            ))
        }

        return ParseResult(
            contactCount: contactCount,
            fingersDown: fingersDown,
            contacts: contacts
        )
    }

    /// Parse from a raw pointer + length (convenience for IOHIDManager callback).
    static func parse(report: UnsafeMutablePointer<UInt8>, length: Int) -> ParseResult? {
        let buffer = UnsafeBufferPointer(start: UnsafePointer(report), count: length)
        return parse(report: buffer)
    }

    /// Format a report as a hex string for debug logging.
    static func hexDump(report: UnsafeMutablePointer<UInt8>, length: Int) -> String {
        (0..<length).map { String(format: "%02X", report[$0]) }.joined(separator: " ")
    }
}
