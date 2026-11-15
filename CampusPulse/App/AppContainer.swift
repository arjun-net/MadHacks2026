import Foundation

/// Creates the shared UI state objects.
@MainActor
final class AppContainer {
    let preferences: AppPreferences
    let store: CampusStore
    let sharing: SharingState
    let alerts: AlertCenter

    init(
        preferences: AppPreferences = AppPreferences(),
        /// nil uses the real system permission; previews pass a fixed value.
        permission: PermissionDisplay? = nil,
        initialSnapshot: CampusSnapshot? = nil
    ) {
        self.preferences = preferences
        // Older builds kept a random device ID; readings no longer carry one, so drop it.
        UserDefaults.standard.removeObject(forKey: "device.id")
        self.store = CampusStore(campuses: CampusCatalog.all, preferences: preferences, initialSnapshot: initialSnapshot)
        let store = self.store
        self.sharing = SharingState(preferences: preferences, permission: permission, campus: { store.campus })
        let alerts = AlertCenter(preferences: preferences)
        self.alerts = alerts
        store.onLiveUpdate = { [weak store] snapshot in
            alerts.evaluate(snapshot)
            if let store { alerts.refreshRecapIfNeeded(history: store.history, campus: store.campus) }
        }
    }

    static func live() -> AppContainer {
        AppContainer()
    }
}
