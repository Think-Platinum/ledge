# USB Protocol & Hardware Control

## Overview

The Corsair Xeneon Edge connects to a computer via:
1. **Video signal**: USB-C (DisplayPort Alt Mode) or HDMI — this is the display path
2. **USB data**: USB-C — this provides touch input, and (on Windows) the HID control channel that iCUE uses for brightness, colour, and firmware communication

On macOS, the video path works natively. Touch input works (as standard mouse events). But the USB HID control channel used by iCUE for device settings has no macOS support.

## Two Control Approaches

Ledge will pursue two complementary approaches to controlling the Xeneon Edge's display settings:

### Approach 1: DDC/CI over I²C

DDC/CI (Display Data Channel Command Interface) is a VESA standard that allows a computer to send commands to a monitor over the display cable (HDMI, DisplayPort, USB-C DP Alt). It's the standard way to control brightness, contrast, volume, and other settings on external monitors.

**Advantages:**
- Well-documented standard (VESA MCCS)
- Proven macOS implementations exist (MonitorControl, Lunar, BetterDisplay)
- Works over the display connection, no separate USB HID needed
- Supports: brightness, contrast, volume, input source, colour preset, power state

**Challenges on macOS:**
- Apple doesn't officially expose DDC/CI APIs
- On Intel Macs, the approach used IOKit `IOFramebufferI2CInterface` (private-ish API)
- On Apple Silicon, the kernel changed — `IOFramebuffer` became `IOMobileFramebuffer`, and old I²C methods stopped working
- MonitorControl and BetterDisplay have found workarounds for Apple Silicon, but they involve reverse-engineered IOKit paths

**Implementation plan:**
1. Reference MonitorControl's DDC implementation (open source, Swift, MIT licence)
2. Use their `DDC.swift` module (or equivalent) to send MCCS commands
3. Support at minimum: brightness (VCP code 0x10), contrast (0x12), audio volume (0x62)
4. Test specifically with the Xeneon Edge — some monitors have quirky DDC implementations

```swift
// Conceptual DDC control interface
protocol DisplayControl {
    func getBrightness() async throws -> UInt16
    func setBrightness(_ value: UInt16) async throws
    func getContrast() async throws -> UInt16
    func setContrast(_ value: UInt16) async throws
    func getVolume() async throws -> UInt16
    func setVolume(_ value: UInt16) async throws
}
```

### Approach 2: USB HID (Corsair-Proprietary)

Corsair uses a proprietary USB HID protocol to communicate with the Xeneon Edge for features beyond standard DDC/CI. On Windows, iCUE uses this channel for:
- Colour profile management (the gist you wrote demonstrates this)
- Widget rendering commands (unknown — may render locally or send pixel data)
- Firmware version queries
- Device identification

**Current state of knowledge:**
- Corsair's USB Vendor ID is `0x1B1C` (6940 decimal)
- The Xeneon Edge exposes **two separate USB devices** (see "Discovered Device Information" section for full details):
  1. **Main device** (VID=0x1B1C/6940, PID=0x1D0D/7437): Vendor "CORSAIR", Product "XENEON EDGE" — HID control channel with vendor-specific usage page (0xFF1B/65307). This is for iCUE communication (colour profiles, firmware, etc.)
  2. **TouchScreen device** (VID=0x27C0/10176, PID=0x0859/2137): Product "TouchScreen" — the touch digitiser, a **separate controller IC** (not Corsair-branded) with 3 HID interfaces
- No public reverse engineering of the Xeneon Edge's HID protocol exists
- The user's gist demonstrates colour balance control, suggesting the HID protocol is at least partially understood
- **DDC/CI is confirmed working** on macOS — MonitorControl detects the Xeneon Edge with "Hardware (DDC)" control method, Display Identifier 2

**What the gist tells us:**
Based on the gist description ("Script to set an optimal color profile and balance on a Corsair Xeneon Edge touchscreen display on macOS without using iCue"), this confirms:
- USB HID communication with the Xeneon Edge is possible on macOS
- Colour profile/balance settings can be sent via USB HID
- This works without iCUE, so it's direct HID communication (likely using `hidapi` or IOKit HID Manager)

