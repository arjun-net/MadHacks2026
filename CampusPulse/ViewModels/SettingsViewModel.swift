import Observation
import SwiftUI

@Observable
@MainActor
final class SettingsViewModel {
    let preferences: AppPreferences
    private let store: CampusStore
    private let sharing: SharingState

    var isDeletingData = false
    var deletionMessage: String?

    init(store: CampusStore, preferences: AppPreferences, sharing: SharingState) {
        self.store = store
        self.preferences = preferences
        self.sharing = sharing
    }

    var campuses: [Campus] { store.campuses }
    var selectedCampus: Campus { store.campus }
    var permission: PermissionDisplay { sharing.permission }
    var sharingStatusLabel: String { sharing.status == .active ? "On" : "Off" }

    var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }

    func select(_ campus: Campus) {
        store.select(campus)
    }

    /// UI-only: shows a progress state, then a confirmation.
    func deleteSharedData() async {
        isDeletingData = true
        try? await Task.sleep(for: .milliseconds(800))
        isDeletingData = false
        deletionMessage = "Your past contributions have been removed."
    }
}
