import Foundation

/// A saved widget layout configuration.
///
/// Users can create multiple layouts (e.g., "Work", "Gaming", "Music")
/// and switch between them.
struct WidgetLayout: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var columns: Int
    var rows: Int
    var placements: [WidgetPlacement]

    /// Optional per-page background image path. When set, overrides the global
    /// dashboard background for this page only. When nil, uses the global setting.
    var backgroundImagePath: String?

    /// Default layout for the Xeneon Edge (2560x720).
    /// A 20-column by 6-row grid for fine-grained widget sizing.
    static let defaultLayout = WidgetLayout(
        id: UUID(),
        name: "Default",
        columns: 20,
        rows: 6,
        placements: [
            // Row 0-3: DateTime (4x4), Spotify (8x4), Calendar (6x4)
            WidgetPlacement(
                id: UUID(),
                widgetTypeID: "com.ledge.datetime",
                column: 0,
                row: 0,
                columnSpan: 4,
                rowSpan: 4,
                configuration: nil
            ),
            WidgetPlacement(
                id: UUID(),
                widgetTypeID: "com.ledge.spotify",
                column: 6,
                row: 0,
                columnSpan: 8,
                rowSpan: 4,
                configuration: nil
            ),
            WidgetPlacement(
                id: UUID(),
                widgetTypeID: "com.ledge.calendar",
                column: 14,
                row: 0,
                columnSpan: 6,
                rowSpan: 4,
                configuration: nil
            ),
            // Row 4-5: Weather (4x2), HA (6x2), Web (6x2)
            WidgetPlacement(
                id: UUID(),
                widgetTypeID: "com.ledge.weather",
                column: 0,
                row: 4,
                columnSpan: 4,
                rowSpan: 2,
                configuration: nil
            ),
            WidgetPlacement(
                id: UUID(),
                widgetTypeID: "com.ledge.homeassistant",
                column: 6,
                row: 4,
                columnSpan: 6,
                rowSpan: 2,
                configuration: nil
            ),
            WidgetPlacement(
                id: UUID(),
                widgetTypeID: "com.ledge.web",
                column: 14,
                row: 4,
                columnSpan: 6,
                rowSpan: 2,
                configuration: nil
            ),
        ]
    )
}

/// The placement of a single widget within a layout grid.
struct WidgetPlacement: Codable, Identifiable, Equatable {
    let id: UUID
    let widgetTypeID: String   // References a registered widget type
    var column: Int             // Grid column (0-based)
    var row: Int                // Grid row (0-based)
    var columnSpan: Int         // Width in grid cells
    var rowSpan: Int            // Height in grid cells
    var configuration: Data?    // Widget-specific config (JSON), optional
}
