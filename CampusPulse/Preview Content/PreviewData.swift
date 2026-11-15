import Foundation

/// A container for SwiftUI previews: no network and no data, so screens show their loading state.
@MainActor
enum PreviewData {
    static func container(
        campus: Campus = CampusCatalog.madison,
        permission: PermissionDisplay = .allowed
    ) -> AppContainer {
        let defaults = UserDefaults(suiteName: "preview.\(UUID().uuidString)") ?? .standard
        let preferences = AppPreferences(defaults: defaults)
        preferences.selectedCampusID = campus.id
        return AppContainer(preferences: preferences, permission: permission, isPreview: true)
    }
}
