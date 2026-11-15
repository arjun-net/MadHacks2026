import Observation
import SwiftUI

@Observable
@MainActor
final class SettingsViewModel {
    let preferences: AppPreferences
    private let store: CampusStore
    private let sharing: SharingState

    var resetMessage: String?

    init(store: CampusStore, preferences: AppPreferences, sharing: SharingState) {
        self.store = store
        self.preferences = preferences
        self.sharing = sharing
    }

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

    /// New random device ID; unsent readings are dropped.
    func resetDeviceID() {
        sharing.resetIdentity()
        resetMessage = "Your device ID was reset. Readings from now on start fresh."
    }
}