**Reverse engineering plan:**
1. **Identify the device**: Connect the Xeneon Edge to macOS and use `ioreg` or System Information to find the USB Product ID and interface list
2. **Capture on Windows**: When access to a Windows machine is available, use Wireshark with USBPcap to capture HID traffic between iCUE and the device while adjusting various settings
3. **Map the protocol**: Document each HID report (report ID, field offsets, value ranges) for each setting
4. **Implement on macOS**: Use IOKit HID Manager to send the same reports from macOS

**IOKit HID Manager approach (preferred for macOS native):**

```swift
import IOKit.hid

class XenonEdgeHIDController {
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?

    // Corsair Vendor ID
    private let vendorID: Int = 0x1B1C
    // Xeneon Edge TouchScreen Product ID (discovered via ioreg)
    private let touchProductID: Int = 0x0859
    // Xeneon Edge main device Product ID — needs `ioreg` with wider grep to confirm
    private let mainProductID: Int = 0x0000 // TODO: run ioreg -p IOUSB -l for full XENEON EDGE entry

    func connect() throws {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let manager else { throw HIDError.managerCreationFailed }

        let matchDict: [String: Any] = [
            kIOHIDVendorIDKey as String: vendorID,
            kIOHIDProductIDKey as String: productID
        ]

        IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw HIDError.openFailed(result) }

        // Get matched devices
        guard let deviceSet = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
              let foundDevice = deviceSet.first else {
            throw HIDError.deviceNotFound
        }
        device = foundDevice
    }

    func sendReport(_ reportID: UInt8, data: [UInt8]) throws {
        guard let device else { throw HIDError.notConnected }
        var reportData = [reportID] + data
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(reportID), &reportData, reportData.count)
        guard result == kIOReturnSuccess else { throw HIDError.sendFailed(result) }
    }
}
```

## Device Discovery

To identify the Xeneon Edge among connected displays, we need to correlate the USB HID device with the display output. This is non-trivial on macOS.

**Strategy:**
1. Enumerate `NSScreen.screens` — find the screen with 2560×720 resolution
2. Use `CGDisplayIOServicePort` (deprecated but still functional) or `IODisplayConnect` to get the IOKit service for that display
3. Query the IOKit service for vendor/product IDs
4. Match against the USB HID device with the same Corsair vendor ID
5. Fall back to user selection if automatic matching fails

```swift
func findXenonEdge() -> NSScreen? {
    return NSScreen.screens.first { screen in
        let frame = screen.frame
        // Xeneon Edge is 2560×720
        return frame.width == 2560 && frame.height == 720
    }
}
```

## Priority Order for Controls

Different display settings may be controllable via different channels. Here's the priority:

| Setting | Primary Method | Fallback |
|---------|---------------|----------|
| Brightness | DDC/CI (VCP 0x10) | USB HID (if supported) |
| Contrast | DDC/CI (VCP 0x12) | USB HID (if supported) |
| Colour Temperature | USB HID (Corsair-specific) | DDC/CI (VCP 0x14) |
| Colour Balance (R/G/B gain) | USB HID (Corsair-specific) | DDC/CI (VCP 0x16/18/1A) |
| Input Source | DDC/CI (VCP 0x60) | Not available |
| Power State | DDC/CI (VCP 0xD6) | Not available |

## Security & Permissions

### USB HID Access on macOS

macOS restricts access to HID devices. The app will need:

1. **Input Monitoring permission** (System Settings > Privacy & Security > Input Monitoring) — required for accessing HID devices
2. **Possibly "Full Disk Access"** — depending on the specific IOKit path used
3. **No sandbox** — sandboxed apps cannot access arbitrary HID devices; this is why Ledge will distribute outside the App Store initially. The App Sandbox must also be disabled for the `CGEventTap` used by `TouchRemapper`
4. **Accessibility permission** (System Settings > Privacy & Security > Accessibility) — required for the `CGEventTap` used by `TouchRemapper` to remap touchscreen coordinates to the Xeneon Edge

### Entitlements

The app's entitlements should include:
```xml
<key>com.apple.security.device.usb</key>
<true/>
```

If distributing via Developer ID (notarised), these entitlements are permitted outside the sandbox.

