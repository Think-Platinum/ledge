# Xcode Project Setup

The Swift source files are scaffolded in `Ledge/Sources/`. You'll need to create the Xcode project to compile and run them.

## Step-by-Step

### 1. Create the Xcode Project

1. Open Xcode
2. File → New → Project
3. Choose **macOS → App**
4. Configure:
   - **Product Name**: `Ledge`
   - **Team**: Your developer team (or "None" for local dev)
   - **Organization Identifier**: `com.ledge` (or your preference)
   - **Interface**: SwiftUI
   - **Language**: Swift
5. Save it in the repo root (alongside the `docs/` directory)
6. **Delete the auto-generated files** that Xcode creates (`ContentView.swift`, `LedgeApp.swift` in the default location, etc.) — we have our own versions

### 2. Add the Source Files

Drag the entire `Ledge/Sources/` folder into the Xcode project navigator. Make sure:
- "Copy items if needed" is **unchecked** (we want references, not copies)
- "Create groups" is selected
- The `Ledge` target is checked

The file structure should look like:

```
Ledge (project)
└── Sources/
    ├── App/
    │   ├── LedgeApp.swift          ← @main entry point
    │   ├── AppDelegate.swift
    │   └── DashboardView.swift
    ├── Display/
    │   ├── LedgePanel.swift
    │   └── DisplayManager.swift
    ├── Layout/
    │   └── LayoutModels.swift
    ├── Widgets/
    │   ├── Protocol/
    │   │   └── LedgeWidget.swift
    │   ├── Runtime/
    │   │   └── WidgetRegistry.swift
    │   └── BuiltIn/
    │       └── ClockWidget/
    │           └── ClockWidget.swift
    └── Settings/
        └── SettingsView.swift
```

### 3. Configure Build Settings

In the Xcode target settings:

**General tab:**
- **Minimum Deployments**: macOS 14.0 (Sonoma)
- **App Category**: Utilities

**Signing & Capabilities tab:**
- Signing: Sign to Run Locally (for now)
- **Disable App Sandbox**: In the target's Signing & Capabilities, remove the "App Sandbox" capability. The sandbox blocks USB HID access which we'll need later. For Phase 0, it also avoids any unexpected restrictions on NSPanel behaviour.

**Info tab (Info.plist values):**
No special Info.plist entries needed for Phase 0. Later phases will need:
```xml
<!-- For USB HID access (Phase 2+) -->
<key>com.apple.security.device.usb</key>
<true/>
```

### 4. Verify @main Entry Point

Xcode should recognise `LedgeApp.swift` as the entry point (it has `@main`). If you get a "multiple entry points" error, make sure you've deleted Xcode's auto-generated `LedgeApp.swift`.

### 5. Build and Run

1. Connect the Xeneon Edge to your Mac
2. Press ⌘R to build and run
3. You should see:
   - A **Settings window** on your primary display (with display detection info)
   - A **black panel with a clock and touch test circle** on the Xeneon Edge
4. **The critical test**: Open a text editor on the primary display, start typing, then tap the circle on the Xeneon Edge. If the text editor stays focused, the non-activating panel is working correctly.

## Troubleshooting

### Panel doesn't appear
- Check the Settings window → Display section. Does it say "Xeneon Edge detected"?
- The display detection matches on resolution (2560×720) or display name containing "XENEON EDGE"
- If detection fails, you can add a manual screen selection (the plumbing is there in `DisplayManager.selectScreen()`)

### Panel appears but steals focus
- Verify `LedgePanel` is using `.nonactivatingPanel` in its style mask
- Ensure it's set in the `super.init()` call, not applied afterwards
- Check that `canBecomeMain` returns `false`

### Build errors about @main
- Make sure only one file has the `@main` attribute
- Delete any auto-generated files from Xcode's project template

### Touch events not registering
- macOS may route Xeneon Edge touch as standard mouse events — this should work with SwiftUI gesture recognisers
- If `NSTouch` events are needed, we'll need to add `touchesBegan/Moved/Ended` overrides in `LedgePanel`

## What You Should See

On the **Xeneon Edge** (2560×720, landscape):
```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│                          Ledge                              │
│                        14:32:07                             │
│               Found: XENEON EDGE (2560×720)                 │
│                                                             │
│                       Touch Test                            │
│                          (●)                                │
│                        Taps: 0                              │
│   Tap the circle. Your foreground app should stay focused.  │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

On your **primary display**: A standard settings window with display info and controls.
