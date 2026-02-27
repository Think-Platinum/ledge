# Widget Framework Implementation Progress

**Started:** 2026-02-12
**Status:** Complete (build verified)

---

## Tier 1: Framework Foundation
- [x] `Widgets/Runtime/WidgetConfigStore.swift` — Per-instance config persistence
- [x] `Widgets/Protocol/LedgeWidget.swift` — Evolve WidgetDescriptor & WidgetContext
- [x] `Widgets/BuiltIn/ClockWidget/ClockWidget.swift` — Update factory signatures
- [x] `Widgets/Runtime/WidgetRegistry.swift` — Update createWidgetView signatures
- [x] `Widgets/Runtime/WidgetContainer.swift` — Widget chrome (bg, corners, border)
- [x] `Layout/LayoutModels.swift` — 10x3 grid, default layout
- [x] `Layout/GridRenderer.swift` — Grid calculation + SwiftUI rendering
- [x] `Layout/LayoutManager.swift` — Layout management + persistence

## Tier 2: Integration
- [x] `App/DashboardView.swift` — Replace placeholder with GridRenderer
- [x] `App/AppDelegate.swift` — Create LayoutManager/ConfigStore, wire up
- [x] `App/LedgeApp.swift` — Inject LayoutManager into settings window

## Tier 3: Widgets
- [x] `Widgets/BuiltIn/DateTimeWidget/DateTimeWidget.swift` — Enhanced clock
- [x] `Widgets/BuiltIn/SpotifyWidget/SpotifyWidget.swift` — Spotify view + descriptor
- [x] `Widgets/BuiltIn/SpotifyWidget/SpotifyBridge.swift` — AppleScript bridge
- [x] `Widgets/BuiltIn/SpotifyWidget/SpotifyWebAPI.swift` — Web API stub
- [x] `Widgets/BuiltIn/CalendarWidget/CalendarWidget.swift` — Calendar view + descriptor
- [x] `Widgets/BuiltIn/CalendarWidget/EventKitManager.swift` — EventKit wrapper
- [x] `Widgets/BuiltIn/WeatherWidget/WeatherWidget.swift` — Weather view + descriptor
- [x] `Widgets/BuiltIn/WeatherWidget/OpenMeteoClient.swift` — Open-Meteo API client
- [x] `Widgets/BuiltIn/WeatherWidget/LocationManager.swift` — CoreLocation wrapper
- [x] `Widgets/BuiltIn/WebWidget/WebWidget.swift` — Web/iFrame view + descriptor
- [x] `Widgets/BuiltIn/WebWidget/WebViewRepresentable.swift` — WKWebView wrapper
- [x] `Widgets/BuiltIn/HomeAssistantWidget/HomeAssistantWidget.swift` — HA view + descriptor
- [x] `Widgets/BuiltIn/HomeAssistantWidget/HomeAssistantClient.swift` — HA REST API client

## Tier 4: Polish & Settings
- [x] `Settings/SettingsView.swift` — Widget list, layout preview, add widget
- [x] `Widgets/Runtime/WidgetRegistry.swift` — Register all 7 widgets, default layout
- [x] Xcode project — Auto-discovered via PBXFileSystemSynchronizedRootGroup
- [x] Info.plist — `NSCalendarsFullAccessUsageDescription`, `NSLocationWhenInUseUsageDescription`

## Tier 5: Build Verification
- [x] `xcodebuild` compiles cleanly (0 errors, 0 warnings)
- [ ] Grid renders on Edge with all 6 widgets positioned (needs hardware test)

---

## Grid Specification
- **Grid:** 10 columns x 3 rows on 2560x720
- **Outer padding:** 12pt, **Gap:** 8pt
- **Cell size:** ~246 x 227 points

## Default Layout
```
Col:  0  1  2  3  4  5  6  7  8  9
Row 0: [DateTime ]   [Spotify         ]   [Calendar      ]
Row 1: [DateTime ]   [Spotify         ]   [Calendar      ]
Row 2: [Weather  ]   [HomeAssistant   ]   [Web           ]
```

## Files Created/Modified

### New files (17)
| File | Purpose |
|------|---------|
| `Widgets/Runtime/WidgetConfigStore.swift` | Per-instance config persistence (JSON, ~/Library/Application Support/) |
| `Widgets/Runtime/WidgetContainer.swift` | Widget chrome (rounded corners, border, error state) |
| `Layout/GridRenderer.swift` | GridMetrics + ZStack-based widget positioning |
| `Layout/LayoutManager.swift` | @Observable layout manager with disk persistence |
| `Widgets/BuiltIn/DateTimeWidget/DateTimeWidget.swift` | Enhanced clock with config (24h, seconds, date format) |
| `Widgets/BuiltIn/SpotifyWidget/SpotifyWidget.swift` | Now playing view with album art + controls |
| `Widgets/BuiltIn/SpotifyWidget/SpotifyBridge.swift` | AppleScript bridge for Spotify control |
| `Widgets/BuiltIn/SpotifyWidget/SpotifyWebAPI.swift` | Web API stub (future) |
| `Widgets/BuiltIn/CalendarWidget/CalendarWidget.swift` | EventKit calendar events display |
| `Widgets/BuiltIn/CalendarWidget/EventKitManager.swift` | EventKit access + event fetching |
| `Widgets/BuiltIn/WeatherWidget/WeatherWidget.swift` | Current conditions + daily forecast |
| `Widgets/BuiltIn/WeatherWidget/OpenMeteoClient.swift` | Open-Meteo API client (free, no key) |
| `Widgets/BuiltIn/WeatherWidget/LocationManager.swift` | CoreLocation for auto-detect |
| `Widgets/BuiltIn/WebWidget/WebWidget.swift` | Embedded webpage widget |
| `Widgets/BuiltIn/WebWidget/WebViewRepresentable.swift` | WKWebView NSViewRepresentable wrapper |
| `Widgets/BuiltIn/HomeAssistantWidget/HomeAssistantWidget.swift` | Smart home entity control |
| `Widgets/BuiltIn/HomeAssistantWidget/HomeAssistantClient.swift` | HA REST API client |

### Modified files (8)
| File | Changes |
|------|---------|
| `Widgets/Protocol/LedgeWidget.swift` | @Observable WidgetContext, factory signatures with (UUID, ConfigStore), iconSystemName, GridSize constants |
| `Widgets/Runtime/WidgetRegistry.swift` | @Observable, new createWidgetView/Settings signatures, registerBuiltInWidgets with all 7 |
| `Widgets/BuiltIn/ClockWidget/ClockWidget.swift` | Updated to new factory signature, simplified |
| `Layout/LayoutModels.swift` | 10x3 grid, default layout with 6 widgets |
| `App/DashboardView.swift` | GridRenderer replaces placeholder, triple-tap debug toggle |
| `App/AppDelegate.swift` | Creates LayoutManager/ConfigStore, wires environment |
| `App/LedgeApp.swift` | Passes layoutManager/configStore to SettingsView |
| `Settings/SettingsView.swift` | Real widget list + per-widget config + layout preview + add widget sheet |
