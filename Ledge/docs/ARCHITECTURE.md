# Architecture

## High-Level Architecture

Ledge is structured as a layered native macOS application. Each layer has a clear responsibility and communicates through well-defined interfaces.

```
┌─────────────────────────────────────────────────┐
│                   User Interface                 │
│  ┌───────────┐ ┌───────────┐ ┌───────────────┐  │
│  │  Widget    │ │  Layout   │ │  Settings /   │  │
│  │  Renderer  │ │  Engine   │ │  Config UI    │  │
│  └───────────┘ └───────────┘ └───────────────┘  │
├─────────────────────────────────────────────────┤
│                  Widget Runtime                  │
│  ┌───────────┐ ┌───────────┐ ┌───────────────┐  │
│  │  Plugin    │ │  Widget   │ │  Sandbox /    │  │
│  │  Loader    │ │  Lifecycle│ │  Permissions  │  │
│  └───────────┘ └───────────┘ └───────────────┘  │
├─────────────────────────────────────────────────┤
│                 Platform Services                │
│  ┌───────────┐ ┌───────────┐ ┌───────────────┐  │
│  │  Display   │ │  Touch    │ │  System Data  │  │
│  │  Manager   │ │  Input    │ │  Providers    │  │
│  └───────────┘ └───────────┘ └───────────────┘  │
├─────────────────────────────────────────────────┤
│                 Hardware Layer                    │
│  ┌───────────┐ ┌───────────┐ ┌───────────────┐  │
│  │  USB HID   │ │  DDC/CI   │ │  Display      │  │
│  │  Control   │ │  Control  │ │  Detection    │  │
│  └───────────┘ └───────────┘ └───────────────┘  │
└─────────────────────────────────────────────────┘
```

## Core Components

### 1. Display Manager

Responsible for identifying the Xeneon Edge among connected displays and managing the full-screen non-activating panel on that screen.

**Key responsibilities:**
- Enumerate `NSScreen.screens` to find the Xeneon Edge (by resolution 2560×720, display name, or vendor/product ID via IOKit)
- Create and manage the `NSPanel` with `.nonactivatingPanel` style mask
- Handle display connect/disconnect events (via `CGDisplayRegisterReconfigurationCallback` or `NSScreen` notifications)
- Manage orientation changes (landscape/portrait)

**Critical implementation detail:** The `.nonactivatingPanel` style mask must be set at `NSPanel` initialisation time. Setting it later causes a known AppKit bug where the window appears key but doesn't properly receive events. See the [NSPanel nonactivating bug](https://philz.blog/nspanel-nonactivating-style-mask-flag/) for details.

```swift
// Conceptual — the core panel setup
class LedgePanel: NSPanel {
    init(on screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isOpaque = true
        self.hasShadow = false
        self.acceptsMouseMovedEvents = true
        self.isMovableByWindowBackground = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
```

### 2. Layout Engine

Manages the spatial arrangement of widgets on the display. Inspired by iCUE's grid system but more flexible.

**Key responsibilities:**
- Define a grid system appropriate for 2560×720 (e.g., 12-column by 4-row grid)
- Allow widgets to span multiple grid cells
- Persist layout configurations to disk (JSON or plist)
- Support multiple saved layouts that users can switch between
- Handle layout editing mode (drag-to-resize, drag-to-reposition)

**Layout model:**
```swift
struct WidgetLayout: Codable {
    let id: UUID
    var name: String
    var widgets: [WidgetPlacement]
}

struct WidgetPlacement: Codable {
    let widgetID: String        // References a registered widget type
    var column: Int             // Grid column (0-based)
    var row: Int                // Grid row (0-based)
    var columnSpan: Int         // How many columns wide
    var rowSpan: Int            // How many rows tall
    var configuration: Data?    // Widget-specific config (JSON)
}
```

The 2560×720 aspect ratio is roughly 32:9, which is extremely wide and not very tall. A 12×3 or 8×2 grid probably makes the most sense. Users should be able to choose grid density.

### 3. Widget Runtime

The plugin system that loads, manages, and renders widgets.

**See [WIDGET_SYSTEM.md](./WIDGET_SYSTEM.md) for full details.**

At a high level:
- Widgets are Swift packages or bundles conforming to a `LedgeWidget` protocol
- Each widget gets a `SwiftUI.View`-sized region to render into
- Widgets declare their data requirements (system stats, network, media, etc.)
- The runtime manages widget lifecycle (load, configure, update, unload)

### 4. Touch Input Manager

Handles touchscreen input from the Xeneon Edge. This turned out to be significantly more complex than originally anticipated due to a macOS limitation.

**The core problem:** macOS does not associate USB touchscreens with specific displays. The Xeneon Edge touchscreen (USB PID `0x0859`) reports absolute coordinates, but macOS maps them to the primary display — not the Xeneon Edge. Touching the Xeneon Edge moves the cursor on the primary monitor.

**Solution — TouchRemapper (`CGEventTap`):**

Ledge uses a `CGEventTap` to intercept mouse events from the touchscreen and remap their coordinates to the Xeneon Edge's position in the global display space. See `Sources/Display/TouchRemapper.swift`.

The flow:
1. On launch, start the `TouchRemapper` targeting the detected Xeneon Edge screen
2. Enter calibration mode — the first touch event captures the touchscreen's HID device ID
3. Subsequent events from that device ID have their coordinates normalised (0.0–1.0 against primary display) and remapped to the Xeneon Edge
4. Events from other devices (mouse, trackpad) pass through unmodified

**Requirements:**
- Accessibility permissions (`AXIsProcessTrusted`)
- App Sandbox disabled (`ENABLE_APP_SANDBOX = NO`)