## Discovered Device Information

### Corsair Control Interface (iCUE Channel)

From `ioreg -r -c IOHIDDevice`:

```
Product:          "XENEON EDGE"
VendorID:         6940  (0x1B1C) — Corsair
ProductID:        7437  (0x1D0D)
PrimaryUsagePage: 65307 (0xFF1B) — Vendor-specific (Corsair iCUE)
PrimaryUsage:     1
```

This is the proprietary HID interface used by iCUE on Windows for colour profiles, firmware queries, and device settings. Not used for touch input.

### TouchScreen Device (Touch Digitiser)

The touchscreen is a **separate USB device** with a different vendor ID — it's a third-party touch controller IC, not Corsair hardware:

```
Product:   "TouchScreen"
VendorID:  10176 (0x27C0) — NOT Corsair
ProductID: 2137  (0x0859)
```

It exposes **3 HID interfaces**, each with a different usage page:

| Interface | UsagePage | Usage | Purpose |
|-----------|-----------|-------|---------|
| Digitizer | 13 (0x0D) | 4 (TouchScreen) | Raw touch digitiser reports (absolute coordinates) |
| Vendor    | 65290 (0xFEFA) | 255 | Proprietary (unknown purpose) |
| Mouse     | 1 (GenericDesktop) | 2 (Mouse) | macOS routes touch-as-mouse events through this |

### IOKit Service Tree (Touch Device)

Each HID interface has child IOService nodes. This is important because CGEvent field 87 (`mouseEventDeviceID`) reports the registry entry ID of a **descendant** service, not the IOHIDDevice itself.

Discovered tree structure (from IOKit registry walking):

```
IOHIDDevice (Mouse interface, UsagePage=1)
├── IOHIDInterface
├── AppleUserHIDEventService  ← CGEvent field 87 uses THIS node's registry ID
│   └── IOHIDEventServiceUserClient
├── IOHIDLibUserClient
└── IOHIDLibUserClient

IOHIDDevice (Digitizer interface, UsagePage=13)
├── IOHIDInterface
├── AppleUserHIDEventService
│   └── IOHIDEventServiceUserClient
├── IOHIDLibUserClient
└── IOHIDLibUserClient

IOHIDDevice (Vendor interface, UsagePage=65290)
├── IOHIDInterface
├── IOHIDLibUserClient
└── IOHIDLibUserClient
```

**Key finding:** CGEvent field 87 does NOT match the IOHIDDevice's registry entry ID. It matches the `AppleUserHIDEventService` descendant. To correlate IOKit HID devices with CGEvent device IDs, you must walk the IOKit service tree and collect all descendant registry entry IDs.

### USB Bus Info

From `ioreg -p IOUSB -l`:

```
Main device:
  USB Vendor Name = "CORSAIR"
  kUSBProductString = "XENEON EDGE"
  USB Serial Number = "145225445656"
  idVendor = 6940 (0x1B1C)
  Device Speed = 1

Child device:
  USB Product Name = "TouchScreen"
  idProduct = 2137 (0x0859)
  bDeviceClass = 0
  bcdDevice = 336
  bMaxPacketSize0 = 64
  bNumConfigurations = 1
  USBSpeed = 1
```

MonitorControl confirms: DDC hardware control works, display identified as "XENEON EDGE", Identifier 2.

## Touch Input on macOS — Investigation Notes

### The Problem

macOS maps the Xeneon Edge's USB touchscreen coordinates to the **primary display** instead of the Edge. This is a macOS limitation — USB HID digitisers with absolute coordinates get mapped to the display at the origin, regardless of which physical screen the digitiser is attached to.

### Approach 1: CGEventTap Remapping (Current — Partially Working)

Intercept mouse events via `CGEventTap`, identify those from the touchscreen device, and remap coordinates from the primary display to the Edge's position.

**Implementation:** `TouchRemapper.swift` + `HIDTouchDetector.swift`

**What works:**
- Auto-detection of the touchscreen via IOKit HID Manager (VID/PID matching)
- Walking the IOKit service tree to collect all possible CGEvent device IDs
- Identifying touchscreen events in the CGEventTap callback
- Coordinate remapping from primary display CG coordinates to Edge CG coordinates
- Initial touch events (mouseDown mapped to primary) get correctly remapped to Edge

