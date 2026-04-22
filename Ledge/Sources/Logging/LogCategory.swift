import Foundation

/// Catalogue of `os.log` categories used across the app. Drives the Developer
/// Settings log category picker and the per-widget `.debug` toggles. When a
/// widget adds a new `Logger(category:)`, add its category string here so it
/// surfaces in the picker and gets a debug toggle.
enum LogCategory {

    /// Display/touch-pipeline categories. These run regardless of which
    /// widgets are loaded.
    static let display: [String] = [
        "TouchRemapper",
        "HIDTouchReader",
        "HIDTouchDetector",
        "DisplayManager",
        "TouchWatchdog",
        "MouseGuard",
        "LedgePanel"
    ]

    /// Widget → category-strings mapping. One widget can declare multiple
    /// Loggers (for sub-components) — list every category string here so the
    /// user can filter each one independently.
    static let widgetGroups: [WidgetGroup] = [
        WidgetGroup(widget: "HomeAssistant", categories: ["HomeAssistantClient", "HomeAssistantWidget"]),
        WidgetGroup(widget: "Spotify",       categories: ["SpotifyAuth", "SpotifyBridge", "SpotifyWebAPI"]),
        WidgetGroup(widget: "GoogleMeet",    categories: ["GoogleMeetBridge"]),
        WidgetGroup(widget: "Calendar",      categories: ["EventKitManager"]),
        WidgetGroup(widget: "Weather",       categories: ["OpenMeteoClient", "LocationManager"]),
        WidgetGroup(widget: "SystemAudio",   categories: ["SystemAudio"]),
        WidgetGroup(widget: "SystemPerf",    categories: ["SystemPerformance"])
    ]

    struct WidgetGroup: Identifiable {
        let widget: String
        let categories: [String]
        var id: String { widget }
    }
}