**Key responsibilities (once remapping is in place):**
- Receive mouse events via the `NSPanel` (which handles this naturally as a non-activating panel)
- Route events to the correct widget based on layout position via SwiftUI's hit-testing
- Support gestures: tap, long press, swipe (via SwiftUI gesture recognisers)
- Distinguish between widget interaction and layout editing gestures
- Provide visual feedback (since the Xeneon Edge has no haptic motor)

**Important findings from testing:**
- Touch events arrive as standard mouse events (`leftMouseDown`, `leftMouseUp`, etc.) — NOT as `NSEvent.directTouch` or `NSTouch` events
- Multi-touch is not available — macOS treats the touchscreen as a single-point mouse
- The `NSPanel`'s `mouseDown(with:)` must call `super.mouseDown(with:)` to preserve SwiftUI's responder chain and gesture recognisers — manually forwarding events to `contentView` breaks SwiftUI gesture handling

### 5. USB HID Control

Direct communication with the Xeneon Edge hardware over USB for device-specific controls.

**See [USB_PROTOCOL.md](./USB_PROTOCOL.md) for full details.**

This layer handles:
- Brightness control
- Contrast control
- Colour temperature / colour balance
- Potentially: firmware info queries, input source switching

Two approaches will be pursued in parallel:
1. **DDC/CI over I²C** (via IOKit, like MonitorControl) — for standard VESA monitor controls
2. **USB HID** (via IOKit HID Manager or HIDAPI) — for Corsair-proprietary controls

### 6. System Data Providers

A set of services that collect system information for widgets to consume.

**Providers:**
- **CPU/GPU**: Temperature, load, frequency (via IOKit SMC keys)
- **Memory**: Usage, pressure
- **Disk**: Usage, I/O rates
- **Network**: Upload/download speeds, interface info
- **Audio**: Current output device, volume, now-playing media info
- **Battery**: Charge level, charging state (if laptop)
- **Time**: Current time, timers, alarms

Each provider runs on a background thread/actor and publishes updates via Combine publishers or Swift async streams. Widgets subscribe to the data they need; providers only activate when at least one widget requires their data.

```swift
protocol SystemDataProvider {
    associatedtype DataType: Sendable
    var updateInterval: TimeInterval { get }
    func start() async
    func stop() async
    var dataStream: AsyncStream<DataType> { get }
}
```

## Technology Choices

| Component | Technology | Rationale |
|-----------|-----------|-----------|
| UI Framework | SwiftUI + AppKit bridge | SwiftUI for widget rendering; AppKit for NSPanel and display management |
| Language | Swift 5.9+ | Native, performant, modern concurrency |
| Concurrency | Swift Concurrency (async/await, actors) | Structured concurrency for data providers and USB I/O |
| USB HID | IOKit HID Manager (primary), HIDAPI (fallback) | IOKit is native; HIDAPI is cross-platform fallback |
| DDC/CI | IOKit I²C (referencing MonitorControl approach) | Proven approach for macOS DDC control |
| Persistence | JSON files in ~/Library/Application Support/Ledge/ | Simple, human-readable, version-controllable |
| Build System | Xcode / Swift Package Manager | Standard macOS toolchain |
| Minimum Target | macOS 14 (Sonoma) | Modern SwiftUI features, WidgetKit improvements |

## Process Architecture

Ledge runs as a single-process macOS application (not a menubar-only app). It has:

- **Main thread**: UI rendering (SwiftUI/AppKit), event handling
- **Background actors**: System data collection, USB HID polling
- **Widget sandboxing**: Initially in-process (same address space), with potential for out-of-process isolation in future via XPC Services

The app will appear in the Dock (it manages a visible window on the Xeneon Edge) but the settings/configuration UI will be on the primary display, not on the Xeneon Edge itself.

```
┌──────────────────────┐    ┌──────────────────────┐
│   Primary Display    │    │    Xeneon Edge        │
│                      │    │                       │
│  ┌────────────────┐  │    │  ┌─────────────────┐  │
│  │  Settings UI   │  │    │  │  Widget Panel   │  │
│  │  (normal       │  │    │  │  (NSPanel,      │  │
│  │   window)      │  │    │  │   nonactivating │  │
│  │                │  │    │  │   fullscreen)   │  │
│  └────────────────┘  │    │  └─────────────────┘  │
│                      │    │                       │
└──────────────────────┘    └──────────────────────┘
```

## Configuration & Settings

Configuration lives in `~/Library/Application Support/Ledge/`:

```
~/Library/Application Support/Ledge/
├── config.json              # Global app config
├── layouts/
│   ├── default.json         # Default widget layout
│   └── gaming.json          # User-created layout
├── widgets/
│   └── <widget-id>/
│       └── config.json      # Per-widget configuration
└── plugins/                 # Third-party widget bundles
    └── MyCustomWidget.ledgewidget
```

## Error Handling Strategy

- **Display not found**: Show a settings window on the primary display explaining the Xeneon Edge wasn't detected, with a "Retry" button. Allow manual display selection.
- **Touch remapping requires Accessibility**: On first launch, prompt the user to grant Accessibility permissions (System Settings > Privacy & Security > Accessibility). Without this, the CGEventTap cannot be created and touch will not work on the Xeneon Edge. The app uses `AXIsProcessTrustedWithOptions` to trigger the system prompt.
- **USB HID access denied**: Prompt user to grant Input Monitoring or relevant permissions in System Settings > Privacy & Security.
- **Widget crash**: Catch widget rendering errors gracefully; show an error placeholder in the widget's grid cell. Log the error. Do not crash the host app.
- **DDC/CI failure**: Fall back to software-only brightness overlay. Log the issue. Some displays/connections don't support DDC.
