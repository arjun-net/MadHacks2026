import Foundation
import Observation

/// User preferences persisted to `UserDefaults`.
@Observable
final class AppPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    var selectedCampusID: String { didSet { defaults.set(selectedCampusID, forKey: Keys.campus) } }
    var sharingEnabled: Bool { didSet { defaults.set(sharingEnabled, forKey: Keys.sharing) } }
    var shareOnlyOnCampus: Bool { didSet { defaults.set(shareOnlyOnCampus, forKey: Keys.onCampusOnly) } }
    var pauseOvernight: Bool { didSet { defaults.set(pauseOvernight, forKey: Keys.pauseOvernight) } }
    var busyAreaAlerts: Bool { didSet { defaults.set(busyAreaAlerts, forKey: Keys.busyAlerts) } }
    var quietSpotAlerts: Bool { didSet { defaults.set(quietSpotAlerts, forKey: Keys.quietAlerts) } }
    var weeklyRecap: Bool { didSet { defaults.set(weeklyRecap, forKey: Keys.weeklyRecap) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.campus: CampusCatalog.madison.id,
            Keys.sharing: false,
            Keys.onCampusOnly: true,
            Keys.pauseOvernight: true,
            Keys.busyAlerts: false,
            Keys.quietAlerts: false,
            Keys.weeklyRecap: false,
        ])
        selectedCampusID = defaults.string(forKey: Keys.campus) ?? CampusCatalog.madison.id
        sharingEnabled = defaults.bool(forKey: Keys.sharing)
        shareOnlyOnCampus = defaults.bool(forKey: Keys.onCampusOnly)
        pauseOvernight = defaults.bool(forKey: Keys.pauseOvernight)
        busyAreaAlerts = defaults.bool(forKey: Keys.busyAlerts)
        quietSpotAlerts = defaults.bool(forKey: Keys.quietAlerts)
        weeklyRecap = defaults.bool(forKey: Keys.weeklyRecap)
    }

    private enum Keys {
        static let campus = "campus.selectedID"
        static let sharing = "sharing.enabled"
        static let onCampusOnly = "sharing.onCampusOnly"
        static let pauseOvernight = "sharing.pauseOvernight"
        static let busyAlerts = "notifications.busyAreas"
        static let quietAlerts = "notifications.quietSpots"
        static let weeklyRecap = "notifications.weeklyRecap"
    }
}
