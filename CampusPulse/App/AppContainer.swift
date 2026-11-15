import Foundation

/// Creates the shared UI state objects.
@MainActor
final class AppContainer {
    let preferences: AppPreferences
    let store: CampusStore
    let sharing: SharingState

    init(
        preferences: AppPreferences = AppPreferences(),
        /// nil uses the real system permission; previews pass a fixed value.
        permission: PermissionDisplay? = nil,
        initialSnapshot: CampusSnapshot? = nil
    ) {
        self.preferences = preferences
        self.store = CampusStore(campuses: CampusCatalog.all, preferences: preferences, initialSnapshot: initialSnapshot)
        let store = self.store
        self.sharing = SharingState(preferences: preferences, permission: permission, campus: { store.campus })
    }

    static func live() -> AppContainer {
        AppContainer()
    }
}
