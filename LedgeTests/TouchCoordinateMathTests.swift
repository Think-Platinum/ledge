import XCTest
import AppKit

/// Unit tests for the pure coordinate transformation functions in TouchCoordinateMath.
///
/// These functions are the core of the touch remapping pipeline. Getting them wrong
/// means touch events land in the wrong place — so we test thoroughly.
///
/// Test fixtures use realistic display geometries:
/// - Primary display: 3024×1964 (MacBook Pro 14" Retina at 2x)
/// - Xeneon Edge: 2560×720 (Corsair Xeneon Edge, positioned below primary)
final class TouchCoordinateMathTests: XCTestCase {

    // MARK: - Test Fixtures

    /// Typical primary display — MacBook Pro 14" Retina
    let primaryFrame = NSRect(x: 0, y: 0, width: 3024, height: 1964)
    let primaryHeight: CGFloat = 1964

    /// Xeneon Edge positioned below the primary display.
    /// In Cocoa coords: origin.y is negative (below primary).
    let edgeFrameCocoa = NSRect(x: 232, y: -720, width: 2560, height: 720)

    // MARK: - cocoaToCGRect Tests

    func testCocoaToCGRect_primaryDisplay() {
        // Primary display origin in CG should be (0, 0)
        let cg = TouchCoordinateMath.cocoaToCGRect(primaryFrame, primaryHeight: primaryHeight)
        XCTAssertEqual(cg.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(cg.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(cg.width, 3024, accuracy: 0.001)
        XCTAssertEqual(cg.height, 1964, accuracy: 0.001)
    }

    func testCocoaToCGRect_edgeBelowPrimary() {
        // Edge is below primary: Cocoa y=-720, height=720
        // CG y = primaryHeight - cocoaY - height = 1964 - (-720) - 720 = 1964
        let cg = TouchCoordinateMath.cocoaToCGRect(edgeFrameCocoa, primaryHeight: primaryHeight)
        XCTAssertEqual(cg.origin.x, 232, accuracy: 0.001)
        XCTAssertEqual(cg.origin.y, 1964, accuracy: 0.001)
        XCTAssertEqual(cg.width, 2560, accuracy: 0.001)
        XCTAssertEqual(cg.height, 720, accuracy: 0.001)
    }

    func testCocoaToCGRect_edgeRightOfPrimary() {
        // Edge to the right: Cocoa origin = (3024, 0)
        let rightEdge = NSRect(x: 3024, y: 0, width: 2560, height: 720)
        let cg = TouchCoordinateMath.cocoaToCGRect(rightEdge, primaryHeight: primaryHeight)
        XCTAssertEqual(cg.origin.x, 3024, accuracy: 0.001)
        // CG y = 1964 - 0 - 720 = 1244
        XCTAssertEqual(cg.origin.y, 1244, accuracy: 0.001)
    }

    func testCocoaToCGRect_edgeAbovePrimary() {
        // Edge above: Cocoa origin = (0, 1964) — top of primary in Cocoa
        let aboveEdge = NSRect(x: 0, y: 1964, width: 2560, height: 720)
        let cg = TouchCoordinateMath.cocoaToCGRect(aboveEdge, primaryHeight: primaryHeight)
        // CG y = 1964 - 1964 - 720 = -720 (above primary in CG space)
        XCTAssertEqual(cg.origin.y, -720, accuracy: 0.001)
    }

    // MARK: - remapPoint Tests

    func testRemapPoint_centerOfPrimary() {
        let sourceCG = CGRect(x: 0, y: 0, width: 3024, height: 1964)
        let targetCG = CGRect(x: 232, y: 1964, width: 2560, height: 720)

        // Center of primary → center of Edge
        let center = CGPoint(x: 1512, y: 982)
        let result = TouchCoordinateMath.remapPoint(from: sourceCG, to: targetCG, point: center)

        XCTAssertNotNil(result)
        // normX = 0.5, normY = 0.5
        // remappedX = 232 + 0.5 * 2560 = 1512
        // remappedY = 1964 + 0.5 * 720 = 2324
        XCTAssertEqual(result!.x, 1512, accuracy: 0.001)
        XCTAssertEqual(result!.y, 2324, accuracy: 0.001)
    }

    func testRemapPoint_topLeftCorner() {
        let sourceCG = CGRect(x: 0, y: 0, width: 3024, height: 1964)
        let targetCG = CGRect(x: 232, y: 1964, width: 2560, height: 720)

        let topLeft = CGPoint(x: 0, y: 0)
        let result = TouchCoordinateMath.remapPoint(from: sourceCG, to: targetCG, point: topLeft)

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, 232, accuracy: 0.001)   // Target origin X
        XCTAssertEqual(result!.y, 1964, accuracy: 0.001)  // Target origin Y
    }

    func testRemapPoint_bottomRightCorner() {
        let sourceCG = CGRect(x: 0, y: 0, width: 3024, height: 1964)
        let targetCG = CGRect(x: 232, y: 1964, width: 2560, height: 720)

        let bottomRight = CGPoint(x: 3024, y: 1964)
        let result = TouchCoordinateMath.remapPoint(from: sourceCG, to: targetCG, point: bottomRight)

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, 232 + 2560, accuracy: 0.001)
        XCTAssertEqual(result!.y, 1964 + 720, accuracy: 0.001)
    }

