import Observation
import SwiftUI

@Observable
@MainActor
final class SettingsViewModel {
    let preferences: AppPreferences
    private let store: CampusStore
    private let sharing: SharingState
    private let alerts: AlertCenter

    /// Shown in an alert after a reset, or when notifications are blocked.
    var message: String?

    init(store: CampusStore, preferences: AppPreferences, sharing: SharingState, alerts: AlertCenter) {
        self.store = store
        self.preferences = preferences
        self.sharing = sharing
        self.alerts = alerts
    }

    /// A notification switch changed. Turning one on asks for permission; if it's refused
    /// the switch goes back off. Also keeps the background refresh and recap schedule in step.
    func notificationSettingChanged(isOn: Bool, revert: @escaping () -> Void) async {
        if isOn, !(await alerts.requestPermission()) {
            revert()
            message = "Notifications are off for Campus Pulse. Turn them on in the Settings app to get alerts."
        }
        alerts.updateWeeklyRecap(history: store.history, campus: store.campus)
    }

    /// Starred places, so the busy-alert footer can point people to the star.
    var hasFavorites: Bool { !preferences.favoriteAreaIDs.isEmpty }

    var campuses: [Campus] { store.campuses }
    var selectedCampus: Campus { store.campus }
    var permission: PermissionDisplay { sharing.permission }
    var permissionLabel: String { sharing.permissionLabel }
    var sharingStatusLabel: String { sharing.status == .active ? "On" : "Off" }

    var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    func select(_ campus: Campus) {
        store.select(campus)
    }

    /// Reloads the map and trends after a developer override changes.
    func reloadData() {
        store.reload()
    }
}
