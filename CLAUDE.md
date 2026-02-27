# Ledge — Claude Code Context

## What Is This?

Ledge is a native macOS widget dashboard for the **Corsair Xeneon Edge** — a 14.5" ultrawide touchscreen (2560x720, 60Hz, 5-point multi-touch) intended as a companion display. Corsair only provides Windows iCUE software, so macOS gets no widget system, no brightness control, and broken touch mapping. Ledge fills that gap.

## Core Architectural Decisions

### NSPanel with `.nonactivatingPanel` (The Foundation)
The entire project hinges on `NSPanel` with `.nonactivatingPanel` style mask so widgets receive touch/mouse input without stealing focus from the user's foreground app. This MUST be set at `super.init()` time due to an AppKit bug — setting it later silently breaks event routing.

### TouchRemapper (CGEventTap)
macOS incorrectly maps USB touchscreen coordinates to the **primary display** instead of the Xeneon Edge. `TouchRemapper` intercepts mouse events via `CGEventTap`, identifies the touchscreen by HID device ID (learned on first touch), and remaps coordinates to the Xeneon Edge's global display position. Requires Accessibility permissions and disabled App Sandbox.

### SwiftUI + AppKit Bridge
SwiftUI for widget rendering and settings UI. AppKit for `NSPanel` management and display detection. `NSHostingView` bridges the two. The app uses SwiftUI App lifecycle with `@NSApplicationDelegateAdaptor`.

## Project Structure

```
Ledge/
├── Sources/
│   ├── App/
│   │   ├── LedgeApp.swift          # @main entry, SwiftUI App lifecycle
│   │   ├── AppDelegate.swift       # NSApplicationDelegate, panel/touch lifecycle
│   │   └── DashboardView.swift     # Root view on Xeneon Edge + TouchTestView
│   ├── Display/
│   │   ├── LedgePanel.swift        # NSPanel subclass (.nonactivatingPanel)
│   │   ├── DisplayManager.swift    # Xeneon Edge detection, panel lifecycle, @MainActor
│   │   └── TouchRemapper.swift     # CGEventTap coordinate remapping
│   ├── Layout/
│   │   └── LayoutModels.swift      # WidgetLayout, WidgetPlacement (Codable)
│   ├── Widgets/
│   │   ├── Protocol/
│   │   │   └── LedgeWidget.swift   # WidgetDescriptor, WidgetContext, GridSize
│   │   ├── Runtime/
│   │   │   └── WidgetRegistry.swift # Singleton, registers/creates widget views
│   │   └── BuiltIn/
│   │       └── ClockWidget/
│   │           └── ClockWidget.swift # First built-in widget
│   ├── Settings/
│   │   └── SettingsView.swift      # Settings UI on primary display
│   ├── Hardware/                   # Stubs (Phase 2+)
│   └── DataProviders/              # Stubs (Phase 1+)
├── Assets.xcassets/
└── Ledge.xcodeproj/
```

## Key Technical Facts

- **Target**: macOS 14+ (Sonoma), Swift 5.9+
- **Xeneon Edge resolution**: 2560x720 (32:9 aspect)
- **Display detection**: Matches by resolution (2560x720) or name ("XENEON EDGE")
- **Touch arrives as**: Standard mouse events (`leftMouseDown`, etc.), NOT `NSTouch` events
- **Multi-touch**: Not available — macOS treats USB touchscreen as single-point mouse
- **Corsair USB Vendor ID**: `0x1B1C`, Touchscreen Product ID: `0x0859`
- **App Sandbox**: DISABLED (`ENABLE_APP_SANDBOX = NO`) — required for CGEventTap and USB HID
- **Permissions needed**: Accessibility (for CGEventTap), Input Monitoring (for USB HID, Phase 2+)
- **Persistence path**: `~/Library/Application Support/Ledge/` (JSON files)

## LedgePanel Critical Rules

