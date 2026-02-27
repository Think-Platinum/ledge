import XCTest
import CoreGraphics

/// Unit tests for the HID report parser and TouchContact coordinate mapping.
///
/// Tests the pure parsing functions that extract multi-touch contact data from
/// the Xeneon Edge touchscreen's 54-byte HID digitizer reports.
final class HIDReportParserTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal valid 54-byte report with the given contacts.
    private func makeReport(
        contactCount: Int = 1,
        fingersDown: Bool = true,
        contacts: [(x: UInt16, y: UInt16)] = [(6850, 2256)]
    ) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: 54)
        report[0] = 0x0D  // Report ID
        let state = UInt8((contactCount & 0x0F) << 4) | (fingersDown ? 1 : 0)
        report[1] = state

        for (i, contact) in contacts.prefix(5).enumerated() {
            let base = 2 + (i * 5)
            report[base]     = UInt8(contact.x & 0xFF)
            report[base + 1] = UInt8(contact.x >> 8)
            report[base + 2] = UInt8(contact.y & 0xFF)
            report[base + 3] = UInt8(contact.y >> 8)
            report[base + 4] = 0x00  // flags
        }
        return report
    }

    // MARK: - Valid Reports

    func testParseSingleContact() {
        let report = makeReport(contactCount: 1, fingersDown: true, contacts: [(6850, 2256)])
        let result = report.withUnsafeBufferPointer { HIDReportParser.parse(report: $0) }

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.contactCount, 1)
        XCTAssertTrue(result!.fingersDown)
        XCTAssertEqual(result!.contacts.count, 1)

        let c = result!.contacts[0]
        XCTAssertEqual(c.slot, 0)
        XCTAssertEqual(c.rawX, 6850)
        XCTAssertEqual(c.rawY, 2256)
        XCTAssertTrue(c.isDown)
    }

    func testParseFingerUp() {
        let report = makeReport(contactCount: 1, fingersDown: false, contacts: [(1000, 2000)])
        let result = report.withUnsafeBufferPointer { HIDReportParser.parse(report: $0) }

        XCTAssertNotNil(result)
        XCTAssertFalse(result!.fingersDown)
        XCTAssertFalse(result!.contacts[0].isDown)
    }

    func testParseTwoContacts() {
        let report = makeReport(
            contactCount: 2,
            fingersDown: true,
            contacts: [(1000, 2000), (50000, 60000)]
        )
        let result = report.withUnsafeBufferPointer { HIDReportParser.parse(report: $0) }

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.contactCount, 2)
        XCTAssertEqual(result!.contacts.count, 2)
        XCTAssertEqual(result!.contacts[0].rawX, 1000)
        XCTAssertEqual(result!.contacts[1].rawX, 50000)
        XCTAssertEqual(result!.contacts[1].rawY, 60000)
    }

    func testParseFiveContacts() {
        let contacts: [(x: UInt16, y: UInt16)] = [
            (0, 0), (16384, 16384), (32768, 32768), (49152, 49152), (65535, 65535)
        ]
        let report = makeReport(contactCount: 5, fingersDown: true, contacts: contacts)
        let result = report.withUnsafeBufferPointer { HIDReportParser.parse(report: $0) }

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.contacts.count, 5)
        for (i, contact) in result!.contacts.enumerated() {
            XCTAssertEqual(contact.slot, i)
            XCTAssertEqual(contact.rawX, contacts[i].x)
            XCTAssertEqual(contact.rawY, contacts[i].y)
        }
    }

    func testParseZeroContacts() {
        let report = makeReport(contactCount: 0, fingersDown: false, contacts: [])
        let result = report.withUnsafeBufferPointer { HIDReportParser.parse(report: $0) }

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.contactCount, 0)
        XCTAssertTrue(result!.contacts.isEmpty)
    }

    // MARK: - Invalid Reports

    func testRejectWrongLength() {
        let short = [UInt8](repeating: 0x0D, count: 53)
        let resultShort = short.withUnsafeBufferPointer { HIDReportParser.parse(report: $0) }
        XCTAssertNil(resultShort)

        let long = [UInt8](repeating: 0x0D, count: 55)
        let resultLong = long.withUnsafeBufferPointer { HIDReportParser.parse(report: $0) }
        XCTAssertNil(resultLong)
    }

    func testRejectWrongReportID() {
        var report = makeReport()
        report[0] = 0x01  // Wrong report ID
        let result = report.withUnsafeBufferPointer { HIDReportParser.parse(report: $0) }
        XCTAssertNil(result)
    }

    func testRejectInvalidContactCount() {
        var report = makeReport()
        // Set contact count to 6 (invalid — max is 5)
        report[1] = UInt8((6 & 0x0F) << 4) | 1
        let result = report.withUnsafeBufferPointer { HIDReportParser.parse(report: $0) }
        XCTAssertNil(result)
    }

    // MARK: - Coordinate Mapping

    func testCoordinateMapping_origin() {
        let contact = TouchContact(slot: 0, rawX: 0, rawY: 0, isDown: true)
        XCTAssertEqual(contact.displayX, 0)
        XCTAssertEqual(contact.displayY, 0)

        let wp = contact.windowPoint(panelWidth: 2560, panelHeight: 720)
        XCTAssertEqual(wp.x, 0)
        XCTAssertEqual(wp.y, 720)  // Y flipped: top of screen → bottom of window
    }

    func testCoordinateMapping_maxValues() {
        let contact = TouchContact(slot: 0, rawX: 65535, rawY: 65535, isDown: true)
        XCTAssertEqual(contact.displayX, 2560)
        XCTAssertEqual(contact.displayY, 720)

        let wp = contact.windowPoint(panelWidth: 2560, panelHeight: 720)
        XCTAssertEqual(wp.x, 2560)
        XCTAssertEqual(wp.y, 0, accuracy: 0.1)  // Bottom of screen → top of window (near 0)
    }

    func testCoordinateMapping_center() {
        let contact = TouchContact(slot: 0, rawX: 32768, rawY: 32768, isDown: true)

        // Should be approximately center (within rounding)
        XCTAssertEqual(contact.displayX, 1280, accuracy: 1)
        XCTAssertEqual(contact.displayY, 360, accuracy: 1)

        let wp = contact.windowPoint(panelWidth: 2560, panelHeight: 720)
        XCTAssertEqual(wp.x, 1280, accuracy: 1)
        XCTAssertEqual(wp.y, 360, accuracy: 1)
    }

    // MARK: - Hex Dump

    func testHexDumpFormat() {
        var bytes: [UInt8] = [0x0D, 0x11, 0xAB, 0xCD]
        let hex = bytes.withUnsafeMutableBufferPointer { buf in
            HIDReportParser.hexDump(report: buf.baseAddress!, length: buf.count)
        }
        XCTAssertEqual(hex, "0D 11 AB CD")
    }
}
