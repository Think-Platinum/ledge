import CoreLocation
import MapKit
import os.log

/// Manages CoreLocation for auto-detecting user's location.
///
/// Used by the Weather widget to determine coordinates when in auto-detect mode.
@Observable
class LocationManager: NSObject, CLLocationManagerDelegate {

    private let logger = Logger(subsystem: "com.ledge.app", category: "LocationManager")
    private let manager = CLLocationManager()

    var latitude: Double?
    var longitude: Double?
    var locationName: String?
    var authorizationStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func requestLocation() {
        manager.requestWhenInUseAuthorization()
        manager.requestLocation()
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            self.latitude = location.coordinate.latitude
            self.longitude = location.coordinate.longitude

            // Reverse geocode for display name
            if #available(macOS 26, *) {
                if let request = MKReverseGeocodingRequest(location: location),
                   let item = try? await request.mapItems.first {
                    self.locationName = item.name ?? "Unknown"
                }
            } else {
                let geocoder = CLGeocoder()
                if let placemark = try? await geocoder.reverseGeocodeLocation(location).first {
                    self.locationName = placemark.locality ?? placemark.administrativeArea ?? "Unknown"
                }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            self.logger.error("Location error: \(error.localizedDescription)")
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorized {
                manager.requestLocation()
            }
        }
    }
}
