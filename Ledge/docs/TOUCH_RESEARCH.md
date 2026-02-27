# Touch Input Research — Deep Dive

## Executive Summary

This document consolidates all research into intercepting and remapping the Xeneon Edge's USB touchscreen input on macOS. It includes: reverse-engineered touch protocol from Windows USB captures, analysis of every viable macOS interception approach, and a recommended implementation strategy.

**Bottom line:** The best approach is a **hybrid** — use IOKit HID Manager to read raw digitizer reports (giving us multi-touch and bypassing macOS's broken mapping), combined with CGEventTap to suppress the wrongly-mapped mouse events macOS generates, then post synthetic CGEvents at the correct screen position.

---

## Part 1: Touch Protocol (from Windows USB Captures)

### Device Configuration

The touchscreen is a third-party controller IC (NOT Corsair), exposed as a separate USB device:

| Property | Value |
|----------|-------|
| Vendor ID | 0x27C0 (10176) |
| Product ID | 0x0859 (2137) |
| USB Speed | Full Speed (USB 1.1, 12 Mbit/s) |
| Max Packet Size | 64 bytes |
| Configuration | 3 interfaces |

USB Configuration Descriptor (from pcap):
```
Interface 0: HID Digitizer (touch reports)
  - 1 endpoint: 0x81 (IN, INTERRUPT)
  - HID Report Descriptor: 704 bytes
  - Interval: 1ms

Interface 1: HID Vendor-specific
  - 2 endpoints: 0x82 (IN), 0x02 (OUT)
  - HID Report Descriptor: 38 bytes
  - Interval: 1ms

Interface 2: HID (unknown — likely mouse emulation)
  - 1 endpoint: 0x83 (IN, INTERRUPT)
  - HID Report Descriptor: 80 bytes
  - Interval: 1ms
```

### Touch Report Format

Reports arrive on **Endpoint 0x81** as INTERRUPT IN transfers, **54 bytes** each:

```
Byte  0:     Report ID (always 0x0D)
Byte  1:     State byte
              High nibble: contact count (1-5)
              Low nibble:  1 = finger(s) down, 0 = finger(s) up (last frame)
Bytes 2-3:   Contact 0 X (uint16, little-endian)
Bytes 4-5:   Contact 0 Y (uint16, little-endian)
Byte  6:     Contact 0 ID/state (0x00 for single, 0x11 when multi-touch)
Bytes 7-8:   Contact 1 X (uint16, little-endian) [if contact count >= 2]
Bytes 9-10:  Contact 1 Y (uint16, little-endian) [if contact count >= 2]
...          (pattern repeats for contacts 2-4)
Bytes 51-53: Trailer (always 0x01 0x01 0x01, then contact count in last byte)
```

### Coordinate System

- Raw range: **0–65535** for both X and Y (standard 16-bit HID digitizer absolute coordinates)
- Maps to **2560×720** display pixels
- Scaling: `displayX = rawX * 2560 / 65535`, `displayY = rawY * 720 / 65535`
- X increases left-to-right, Y increases top-to-bottom

### Observed Data

**Single finger tap (Steam icon):**
- 17 frames, all at (6850, 2256) → display position (268px, 25px)
- Last frame has flags=0x0 (finger up), all previous flags=0x1

**Single finger swipe left→right:**
- 37 frames, X increasing: 6127→11972 → display 239px→468px
- Y relatively stable (5047–5581 → 55–61px)
- Last frame repeats previous position with flags=0x0

**Two-finger swipe:**
- Up to 81 frames with 2 simultaneous contacts
- Both contacts track independently with smooth coordinate progression
- Finger-up sequence: cnt=2 fl=0 → cnt=1 fl=1 → cnt=1 fl=0 (contacts lift sequentially)

### Key Protocol Findings

1. **Reports are event-driven** — sent continuously while finger(s) are down, idle when no contact
2. **Multi-touch supports up to 5 contacts** (54 bytes / ~10 bytes per contact + 4-byte header + 3-byte trailer)
3. **No explicit contact ID tracking** — position 0 always holds the first finger, position 1 the second, etc.
4. **Finger-up is indicated by flags**, not by coordinate change
5. **The 704-byte HID report descriptor** for Interface 0 should be captured to confirm the exact field layout (we're inferring from observed data)

---

## Part 2: Colour Control Protocol (from Windows USB Captures)

### Device

Corsair main device: VID=0x1B1C, PID=0x1D0D

### Command Format (64 bytes)

```
Byte 0:     Report ID (0x01)
Byte 1:     Command type (0x0F = colour control)
Bytes 2-6:  Padding (zeros)
Byte 7:     Colour channel: 0x01=Red, 0x02=Green, 0x03=Blue
Byte 8:     Intensity (0x00–0xFF)
Bytes 9-63: Padding (zeros)
```

Sent on Endpoint 0x01 (INTERRUPT OUT). Device acknowledges on Endpoint 0x82 (INTERRUPT IN) with an echo of the command.

Each colour channel is set independently with a separate command.

---

## Part 3: macOS Interception Approaches

### Approach 1: CGEventTap Only (Current Implementation)

**How it works:** Intercept mouse events after macOS has already generated them from the HID reports. Identify touchscreen events by device ID (field 87). Remap coordinates from primary display to Xeneon Edge.

**Pros:**
- Already implemented and mostly working
- Only needs Accessibility permission
- Safe — if app crashes, no devices are left in a bad state
- Open-source friendly (no Apple review)

**Cons:**
- Can only remap, not suppress — returning NULL from the callback doesn't always prevent the cursor from briefly appearing on the wrong screen
- No multi-touch — macOS has already flattened touch to single mouse events by this point
- Post-remap feedback loop: after remapping mouseDown, subsequent drag/up events may arrive with coordinates already on the Edge
- Only sees the events macOS decides to generate (mouse interface, not digitizer)

**Verdict:** Good enough for basic single-touch, but inherently limited.

### Approach 2: IOKit HID Manager with kIOHIDOptionsTypeSeizeDevice

**How it works:** Open the touchscreen's HID device with exclusive access. Read raw HID reports directly. Prevent macOS from processing them.

**Critical findings:**
- `kIOHIDOptionsTypeSeizeDevice` prevents OTHER APPS from reading the device, but **macOS's own HID stack still processes it and generates mouse events**
- Requires root for keyboard-class devices; touchscreens (mouse-class) may work without root
- If the app crashes while seized, the device remains seized until process termination
- On modern macOS, seize doesn't reliably hide devices from `IOHIDManagerCopyDevices`

**Verdict:** ❌ Not reliable for preventing OS mouse event generation.

### Approach 3: DriverKit / DEXT (Driver Extension)

**How it works:** Create a System Extension that intercepts the touchscreen at the driver level, before macOS generates mouse events.

**Findings:**
- Would work perfectly — full control over HID processing
- Requires Apple notarization and ~3-week review cycle per update
- Users must manually approve system extensions
- Not feasible for open-source development

**Verdict:** ❌ Impractical for this project.

### Approach 4: IOHIDEventSystemClient (Private API)

**Findings:** Hard-coded check for `com.apple.springboard` bundle ID. Cannot be used by third-party apps.

**Verdict:** ❌ Impossible.

### Approach 5: Hybrid — IOKit HID + CGEventTap Suppression (RECOMMENDED)

**How it works:**
1. **IOKit HID Manager** reads raw digitizer reports from Interface 0 (Endpoint 0x81) — this gives us multi-touch data directly from the USB device
2. **CGEventTap** intercepts the mouse events macOS generates from the same device and **returns NULL to suppress them** (preventing cursor movement on primary display)
3. **Synthetic CGEvents** are posted at the correct Xeneon Edge screen position based on the raw digitizer coordinates

**Why this is best:**
- CGEventTap suppression (return NULL) works at `headInsertEventTap` — the event is consumed before anything else processes it
- IOKit HID gives us the raw 54-byte digitizer reports with multi-touch support
- No device seizure needed — we read alongside macOS, then suppress the generated events
- If the IOKit reading fails, the CGEventTap still works as a (degraded) remapper
- Same permission requirements as current approach (Accessibility)
- Safe crash behaviour — no seized devices

**Implementation outline:**

```swift
class HIDTouchReader {
    private var manager: IOHIDManager?
    var onTouchReport: (([TouchContact]) -> Void)?

    func start() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, 0)

        // Match the Digitizer interface specifically
        let criteria: [String: Any] = [
            kIOHIDVendorIDKey as String: 0x27C0,
            kIOHIDProductIDKey as String: 0x0859,
            kIOHIDPrimaryUsagePageKey as String: 0x0D,  // Digitizer
            kIOHIDPrimaryUsageKey as String: 4,          // TouchScreen
        ]

        IOHIDManagerSetDeviceMatching(manager!, criteria as CFDictionary)
        IOHIDManagerRegisterInputReportCallback(manager!, { context, result, sender, type, reportID, report, reportLength in
            // Parse 54-byte touch report
            guard reportLength == 54, report[0] == 0x0D else { return }

            let contactCount = Int((report[1] >> 4) & 0x0F)
            let fingerDown = (report[1] & 0x0F) == 1
            var contacts: [TouchContact] = []

            for i in 0..<contactCount {
                let base = 2 + (i * 5)  // approximate — needs exact offset from descriptor
                let x = UInt16(report[base]) | (UInt16(report[base+1]) << 8)
                let y = UInt16(report[base+2]) | (UInt16(report[base+3]) << 8)
                contacts.append(TouchContact(x: x, y: y, isDown: fingerDown))
            }

            // Notify listener
            let reader = Unmanaged<HIDTouchReader>.fromOpaque(context!).takeUnretainedValue()
            reader.onTouchReport?(contacts)
        }, Unmanaged.passUnretained(self).toOpaque())

        IOHIDManagerScheduleWithRunLoop(manager!, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(manager!, 0)  // Non-exclusive — macOS still processes it
    }
}
```

Then in the CGEventTap callback:
```swift
// If event is from the touchscreen → return nil (suppress it)
// The HIDTouchReader has already captured the raw data
// Post a synthetic event at the correct Xeneon Edge position instead
if touchDeviceIDs.contains(deviceID) {
    return nil  // Suppress — prevents cursor from moving on primary display
}
return Unmanaged.passUnretained(event)  // Pass through non-touch events
```

---

## Part 4: Remaining Questions

### Must-capture on macOS

To fully validate the hybrid approach, we need the HID Report Descriptor from the touchscreen's Digitizer interface. This 704-byte descriptor defines the exact field layout (bit positions for X, Y, Tip Switch, Contact ID, Contact Count, etc.).

**How to capture:**
```bash
# Option 1: IOKit dump
ioreg -r -c IOHIDDevice -l | grep -A 100 "0x27c0"

# Option 2: HID descriptor tool
# Install: brew install hidapi
# Then use a Python script with hidapi to read the descriptor
```

Alternatively, since the Windows pcap includes a GET_DESCRIPTOR request for the HID report descriptor (Block 17 in the Calibration capture), we may be able to extract it from there — the 704-byte descriptor was requested but the capture only shows the first 91 bytes of the config descriptor response. A longer capture or explicit GET_REPORT_DESCRIPTOR request would be needed.

### Coordinate layout refinement

Our byte-level analysis of the 54-byte reports is based on observed data patterns. The exact per-contact byte layout (especially bytes 6+ for multi-touch contacts 2-4) needs validation against the HID report descriptor. The current model:

```
[0]    Report ID (0x0D)
[1]    State: high nibble=count, low nibble=down/up
[2-3]  Contact 0 X (uint16 LE)
[4-5]  Contact 0 Y (uint16 LE)
[6]    Contact 0 flags/ID
[7-8]  Contact 1 X
[9-10] Contact 1 Y
...
```

This needs to be confirmed — the gaps between contacts might not be exactly 5 bytes. Standard HID digitizer reports typically use: Tip Switch (1 bit) + Contact ID (8 bits) + X (16 bits) + Y (16 bits) = 5 bytes per contact, but padding and additional fields (pressure, width/height) could change this.

---

## Part 5: Implementation Roadmap

### Phase A: Validate CGEventTap Suppression (Quick Win)

Modify the existing `TouchRemapper.processEvent()` to return `nil` (instead of the remapped event) for touchscreen events, and instead post a synthetic CGEvent at the remapped coordinates. This tests whether suppression actually prevents cursor movement on the primary display.

**Expected outcome:** Touch the Edge → cursor does NOT move on primary, synthetic event hits the Edge panel.

### Phase B: Add IOKit HID Raw Report Reading

Create `HIDTouchReader` class that opens the Digitizer interface (Interface 0, UsagePage=0x0D) and reads 54-byte reports. Parse contact count, coordinates, and down/up state. Feed this to the TouchRemapper to post synthetic events.

**Expected outcome:** Multi-touch awareness, no dependency on macOS's broken mapping.

### Phase C: Capture and Parse HID Report Descriptor

On macOS, read the 704-byte HID Report Descriptor for the Digitizer interface. Parse it to confirm the exact field layout for all 5 contact slots. Update the report parser accordingly.

### Phase D: Gesture Recognition

With multi-touch data from Phase B, implement gesture recognition: tap, long press, swipe, two-finger scroll, pinch-to-zoom. Feed gestures to the widget system.

---

## References

- [CGEvent.tapCreate documentation](https://developer.apple.com/documentation/coregraphics/cgevent/1454426-tapcreate)
- [IOHIDManager documentation](https://developer.apple.com/documentation/iokit/iohidmanager_h)
- [Karabiner-Elements](https://karabiner-elements.pqrs.org/) — open-source CGEventTap usage
- [Touch-Base / UPDD](http://touch-base.com/) — commercial macOS touchscreen driver (proprietary)
- [Linux xinput map-to-output](https://wiki.archlinux.org/title/Calibrating_Touchscreen) — how Linux solves this (coordinate transformation matrix)
- [hidapi library](https://github.com/libusb/hidapi) — cross-platform HID access
