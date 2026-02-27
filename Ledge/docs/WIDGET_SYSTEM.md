# Widget System Design

## Philosophy

The widget system is the heart of Ledge. It should be:

- **Simple to build for** — A widget author should be able to create a basic widget in under 50 lines of Swift
- **Safe** — A misbehaving widget should not be able to crash the app or steal user data
- **Responsive** — Widgets must render at 60fps and respond to touch immediately
- **Data-driven** — Widgets declare what data they need; the host provides it

## Widget Protocol

Every widget must conform to the `LedgeWidget` protocol:

```swift
import SwiftUI

/// The core protocol that all Ledge widgets must conform to.
protocol LedgeWidget: Identifiable {
    /// Unique identifier for this widget type (reverse-DNS style)
    static var widgetTypeID: String { get }

    /// Human-readable name
    static var displayName: String { get }

    /// Short description of what this widget does
    static var description: String { get }

    /// Preferred minimum grid size (columns × rows)
    static var minimumSize: GridSize { get }

    /// Preferred default grid size
    static var defaultSize: GridSize { get }

    /// Maximum grid size (nil = unlimited)
    static var maximumSize: GridSize? { get }

    /// The SwiftUI view that renders this widget
    associatedtype Body: View
    @ViewBuilder var body: Body { get }

    /// The SwiftUI view for this widget's settings (shown in config panel)
    associatedtype SettingsBody: View
    @ViewBuilder var settingsBody: SettingsBody { get }

    /// Called when the widget is first loaded
    func onLoad(context: WidgetContext) async

    /// Called when the widget is about to be removed
    func onUnload() async

    /// Called when the widget's configuration changes
    func onConfigurationChanged(_ config: WidgetConfiguration) async
}

struct GridSize: Codable, Equatable {
    let columns: Int
    let rows: Int
}
```

## Widget Context

The host application provides each widget with a `WidgetContext` that gives access to platform services:

```swift
@MainActor
class WidgetContext: ObservableObject {
    /// The widget's allocated size in points
    @Published var size: CGSize

    /// Access to system data providers
    let systemData: SystemDataAccess

    /// Access to media/now-playing information
    let media: MediaDataAccess

    /// Access to network state
    let network: NetworkDataAccess

    /// Persistent storage scoped to this widget instance
    let storage: WidgetStorage

    /// Schedule periodic updates
    func requestUpdate(every interval: TimeInterval)

    /// Request a one-time data refresh
    func requestRefresh()

    /// Open a URL on the primary display (not on the Xeneon Edge)
    func openURL(_ url: URL)

    /// Show a brief toast notification on the widget
    func showToast(_ message: String, duration: TimeInterval)
}
```

## Built-in Widget Catalogue

These are the widgets that ship with Ledge. They serve as both useful defaults and reference implementations for third-party widget authors.

### Phase 1 — Core Widgets

| Widget | Description | Data Source |
|--------|-------------|-------------|
| **Clock** | Analogue or digital clock with timezone support | System time |
| **CPU Monitor** | CPU usage graph, per-core breakdown, temperature | IOKit SMC |
| **GPU Monitor** | GPU usage, temperature, VRAM | IOKit SMC |
| **Memory Monitor** | RAM usage bar/graph, pressure indicator | `host_statistics` |
| **Now Playing** | Album art, track name, artist, playback controls | MediaRemote framework |
| **Volume Control** | Per-app volume sliders or master volume | CoreAudio |
| **Weather** | Current conditions, forecast | WeatherKit or public API |
| **Shortcut Launcher** | Grid of app/script launch buttons | User-configured |

### Phase 2 — Extended Widgets

