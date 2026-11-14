import Foundation

/// Fixtures for SwiftUI previews, pinned to an early-afternoon time so they look representative.
@MainActor
enum PreviewData {
    static let referenceDate: Date = {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: .now)
        components.hour = 13
        components.minute = 10
        return Calendar.current.date(from: components) ?? .now
    }()

    static var snapshot: CampusSnapshot {
        snapshot(for: CampusCatalog.madison)
    }

    static func snapshot(for campus: Campus) -> CampusSnapshot {
        SampleActivityData.snapshot(for: campus, tick: 3, date: referenceDate)
    }

    static func container(
        campus: Campus = CampusCatalog.madison,
        preloaded: Bool = true,
        permission: PermissionDisplay = .allowed
    ) -> AppContainer {
        let defaults = UserDefaults(suiteName: "preview.\(UUID().uuidString)") ?? .standard
        let preferences = AppPreferences(defaults: defaults)
        preferences.selectedCampusID = campus.id
        return AppContainer(
            preferences: preferences,
            permission: permission,
            initialSnapshot: preloaded ? snapshot(for: campus) : nil
        )
    }
}
