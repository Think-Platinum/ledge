import CoreGraphics
import AppKit

/// Pure coordinate transformation functions for the touch remapping pipeline.
///
/// macOS uses two different coordinate systems:
///
/// - **Cocoa/AppKit** (NSScreen.frame, NSWindow.frame, NSEvent.locationInWindow):
///   Origin at **bottom-left** of the primary display, Y axis points **up**.
///
/// - **CG/Quartz** (CGEvent.location, CGDisplayBounds):
///   Origin at **top-left** of the primary display, Y axis points **down**.
///
/// These functions handle the conversions needed to remap USB touchscreen
/// coordinates (which arrive in CG space mapped to the primary display)
/// to the correct position on the Xeneon Edge display.
///
/// All functions are pure — they take geometry parameters and return results
/// with no side effects, making them trivially unit-testable.
nonisolated enum TouchCoordinateMath {

    /// Convert an NSScreen/Cocoa frame (origin bottom-left, Y up) to
    /// CG/Quartz coordinates (origin top-left, Y down).
    ///
    /// CGEvent.location uses CG coordinates, so we must work in that space
    /// when processing touch events.
    ///
    /// - Parameters:
    ///   - cocoaFrame: The frame in Cocoa coordinates (e.g. from `NSScreen.frame`).
    ///   - primaryHeight: The height of the primary display in points
    ///     (i.e. `NSScreen.screens.first?.frame.height`).
    /// - Returns: The equivalent rectangle in CG coordinates.
    static func cocoaToCGRect(_ cocoaFrame: NSRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(
            x: cocoaFrame.origin.x,
            y: primaryHeight - cocoaFrame.origin.y - cocoaFrame.height,
            width: cocoaFrame.width,
            height: cocoaFrame.height
        )
    }

    /// Remap a point from one CG-coordinate rectangle to another.
    ///
    /// The USB touchscreen digitiser maps absolute coordinates to the primary display.
    /// This function normalises the point relative to the source rectangle (primary display),
    /// then maps it into the target rectangle (Xeneon Edge).
    ///
    /// - Parameters:
    ///   - sourceRect: The source display rectangle in CG coordinates (primary display).
    ///   - targetRect: The target display rectangle in CG coordinates (Xeneon Edge).
    ///   - point: The point to remap, in CG coordinates.
    /// - Returns: The remapped point in CG coordinates, or `nil` if the point is
    ///   outside the source rectangle or the source has zero size.
    static func remapPoint(
        from sourceRect: CGRect,
        to targetRect: CGRect,
        point: CGPoint
    ) -> CGPoint? {
        guard sourceRect.width > 0, sourceRect.height > 0 else {
            return nil
        }

        // Normalise to [0, 1] relative to source
        let normX = (point.x - sourceRect.origin.x) / sourceRect.width
        let normY = (point.y - sourceRect.origin.y) / sourceRect.height

        // Reject points outside the source rectangle
        guard normX >= 0, normX <= 1, normY >= 0, normY <= 1 else {
            return nil
        }

        // Map into target rectangle
        return CGPoint(
            x: targetRect.origin.x + normX * targetRect.width,
            y: targetRect.origin.y + normY * targetRect.height
        )
    }

    /// Convert a CG point (origin top-left, Y down) to window-local Cocoa
    /// coordinates (origin bottom-left of window, Y up).
    ///
    /// Used when building `NSEvent` objects for direct delivery to `LedgePanel`.
    ///
    /// - Parameters:
    ///   - cgPoint: The point in CG/Quartz global coordinates.
    ///   - windowFrame: The window's frame in Cocoa coordinates (`NSWindow.frame`).
    ///   - primaryHeight: The height of the primary display in points.
    /// - Returns: The point in the window's local coordinate system.
    static func cgPointToWindowLocal(
        _ cgPoint: CGPoint,
        windowFrame: NSRect,
        primaryHeight: CGFloat
    ) -> NSPoint {
        // CG → Cocoa global: flip Y around primary display height
        let cocoaGlobalY = primaryHeight - cgPoint.y
        // Cocoa global → window-local: subtract window origin
        return NSPoint(
            x: cgPoint.x - windowFrame.origin.x,
            y: cocoaGlobalY - windowFrame.origin.y
        )
    }
}
