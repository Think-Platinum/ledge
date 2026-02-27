# Focus Management — Non-Activating Touch Interaction

## The Core Problem

When you tap a widget on the Xeneon Edge touchscreen, macOS treats it like a mouse click on a window. Normally, this would:
1. Activate the Ledge application
2. Make its window the main window
3. Deactivate whatever was previously in the foreground (your game, your IDE, etc.)

This is unacceptable for a companion display. The whole point is to glance at system stats or tap a media control without disrupting your workflow.

## The Solution: NSPanel with nonactivatingPanel

macOS provides `NSPanel` (a subclass of `NSWindow`) specifically for auxiliary panels that shouldn't steal focus. When created with the `.nonactivatingPanel` style mask:

- The panel can receive mouse/touch events
- The panel can become the **key window** (receives keyboard input)
- The panel does **not** become the **main window**
- The panel does **not** activate the owning application
- The previously focused application remains focused

This is exactly how Spotlight, Alfred, and similar overlay tools work on macOS.

## Implementation

### Panel Creation

The `.nonactivatingPanel` style mask **must be set at initialisation time**. There is a known AppKit bug where setting it after init causes the window to appear key but not properly receive events (the internal `kCGSPreventsActivationTagBit` is not correctly toggled). See [philz.blog analysis](https://philz.blog/nspanel-nonactivating-style-mask-flag/).

```swift
class LedgePanel: NSPanel {

    init(on screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        // Panel configuration
        self.level = .floating               // Float above normal windows
        self.isFloatingPanel = true           // Stay above even when app is inactive
        self.hidesOnDeactivate = false        // Don't hide when app loses focus
        self.hasShadow = false                // No window shadow
        self.isOpaque = true                  // Fully opaque (we handle our own background)
        self.backgroundColor = .black         // Black background behind widgets
        self.acceptsMouseMovedEvents = true   // Track mouse/touch movement
        self.isMovableByWindowBackground = false // Don't allow dragging

        // Join all spaces (desktops) and work alongside fullscreen apps
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
    }

    // CRITICAL: Allow the panel to receive keyboard/touch input
    override var canBecomeKey: Bool { true }

    // CRITICAL: Prevent the panel from becoming the main window
    override var canBecomeMain: Bool { false }

    // Accept first responder for touch events
    override var acceptsFirstResponder: Bool { true }
}
```

### Window Level

The panel's `level` property controls its z-ordering:

| Level | Behaviour | Use Case |
|-------|-----------|----------|
| `.floating` | Above normal windows, below alerts | Default for Ledge |
| `.statusBar` | Above floating windows | If widgets should be above everything |
| `.normal` | Same as regular windows | If the user wants Ledge to be coverable |

The user should be able to choose the window level in settings.

### Collection Behaviour

- **`.canJoinAllSpaces`**: The panel appears on all virtual desktops (Spaces). Since the Xeneon Edge is a physical display, the panel should always be visible regardless of which Space is active on the primary display.
- **`.fullScreenAuxiliary`**: The panel works alongside fullscreen apps. If a game is fullscreen on the primary display, the Xeneon Edge panel remains visible and interactive.
- **`.stationary`**: The panel doesn't move when Spaces are switched (it stays put on the Xeneon Edge).

## Edge Cases & Workarounds

### 1. Text Input in Widgets

Some widgets may need text input (a search widget, a note widget). When the user taps a text field in a widget on the Xeneon Edge:
- The `NSPanel` becomes the key window (receives keyboard input)
- The previously focused application is **not** deactivated
- Keyboard input goes to the widget's text field
- When the user clicks back on the primary display, the panel loses key status but remains visible

This works naturally with `NSPanel` + `.nonactivatingPanel`. However, some edge cases:
- **Input methods** (e.g., Chinese/Japanese input) may behave oddly with non-activating panels
- **Autocomplete** popups may appear on the wrong screen
- Recommendation: keep text-heavy interaction in the settings UI (on the primary display), not on the Xeneon Edge

### 2. Touch Event Routing — The macOS Touchscreen Limitation

**Original assumption (WRONG):** We expected macOS to route touch coordinates to the correct screen. In reality, macOS maps external USB touchscreen input to the **primary display**, not to the display the touchscreen is physically attached to. There is no built-in way to associate a USB touch digitiser with a specific secondary display.

**What actually happens:**
1. The Xeneon Edge's touchscreen appears as a standard HID pointing device (PID `0x0859`)
2. Touch events arrive as mouse events (`leftMouseDown`, `leftMouseUp`, `leftMouseDragged`, `mouseMoved`)
3. macOS maps the absolute touch coordinates to the **primary display's** coordinate space
4. The result: touching the Xeneon Edge moves the cursor on the primary monitor

**The fix — TouchRemapper (CGEventTap):**

We use a `CGEventTap` to intercept mouse events and remap coordinates from the primary display to the Xeneon Edge. This is ironic because CGEventTap was rejected for focus management (Section "Alternative Approaches" below) — but it's needed for a completely different purpose: coordinate remapping.

The approach:
1. Create a `CGEventTap` at session level that intercepts mouse-down, mouse-up, mouse-dragged, and mouse-moved events
2. **Calibration step**: The first touch identifies the touchscreen's HID device ID (`CGEvent.getIntegerValueField(.mouseEventDeviceID)`)
3. On subsequent events, check if the event came from the touchscreen device (by device ID)
4. If so, normalise the coordinates against the primary display (0.0–1.0) and map them to the Xeneon Edge's position in the global display space
5. Non-touchscreen events (trackpad, mouse) pass through unmodified

```swift
func remapPoint(_ point: CGPoint) -> CGPoint? {
    // Normalise against primary display
    let normX = (point.x - primaryFrame.origin.x) / primaryFrame.width
    let normY = (point.y - primaryFrame.origin.y) / primaryFrame.height
    // Map to target display
    return CGPoint(
        x: targetFrame.origin.x + normX * targetFrame.width,
        y: targetFrame.origin.y + normY * targetFrame.height
    )
}
```

**Requirements:**
- **Accessibility permissions** (System Settings > Privacy & Security > Accessibility) — required for `CGEvent.tapCreate` with `.defaultTap`
- **App Sandbox disabled** (`ENABLE_APP_SANDBOX = NO` in Xcode) — sandboxed apps cannot create event taps
- The user prompts for Accessibility permission via `AXIsProcessTrustedWithOptions`

**Limitations:**
- Multi-touch is not supported (macOS treats the touchscreen as a single-point mouse device)
- The calibration step requires the user to touch the screen once to identify the device
- If the touchscreen device ID changes (unlikely), recalibration is needed

**Note on `NSTouch` events:** The Xeneon Edge does NOT send `NSTouch` events. Those are reserved for Apple's Magic Trackpad. All touch input arrives as standard mouse events.

### 3. Context Menus

Standard `NSMenu` context menus will activate the application when shown. To maintain non-activating behaviour, we should use custom SwiftUI-based popup menus rendered within the `NSPanel` rather than system context menus.

### 4. Drag and Drop

If a widget supports drag-and-drop (e.g., dragging a file shortcut), this may cause activation issues. For the initial version, drag-and-drop across displays should be avoided. Within-panel drag (e.g., rearranging widgets in edit mode) is fine.

### 5. Alerts and Dialogs

`NSAlert` and modal dialogs will activate the application. Any alert-like UI on the Xeneon Edge should be implemented as custom SwiftUI views within the panel, not as system alerts.

## Testing the Focus Behaviour

A simple test to verify the non-activating behaviour:

1. Open a text editor on the primary display and start typing
2. Tap a widget on the Xeneon Edge
3. Verify: the text editor remains focused, the cursor stays in the text editor
4. Type on the keyboard
5. Verify: keystrokes still go to the text editor (unless a text field in a widget was tapped)

This is the critical user experience test. If it fails, the entire architecture needs revisiting.

## Alternative Approaches Considered

### CGEventTap for Focus Prevention (Rejected)

We could intercept touch events at the system level using `CGEventTap` and prevent them from activating any window. This was rejected for **focus management** because:
- Requires Accessibility permissions
- Fragile — interfering with system event routing can cause unpredictable behaviour
- `NSPanel` with `.nonactivatingPanel` solves the focus problem natively

**Note:** While CGEventTap was rejected for focus management, it IS used for a different purpose — **touch coordinate remapping** (see "Touch Event Routing" above). The key distinction: we use it to move the event to the right screen, not to prevent activation.

### Separate Process (Rejected for now)

Running the widget dashboard as a separate process (not an app with a Dock icon) using `LSUIElement = true` was considered. This would make it behave like a background agent. However:
- It complicates the settings UI (need IPC between the agent and a settings app)
- `NSPanel` already provides the necessary focus behaviour
- May revisit if there are unforeseen focus issues

### Quartz Window Services / Private API (Rejected)

Using `CGSSetWindowTags` or similar private Quartz APIs to set activation flags was considered. Rejected because:
- Private API — could break in any macOS update
- Not necessary — `NSPanel` provides the public API for this