    func testRemapPoint_outOfBounds_negative() {
        let sourceCG = CGRect(x: 0, y: 0, width: 3024, height: 1964)
        let targetCG = CGRect(x: 232, y: 1964, width: 2560, height: 720)

        let outsideLeft = CGPoint(x: -1, y: 500)
        XCTAssertNil(TouchCoordinateMath.remapPoint(from: sourceCG, to: targetCG, point: outsideLeft))
    }

    func testRemapPoint_outOfBounds_tooLarge() {
        let sourceCG = CGRect(x: 0, y: 0, width: 3024, height: 1964)
        let targetCG = CGRect(x: 232, y: 1964, width: 2560, height: 720)

        let outsideBottom = CGPoint(x: 500, y: 1965)
        XCTAssertNil(TouchCoordinateMath.remapPoint(from: sourceCG, to: targetCG, point: outsideBottom))
    }

    func testRemapPoint_zeroSizeSource() {
        let zeroSource = CGRect(x: 0, y: 0, width: 0, height: 0)
        let targetCG = CGRect(x: 0, y: 0, width: 2560, height: 720)

        XCTAssertNil(TouchCoordinateMath.remapPoint(from: zeroSource, to: targetCG, point: .zero))
    }

    func testRemapPoint_preservesAspectMapping() {
        // 25% across primary → 25% across Edge
        let sourceCG = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let targetCG = CGRect(x: 100, y: 1000, width: 2560, height: 720)

        let quarterPoint = CGPoint(x: 500, y: 250)  // 25% X, 25% Y
        let result = TouchCoordinateMath.remapPoint(from: sourceCG, to: targetCG, point: quarterPoint)

        XCTAssertNotNil(result)
        XCTAssertEqual(result!.x, 100 + 0.25 * 2560, accuracy: 0.001)
        XCTAssertEqual(result!.y, 1000 + 0.25 * 720, accuracy: 0.001)
    }

    // MARK: - cgPointToWindowLocal Tests

    func testCGPointToWindowLocal_originOfWindow() {
        // Window at Cocoa (232, -720) means CG top-left is (232, 1964)
        let windowFrame = NSRect(x: 232, y: -720, width: 2560, height: 720)
        let cgPoint = CGPoint(x: 232, y: 1964)  // Top-left of window in CG

        let local = TouchCoordinateMath.cgPointToWindowLocal(
            cgPoint,
            windowFrame: windowFrame,
            primaryHeight: primaryHeight
        )

        // Window-local: x=0 (leftmost), y=720 (topmost in Cocoa = height)
        XCTAssertEqual(local.x, 0, accuracy: 0.001)
        XCTAssertEqual(local.y, 720, accuracy: 0.001)
    }

    func testCGPointToWindowLocal_bottomRightOfWindow() {
        let windowFrame = NSRect(x: 232, y: -720, width: 2560, height: 720)
        // Bottom-right in CG = (232+2560, 1964+720) = (2792, 2684)
        let cgPoint = CGPoint(x: 2792, y: 2684)

        let local = TouchCoordinateMath.cgPointToWindowLocal(
            cgPoint,
            windowFrame: windowFrame,
            primaryHeight: primaryHeight
        )

        // Window-local: x=2560 (rightmost), y=0 (bottommost in Cocoa)
        XCTAssertEqual(local.x, 2560, accuracy: 0.001)
        XCTAssertEqual(local.y, 0, accuracy: 0.001)
    }

    func testCGPointToWindowLocal_centerOfWindow() {
        let windowFrame = NSRect(x: 0, y: 0, width: 1000, height: 500)
        // CG center of this window: (500, primaryHeight - 0 - 500 + 250) = (500, 1714)
        // Actually: window top in CG = primaryHeight - cocoaY - height = 1964 - 0 - 500 = 1464
        // Window center CG = (500, 1464 + 250) = (500, 1714)
        let cgPoint = CGPoint(x: 500, y: 1714)

        let local = TouchCoordinateMath.cgPointToWindowLocal(
            cgPoint,
            windowFrame: windowFrame,
            primaryHeight: primaryHeight
        )

        // cocoaGlobalY = 1964 - 1714 = 250
        // localX = 500 - 0 = 500
        // localY = 250 - 0 = 250
        XCTAssertEqual(local.x, 500, accuracy: 0.001)
        XCTAssertEqual(local.y, 250, accuracy: 0.001)
    }
}
