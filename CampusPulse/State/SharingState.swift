import CoreLocation
import Network
import Observation
import os
import SwiftUI

enum SharingStatus: Equatable {
    case off
    case active
    case permissionDenied
}

/// The system location permission, as shown in the UI.
enum PermissionDisplay: Equatable {
    case notRequested, allowed, denied

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways: self = .allowed
        case .denied, .restricted: self = .denied
        default: self = .notRequested
        }
    }

    var displayName: String {
        switch self {
        case .notRequested: "Not Requested"
        case .allowed: "While Using"
        case .denied: "Denied"
        }
    }

    var tint: Color {
        switch self {
        case .allowed: Theme.Colors.positive
        case .denied: Theme.Colors.danger
        case .notRequested: Theme.Colors.warning
        }
    }
}

/// Location sharing: permission, and while sharing is on, one reading sent to the backend
/// on every even minute (10:38, 10:40, 10:42…). Undelivered readings are queued on disk
/// and flushed in a batch with the next one.
@Observable
@MainActor
final class SharingState {
    private(set) var permission: PermissionDisplay
    /// Slot time of the last reading the server accepted.
    private(set) var lastUpdateAt: Date?
    /// The next even-minute slot.
    private(set) var nextUpdateAt: Date?
    /// Readings waiting to be delivered.
    private(set) var pendingCount = 0
    /// "Always" lets sharing continue after the app is closed (iOS relaunches it in the background).
    private(set) var hasAlwaysPermission = false

    let updateInterval = AppConfig.updateInterval

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let campus: () -> Campus
    @ObservationIgnored private let provider: LocationProvider
    @ObservationIgnored private let api: LocationAPI
    @ObservationIgnored private let queue: PendingLocationQueue
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    /// Previews and the debug `-screen denied` option pin the permission instead of asking the system.
    @ObservationIgnored private var isSimulated: Bool
    @ObservationIgnored private var isDelivering = false
    @ObservationIgnored private var pathMonitor: NWPathMonitor?

    private static let log = Logger(subsystem: "CampusPulse", category: "Sharing")

    init(
        preferences: AppPreferences,
        permission: PermissionDisplay? = nil,
        campus: @escaping () -> Campus,
        provider: LocationProvider? = nil,
        api: LocationAPI = LocationAPI(),
        queue: PendingLocationQueue = PendingLocationQueue()
    ) {
        self.preferences = preferences
        self.campus = campus
        let provider = provider ?? LocationProvider()
        self.provider = provider
        self.api = api
        self.queue = queue
        self.isSimulated = permission != nil
        self.permission = permission ?? PermissionDisplay(provider.authorizationStatus)
        self.pendingCount = isSimulated ? 0 : queue.load().count
        self.hasAlwaysPermission = !isSimulated && provider.authorizationStatus == .authorizedAlways

        provider.onAuthorizationChange = { [weak self] status in
            self?.authorizationDidChange(status)
        }
        if !isSimulated { watchNetwork() }
        // Sharing is on by default. Permission is asked from onboarding on first launch
        // (or here on later launches, if it was never answered).
        if isEnabled {
            switch self.permission {
            case .allowed: startReporting()
            case .notRequested where !isSimulated && preferences.hasOnboarded: provider.requestAuthorization()
            default: break
            }
        }
    }

    var isEnabled: Bool { preferences.sharingEnabled }

    /// "Always", "While Using", "Denied" or "Not Requested".
    var permissionLabel: String {
        permission == .allowed && hasAlwaysPermission ? "Always" : permission.displayName
    }

    /// Whether asking for "Always" would show the system prompt. iOS only shows it once;
    /// after that, the only way is the Settings app.
    var canPromptForAlways: Bool {
        permission == .allowed && !hasAlwaysPermission && !isSimulated
            && !UserDefaults.standard.bool(forKey: Self.askedAlwaysKey)
    }

    func requestAlwaysPermission() {
        guard canPromptForAlways else { return }
        UserDefaults.standard.set(true, forKey: Self.askedAlwaysKey)
        provider.requestAlwaysAuthorization()
    }

    private static let askedAlwaysKey = "location.askedAlways"

    var status: SharingStatus {
        if permission == .denied { return .permissionDenied }
        return isEnabled ? .active : .off
    }

    func setEnabled(_ enabled: Bool) {
        guard permission != .denied else { return }
        preferences.sharingEnabled = enabled
        if enabled {
            if permission == .notRequested, !isSimulated {
                // Reporting starts once the system answers (see `authorizationDidChange`).
                provider.requestAuthorization()
            } else {
                if permission == .notRequested { permission = .allowed }
                startReporting()
            }
        } else {
            stopReporting()
        }
    }

    /// Used by previews and the debug launch option to show the denied state.
    func simulate(permission: PermissionDisplay) {
        isSimulated = true
        self.permission = permission
        if permission == .denied {
            preferences.sharingEnabled = false
            stopReporting()
        }
    }

    /// Starts over with a new random device ID and drops readings that haven't been sent,
    /// so nothing sent from now on can be linked to what this phone sent before.
    func resetIdentity() {
        DeviceIdentity.reset()
        queue.save([])
        pendingCount = 0
        lastUpdateAt = nil
    }

