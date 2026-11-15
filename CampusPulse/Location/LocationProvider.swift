import CoreLocation
import os

/// Wraps `CLLocationManager`: permission, continuous updates (including in the background
/// while sharing is on), and the most recent usable fix.
@MainActor
final class LocationProvider: NSObject {
    /// Called on the main actor whenever the authorization status changes.
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    private(set) var latest: CLLocation?
    private let manager = CLLocationManager()
    private var isUpdating = false
    private nonisolated static let log = Logger(subsystem: "CampusPulse", category: "Location")

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 10
        manager.activityType = .fitness
        // Keep updates (and with them the 2-minute schedule) alive when the screen is off.
        manager.pausesLocationUpdatesAutomatically = false
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }

    func requestAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func start() {
        guard !isUpdating else { return }
        isUpdating = true
        if Self.supportsBackgroundLocation {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
    }

    func stop() {
        guard isUpdating else { return }
        isUpdating = false
        manager.stopUpdatingLocation()
        if Self.supportsBackgroundLocation {
            manager.allowsBackgroundLocationUpdates = false
        }
        latest = nil
    }

    /// The latest fix if it's accurate enough to place someone in a building.
    /// Updates only arrive after 10 m of movement, so an older fix still means "still here".
    var usableLocation: CLLocation? {
        guard let latest, latest.horizontalAccuracy >= 0, latest.horizontalAccuracy <= 100,
              -latest.timestamp.timeIntervalSinceNow < 30 * 60 else { return nil }
        return latest
    }

    /// Setting `allowsBackgroundLocationUpdates` without the `location` background mode crashes.
    private static let supportsBackgroundLocation: Bool = {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") ?? false
    }()
}

extension LocationProvider: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated { latest = last }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated { onAuthorizationChange?(status) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Self.log.error("Location error: \(error.localizedDescription, privacy: .public)")
    }
}
