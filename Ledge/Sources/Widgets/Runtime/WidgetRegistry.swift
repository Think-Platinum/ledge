import SwiftUI
import os.log

/// Manages registration and instantiation of widget types.
///
/// Built-in widgets are registered at app startup. Plugin widgets (future)
/// will be discovered and registered from .ledgewidget bundles.
@Observable
class WidgetRegistry {

    static let shared = WidgetRegistry()

    private let logger = Logger(subsystem: "com.ledge.app", category: "WidgetRegistry")

    /// All registered widget types, keyed by type ID.
    private(set) var registeredTypes: [String: WidgetDescriptor] = [:]

    private init() {}

    /// Register a widget descriptor.
    func register(_ descriptor: WidgetDescriptor) {
        registeredTypes[descriptor.typeID] = descriptor
        logger.info("Registered widget: \(descriptor.displayName) (\(descriptor.typeID))")
    }

    /// Create a view for a widget type by its ID.
    func createWidgetView(typeID: String, instanceID: UUID, configStore: WidgetConfigStore) -> AnyView? {
        guard let descriptor = registeredTypes[typeID] else {
            logger.error("Unknown widget type: \(typeID)")
            return nil
        }
        return descriptor.viewFactory(instanceID, configStore)
    }

    /// Create a settings view for a widget type by its ID.
    func createSettingsView(typeID: String, instanceID: UUID, configStore: WidgetConfigStore) -> AnyView? {
        guard let descriptor = registeredTypes[typeID] else {
            logger.error("Unknown widget type: \(typeID)")
            return nil
        }
        return descriptor.settingsFactory?(instanceID, configStore)
    }

    /// All registered widget types as a sorted array.
    var allTypes: [WidgetDescriptor] {
        registeredTypes.values.sorted { $0.displayName < $1.displayName }
    }

    /// Register all built-in widgets. Called once at app startup.
    func registerBuiltInWidgets() {
        register(DateTimeWidget.descriptor)
        register(SpotifyWidget.descriptor)
        register(CalendarWidget.descriptor)
        register(WeatherWidget.descriptor)
        register(WebWidget.descriptor)
        register(HomeAssistantWidget.descriptor)
        register(SystemPerformanceWidget.descriptor)
        register(SystemAudioWidget.descriptor)
        register(GoogleMeetWidget.descriptor)
        register(TouchDiagnosticsWidget.descriptor)
        logger.info("Registered \(self.registeredTypes.count) built-in widget(s)")
    }
}