    // MARK: - Permission

    private func authorizationDidChange(_ status: CLAuthorizationStatus) {
        guard !isSimulated else { return }
        permission = PermissionDisplay(status)
        hasAlwaysPermission = status == .authorizedAlways
        switch permission {
        case .allowed:
            if isEnabled { startReporting() }
        case .denied:
            preferences.sharingEnabled = false
            stopReporting()
        case .notRequested:
            break
        }
    }

    // MARK: - Schedule

    private func startReporting() {
        guard timerTask == nil else { return }
        if !isSimulated { provider.start() }
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let slot = Self.nextSlot(after: .now)
                self?.nextUpdateAt = slot
                try? await Task.sleep(for: .seconds(max(0, slot.timeIntervalSinceNow)))
                guard !Task.isCancelled, let self else { return }
                // If the app was suspended past the slot, skip it rather than send a stale reading.
                guard Date.now.timeIntervalSince(slot) < 60 else { continue }
                await self.report(slot: slot)
            }
        }
    }

    private func stopReporting() {
        timerTask?.cancel()
        timerTask = nil
        nextUpdateAt = nil
        provider.stop()
    }

    /// The next even minute strictly after `date`. Unix time 0 is an even minute, so
    /// multiples of 120 s land on :00, :02, :04… in UTC (and in every whole- or half-hour time zone).
    nonisolated static func nextSlot(after date: Date) -> Date {
        let interval = AppConfig.updateInterval
        let slots = (date.timeIntervalSince1970 / interval).rounded(.down) + 1
        return Date(timeIntervalSince1970: slots * interval)
    }

    // MARK: - Reporting

    private func report(slot: Date) async {
        guard isEnabled, permission == .allowed, !isSimulated else { return }

        if preferences.pauseOvernight, (0..<6).contains(Calendar.current.component(.hour, from: slot)) {
            return
        }
        guard let location = await provider.currentLocation() else {
            Self.log.info("No usable location fix for \(LocationAPI.timestampString(slot), privacy: .public); skipping")
            return
        }
        let coordinate = Coordinate(location.coordinate.latitude, location.coordinate.longitude)
        if preferences.shareOnlyOnCampus, !Self.contains(campus().boundary, coordinate) {
            return
        }

        let point = LocationPoint(
            lat: coordinate.latitude,
            lng: coordinate.longitude,
            timestamp: slot,
            deviceID: DeviceIdentity.id,
            building: BuildingLocator.forCampus(campus().id)?.building(at: coordinate)
        )
        await deliver(adding: point)
    }

    /// Sends anything queued from earlier failures. Called when the network comes back
    /// and when the app returns to the foreground, so readings don't wait for the next slot.
    func flushPending() async {
        guard !isSimulated, pendingCount > 0 else { return }
        await deliver(adding: nil)
    }

    /// Sends the queue plus `point` in one request; keeps them queued if the server can't take them.
    private func deliver(adding point: LocationPoint?) async {
        // A slot reading that arrives mid-flush is queued and goes out with the next delivery.
        guard !isDelivering else {
            if let point {
                queue.save(queue.load() + [point])
                pendingCount = queue.load().count
            }
            return
        }
        isDelivering = true
        defer { isDelivering = false }

        let pending = queue.load() + (point.map { [$0] } ?? [])
        guard !pending.isEmpty else { return }

        let result = await api.send(pending)
        // Readings queued while this request was in flight.
        let arrivedMeanwhile = queue.load().filter { !pending.contains($0) }

        switch result {
        case .accepted:
            Self.log.info("Sent \(pending.count) reading(s)")
            queue.save(arrivedMeanwhile)
            if let latest = pending.map(\.timestamp).max() { lastUpdateAt = max(lastUpdateAt ?? latest, latest) }
        case .retryLater:
            queue.save(pending + arrivedMeanwhile)
        case .rejected:
            // Invalid payload: drop it rather than retrying forever.
            queue.save(arrivedMeanwhile)
        }
        pendingCount = queue.load().count
    }

    /// Flushes the queue as soon as a connection is available again.
    private func watchNetwork() {
        let monitor = NWPathMonitor()
        var wasConnected = true
        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            defer { wasConnected = connected }
            guard connected, !wasConnected else { return }
            Task { @MainActor [weak self] in await self?.flushPending() }
        }
        monitor.start(queue: DispatchQueue(label: "CampusPulse.network"))
        pathMonitor = monitor
    }

    /// Ray-casting point-in-polygon test against the campus outline.
    static func contains(_ polygon: [Coordinate], _ point: Coordinate) -> Bool {
        guard polygon.count >= 3 else { return true }
        var inside = false
        var j = polygon.count - 1
        for i in polygon.indices {
            let a = polygon[i], b = polygon[j]
            if (a.latitude > point.latitude) != (b.latitude > point.latitude),
               point.longitude < (b.longitude - a.longitude) * (point.latitude - a.latitude) / (b.latitude - a.latitude) + a.longitude {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

/// A random ID generated once per install and reused for every reading.
enum DeviceIdentity {
    private static let key = "device.id"

    static var id: String {
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let new = "ios-" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(new, forKey: key)
        return new
    }

    /// The next `id` read creates a fresh one.
    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
