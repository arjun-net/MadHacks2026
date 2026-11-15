import Foundation
import Observation
import SwiftUI

/// Light ("Day Edition"), dark ("Night Edition"), or follow the system.
enum Appearance: String, CaseIterable, Identifiable {
    case light, dark, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light: "Day"
        case .dark: "Night"
        case .system: "System"
        }
    }

    /// `nil` follows the system setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }
}

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
    var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: Keys.appearance) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.campus: CampusCatalog.madison.id,
            Keys.sharing: true,
            Keys.onCampusOnly: true,
            Keys.pauseOvernight: true,
            Keys.busyAlerts: false,
            Keys.quietAlerts: false,
            Keys.weeklyRecap: false,
            Keys.appearance: Appearance.light.rawValue,
        ])
        selectedCampusID = defaults.string(forKey: Keys.campus) ?? CampusCatalog.madison.id
        sharingEnabled = defaults.bool(forKey: Keys.sharing)
        shareOnlyOnCampus = defaults.bool(forKey: Keys.onCampusOnly)
        pauseOvernight = defaults.bool(forKey: Keys.pauseOvernight)
        busyAreaAlerts = defaults.bool(forKey: Keys.busyAlerts)
        quietSpotAlerts = defaults.bool(forKey: Keys.quietAlerts)
        weeklyRecap = defaults.bool(forKey: Keys.weeklyRecap)
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .light
    }

    private enum Keys {
        static let campus = "campus.selectedID"
        static let sharing = "sharing.enabled"
        static let onCampusOnly = "sharing.onCampusOnly"
        static let pauseOvernight = "sharing.pauseOvernight"
        static let busyAlerts = "notifications.busyAreas"
        static let quietAlerts = "notifications.quietSpots"
        static let weeklyRecap = "notifications.weeklyRecap"
        static let appearance = "display.appearance"
    }
}
