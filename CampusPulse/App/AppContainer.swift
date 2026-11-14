import Foundation

/// Creates the shared UI state objects.
@MainActor
final class AppContainer {
    let preferences: AppPreferences
    let store: CampusStore
    let sharing: SharingState

    init(
        preferences: AppPreferences = AppPreferences(),
        permission: PermissionDisplay = .notRequested,
        initialSnapshot: CampusSnapshot? = nil
    ) {
        self.preferences = preferences
        self.store = CampusStore(campuses: CampusCatalog.all, preferences: preferences, initialSnapshot: initialSnapshot)
        self.sharing = SharingState(preferences: preferences, permission: permission)
    }

    static func live() -> AppContainer {
        AppContainer()
    }
}
