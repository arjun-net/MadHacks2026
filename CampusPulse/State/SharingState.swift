import CoreLocation
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
        case .allowed: Theme.Colors.live
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

    let updateInterval = AppConfig.updateInterval

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let campus: () -> Campus
    @ObservationIgnored private let provider: LocationProvider
    @ObservationIgnored private let api: LocationAPI
    @ObservationIgnored private let queue: PendingLocationQueue
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    /// Previews and the debug `-screen denied` option pin the permission instead of asking the system.
    @ObservationIgnored private var isSimulated: Bool

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

        provider.onAuthorizationChange = { [weak self] status in
            self?.authorizationDidChange(status)
        }
        // Sharing is on by default: ask for permission on first launch, then start sending.
        if isEnabled {
            switch self.permission {
            case .allowed: startReporting()
            case .notRequested where !isSimulated: provider.requestAuthorization()
            default: break
            }
        }
    }

    var isEnabled: Bool { preferences.sharingEnabled }

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

    // MARK: - Permission

    private func authorizationDidChange(_ status: CLAuthorizationStatus) {
        guard !isSimulated else { return }
        permission = PermissionDisplay(status)
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
            deviceID: DeviceIdentity.id
        )
        let pending = queue.load() + [point]
        let result = await api.send(pending)

        switch result {
        case .accepted:
            Self.log.info("Sent \(pending.count) reading(s) for \(LocationAPI.timestampString(slot), privacy: .public)")
            queue.save([])
            pendingCount = 0
            lastUpdateAt = slot
        case .retryLater:
            queue.save(pending)
            pendingCount = min(pending.count, PendingLocationQueue.capacity)
        case .rejected:
            // Invalid payload: drop it rather than retrying forever.
            queue.save([])
            pendingCount = 0
        }
    }

    /// Ray-casting point-in-polygon test against the campus outline.
    private static func contains(_ polygon: [Coordinate], _ point: Coordinate) -> Bool {
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
}