**What doesn't fully work:**
- After a remapped mouseDown moves the cursor to the Edge, macOS adjusts its internal absolute coordinate mapping. Subsequent drag/up events arrive with coordinates already on the Edge rather than on the primary. This creates an inconsistency: the first event needs remapping, but follow-up events from the same gesture don't.
- The workaround (pass through events already on the Edge) works for simple taps but may cause issues with gestures, drags, and multi-touch patterns.

**Coordinate system gotchas discovered:**
- `NSScreen.frame` uses Cocoa coordinates (Y axis up, origin at bottom-left of primary)
- `CGEvent.location` uses CG/Quartz coordinates (Y axis down, origin at top-left of primary)
- Primary display frames match in both systems; secondary displays do NOT
- Conversion: `cgY = primaryHeight - cocoaY - screenHeight`

**Device ID gotchas discovered:**
- CGEvent field 87 (`mouseEventDeviceID`) uses raw value 87 — not bridged to Swift's `CGEventField` enum
- The field reports the IOKit registry entry ID of an IOService descendant (specifically `AppleUserHIDEventService`), NOT the `IOHIDDevice` node itself
- The touchscreen's 3 HID interfaces each have different registry entry IDs, and their descendants have yet more IDs — must collect the full set and match against any of them
- Registry entry IDs change on device reconnect (they're assigned sequentially by the kernel)

### Approach 2: IOKit HID Direct Input (Not Yet Attempted)

Read raw touch digitiser reports directly via IOKit HID Manager, bypassing macOS's broken coordinate mapping entirely. Post synthetic CGEvents at the correct screen position.

**Concept:**
1. Open the Digitizer interface (UsagePage=0x0D) via `IOHIDManagerOpen`
2. Register input value callbacks for X, Y, and Tip Switch elements
3. Read absolute coordinates (logical min/max from the HID descriptor)
4. Normalise to [0,1] and map to Edge's screen position
5. Post synthetic `CGEvent` at the correct location
6. Optionally seize the device (`kIOHIDOptionsTypeSeizeDevice`) to prevent macOS from generating its own (wrong) mouse events — requires Input Monitoring permission

**Advantages:**
- Completely bypasses macOS's broken mapping
- No coordinate system confusion — we control the entire pipeline
- No "post-remap feedback loop" issue

**Disadvantages:**
- Requires Input Monitoring permission (in addition to Accessibility)
- Seizing the device is risky — if the app crashes, the touchscreen is unresponsive until reconnect
- Must parse HID report descriptors to find the correct elements
- Must handle all touch state (down, move, up) manually

### Approach 3: Hybrid (Recommended Next Step)

Keep the CGEventTap but improve the coordinate handling:
- Use IOKit HID auto-detection (already working) to identify the device
- Track touch state (down vs. drag/up) to know when to remap vs. pass through
- Only remap the initial mouseDown; pass through all subsequent events for that gesture
- Reset on mouseUp so the next gesture gets remapped fresh

## Next Steps

1. **~~Connect the Xeneon Edge to a Mac~~** — DONE. Full device tree discovered (see above), including the Corsair control interface (VID=0x1B1C, PID=0x1D0D) and the touchscreen controller (VID=0x27C0, PID=0x0859) with all 3 HID interfaces documented.

2. **~~Test DDC/CI~~** — DONE. MonitorControl confirms Hardware (DDC) works with the Xeneon Edge.

3. **~~Investigate touch remapping via CGEventTap~~** — DONE (partially working). Auto-detection via IOKit works; coordinate remapping has a post-remap feedback loop issue. See "Touch Input on macOS" section for full findings.

4. **Improve touch input handling**: Either refine the CGEventTap approach (track gesture state, only remap initial mouseDown) or implement direct IOKit HID digitiser reading. See Approach 2 and 3 in the touch investigation notes.

5. **Capture USB HID on Windows**: Use Wireshark + USBPcap while adjusting settings in iCUE. Focus on brightness, colour balance, and any widget-related communication.

6. **Integrate the gist**: Adapt the colour control code from the existing gist into the Ledge architecture.