1. `.nonactivatingPanel` MUST be in the `styleMask` at `super.init()` time — never set later
2. `canBecomeKey = true` (accepts input), `canBecomeMain = false` (doesn't steal focus)
3. `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`
4. `mouseDown(with:)` must call `super.mouseDown(with:)` — do NOT manually forward events to `contentView`, that breaks SwiftUI's responder chain and gesture recognisers
5. `hidesOnDeactivate = false` — panel must stay visible when the app isn't active

## Touch Pipeline Flow

The touch pipeline is managed by `DisplayManager` and has automatic permission handling:

1. **Permission**: On launch, `startTouchRemapper()` checks Accessibility permission. If not granted, it requests via `AXIsProcessTrustedWithOptions` and polls every 2s + on app activation until granted.
2. **Event Tap**: Once permission is confirmed, `proceedWithTouchRemapper()` creates the `CGEventTap` at session level intercepting mouse down/up/dragged/moved.
3. **Calibration**: Automatically enters learning mode — the first touch captures the touchscreen's HID device ID via `.mouseEventDeviceID`.
4. **Remapping**: Subsequent events from that device: normalise coordinates against primary display (0-1), remap to Xeneon Edge frame. Events from other devices pass through unmodified.
5. **Debug**: `onEventProcessed` callback feeds last-touch info to the dashboard's `TouchDebugOverlay`.

### State model (on DisplayManager)
- `accessibilityPermission`: `.unknown` / `.waiting` / `.granted`
- `isTouchRemapperActive`: whether the CGEventTap is running
- `calibrationState`: `.notStarted` / `.learning` / `.calibrated`
- `learnedDeviceID`: the touchscreen's HID device ID (once calibrated)
- `lastTouchInfo`: coordinates of the most recent touch event (for debug)
- `touchStatus`: computed string derived from the above (used by Settings UI)

## Widget System

- `WidgetDescriptor` pattern avoids Swift associated type complications
- `viewFactory: () -> AnyView` closure creates widget views on demand
- `WidgetRegistry.shared` singleton holds all registered types
- `WidgetContext` (per-instance, `@MainActor`) provides platform services to widgets
- Default layout: 6x2 grid (each cell ~426x360 points)

## Development Phases

- **Phase 0 (current)**: Foundation — panel, display detection, touch remapping, clock widget, settings UI
- **Phase 1**: Layout engine, grid rendering, CPU/GPU/Memory/Now Playing widgets
- **Phase 2**: DDC/CI brightness control, USB HID Corsair-specific controls
- **Phase 3**: Polish, extended widgets (weather, volume, shortcuts), themes
- **Phase 4**: USB protocol reverse engineering (Wireshark captures)
- **Phase 5**: Plugin system (`.ledgewidget` bundles)
- **Phase 6**: Open source, community ecosystem

## Current Status & Known Issues

### Working
- NSPanel renders fullscreen on Xeneon Edge
- Display detection (resolution + name matching)
- Display connect/disconnect observation
- Clock widget rendering
- Settings UI with display info and touch controls
- TouchRemapper scaffolding (CGEventTap creation, coordinate remapping logic)

### In Progress / Blocked
- Touch remapping end-to-end validation — permission polling and auto-calibration flow implemented, needs testing with actual Xeneon Edge touch
- Non-focus-stealing behaviour verification with touch (works with mouse, untested with remapped touch)
- App Sandbox must be disabled in the Xcode project (`ENABLE_APP_SANDBOX = NO`)

### Not Yet Implemented
- Grid layout engine and renderer
- System data providers (CPU, GPU, Memory, Network)
- Actual widget grid placement on the dashboard
- DDC/CI and USB HID hardware control
- Plugin loading system

## Documentation

Detailed design docs in `Ledge/docs/`:
- `OVERVIEW.md` — Problem, goals, hardware specs, research links
- `ARCHITECTURE.md` — Layered design, component responsibilities, tech choices
- `FOCUS_MANAGEMENT.md` — NSPanel, touch remapping, edge cases (text input, context menus)
- `WIDGET_SYSTEM.md` — Widget protocol, built-in catalogue, plugin format, touch patterns
- `USB_PROTOCOL.md` — DDC/CI, USB HID, device discovery, captured device info
- `ROADMAP.md` — Phased plan with checkboxes, known risks, quick wins
- `XCODE_SETUP.md` — Step-by-step project creation and troubleshooting

## Build & Run

1. Open `Ledge/Ledge.xcodeproj` in Xcode
2. Ensure App Sandbox is disabled (Signing & Capabilities)
3. Connect Xeneon Edge, press Cmd+R
4. Grant Accessibility permissions when prompted
5. Settings window appears on primary display, widget panel on Xeneon Edge
6. Touch the Xeneon Edge to calibrate (identifies touchscreen device ID)

## Conventions

- Use `os.log` Logger with subsystem `"com.ledge.app"` and per-component categories
- `@MainActor` for all UI-touching classes (DisplayManager, WidgetContext)
- Widget type IDs use reverse-DNS: `"com.ledge.clock"`, `"com.ledge.cpu"`, etc.
- Prefer SwiftUI gesture recognisers over manual event handling
- Keep widget configuration settings on the primary display, not the Xeneon Edge
- Avoid `NSAlert`, `NSMenu`, or any system UI that would activate the app — use custom SwiftUI views instead