| Widget | Description | Data Source |
|--------|-------------|-------------|
| **Web View** | Embedded web content (like iCUE's iFrame widget) | WKWebView |
| **Network Monitor** | Upload/download speed graph | `nettop` / Network Extension |
| **Disk Monitor** | Disk usage, I/O rates | IOKit |
| **Calendar** | Upcoming events from system calendar | EventKit |
| **Timer / Stopwatch** | Configurable countdown or stopwatch | Local |
| **Clipboard History** | Recent clipboard entries, tap to re-copy | NSPasteboard |
| **Display Controls** | Brightness, contrast, colour temp sliders for the Xeneon Edge | USB HID / DDC/CI |

### Phase 3 — Community / Plugin Widgets

| Widget | Description |
|--------|-------------|
| **Spotify** | Rich Spotify controls (requires Spotify API) |
| **Home Assistant** | Smart home device controls |
| **OBS Controls** | Scene switching, recording controls |
| **Twitch Chat** | Live chat overlay |
| **Custom HTML** | User-authored HTML/CSS/JS widget |

## Widget Loading & Discovery

### Built-in Widgets
Built-in widgets are compiled directly into the application. They're registered in a central `WidgetRegistry`:

```swift
class WidgetRegistry {
    static let shared = WidgetRegistry()

    private var registeredTypes: [String: any LedgeWidget.Type] = [:]

    func register<W: LedgeWidget>(_ type: W.Type) {
        registeredTypes[W.widgetTypeID] = type
    }

    func createWidget(typeID: String) -> (any LedgeWidget)? {
        guard let type = registeredTypes[typeID] else { return nil }
        return type.init()
    }

    func allWidgetTypes() -> [any LedgeWidget.Type] {
        Array(registeredTypes.values)
    }
}
```

### Plugin Widgets (Future)

Third-party widgets will be distributed as `.ledgewidget` bundles (macOS bundles with a custom extension). These are loaded at runtime via `Bundle`:

```
MyWidget.ledgewidget/
├── Contents/
│   ├── Info.plist          # Widget metadata
│   ├── MacOS/
│   │   └── MyWidget        # Compiled binary
│   └── Resources/
│       └── icon.png        # Widget icon
```

The plugin loading process:
1. Scan `~/Library/Application Support/Ledge/plugins/` for `.ledgewidget` bundles
2. Load the bundle via `Bundle(url:)`
3. Locate the principal class (must conform to `LedgeWidget`)
4. Register it in the `WidgetRegistry`
5. Make it available in the widget picker

**Security considerations for plugins:**
- Plugins run in-process initially (simplicity). Future versions may use XPC for isolation.
- Plugin bundles should be code-signed (warn on unsigned bundles).
- Plugins declare required permissions in Info.plist (network access, file access, etc.).
- The host app may restrict plugin access to sensitive APIs.

## Widget Rendering

Each widget is rendered as a SwiftUI view within a container that provides:
- A background (configurable per-widget: solid colour, blur, transparent)
- Rounded corner clipping
- A subtle border to visually separate widgets
- An error boundary (catches SwiftUI rendering failures)

```swift
struct WidgetContainer<W: LedgeWidget>: View {
    let widget: W
    let placement: WidgetPlacement
    @ObservedObject var context: WidgetContext

    var body: some View {
        widget.body
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(widgetBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
            )
    }
}
```

## Widget Communication

Widgets do not communicate directly with each other. If cross-widget communication is needed (e.g., a "theme changed" event), it goes through the host via `NotificationCenter` or a shared `WidgetBus`:

```swift
actor WidgetBus {
    static let shared = WidgetBus()

    func post(_ event: WidgetEvent)
    func subscribe(to eventType: WidgetEvent.Type) -> AsyncStream<WidgetEvent>
}

enum WidgetEvent {
    case themeChanged(Theme)
    case layoutChanged
    case displaySettingsChanged
    case customEvent(name: String, data: Any)
}
```

## Widget Configuration UI

When a user wants to configure a widget, the settings panel appears on the **primary display** (not the Xeneon Edge). This is because:
1. The Xeneon Edge's 720px height makes complex settings UIs cramped
2. Settings interaction should use the standard keyboard/trackpad, not the touchscreen
3. Keeping settings on the primary display avoids the non-activating panel complications for text input

The settings panel shows:
- Widget-specific settings (provided by `settingsBody`)
- Common settings (background style, update interval, widget name)
- Grid placement controls (position, size)

## Touch Interaction Patterns

Widgets should follow these touch interaction conventions:

| Gesture | Action |
|---------|--------|
| **Single tap** | Primary action (play/pause, toggle, select) |
| **Long press** | Open context menu or enter edit mode |
| **Horizontal swipe** | Navigate within widget (next/prev track, scroll list) |
| **Vertical swipe** | Scroll content within widget |
| **Two-finger tap** | Secondary action (widget-defined) |
| **Pinch** | Reserved for layout zoom (future) |

Widgets receive touch events through standard SwiftUI gesture recognisers. The widget container handles the long-press-to-edit gesture before passing events to the widget.
