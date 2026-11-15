import CoreLocation
import os

/// Wraps `CLLocationManager`: permission, continuous updates (including in the background
/// while sharing is on), and the most recent usable fix.
@MainActor
final class LocationProvider: NSObject {
    /// Called on the main actor whenever the authorization status changes.
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    private(set) var latest: CLLocation? {
        didSet { if usableLocation != nil { resumeWaiters() } }
    }
    private var waiters: [CheckedContinuation<Void, Never>] = []
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

    /// Upgrade from "While Using" to "Always" so sharing survives the app being closed.
    /// iOS shows this prompt at most once; after that the user has to change it in Settings.
    func requestAlwaysAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    func start() {
        guard !isUpdating else { return }
        isUpdating = true
        if Self.supportsBackgroundLocation {
            manager.allowsBackgroundLocationUpdates = true
            manager.showsBackgroundLocationIndicator = true
        }
        manager.startUpdatingLocation()
        updateRelaunchMonitoring()
    }

    /// With "Always" permission, significant-change monitoring makes iOS relaunch the app in the
    /// background after it's been closed or killed, which restarts the 2-minute schedule.
    private func updateRelaunchMonitoring() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else { return }
        if isUpdating, manager.authorizationStatus == .authorizedAlways {
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
        }
    }

    func stop() {
        guard isUpdating else { return }
        isUpdating = false
        manager.stopUpdatingLocation()
        updateRelaunchMonitoring()
        if Self.supportsBackgroundLocation {
            manager.allowsBackgroundLocationUpdates = false
        }
        latest = nil
    }

    /// The usable fix, waiting up to `timeout` for one if there isn't one yet
    /// (GPS warming up, or just back from the background).
    func currentLocation(timeout: Duration = .seconds(15)) async -> CLLocation? {
        if let usableLocation { return usableLocation }
        manager.requestLocation()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.resumeWaiters()
        }
        await withCheckedContinuation { waiters.append($0) }
        timer.cancel()
        return usableLocation
    }

    private func resumeWaiters() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    /// The latest fix if it's accurate enough to place someone in a building.
    /// Updates only arrive after 10 m of movement, so an older fix still means "still here".
    var usableLocation: CLLocation? {
        guard let latest, latest.horizontalAccuracy >= 0, latest.horizontalAccuracy <= 150,
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
        MainActor.assumeIsolated {
            updateRelaunchMonitoring()
            onAuthorizationChange?(status)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Self.log.error("Location error: \(error.localizedDescription, privacy: .public)")
    }
}
