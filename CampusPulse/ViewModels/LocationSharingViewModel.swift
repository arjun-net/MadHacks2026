import Observation
import SwiftUI

@Observable
@MainActor
final class LocationSharingViewModel {
    private let sharing: SharingState
    private let store: CampusStore

    init(sharing: SharingState, store: CampusStore) {
        self.sharing = sharing
        self.store = store
    }

    var isSharingOn: Bool {
        get { sharing.isEnabled }
        set { sharing.setEnabled(newValue) }
    }

    var status: SharingStatus { sharing.status }
    var isPermissionDenied: Bool { sharing.permission == .denied }
    var lastUpdateAt: Date? { sharing.lastUpdateAt }
    var nextUpdateAt: Date? { sharing.nextUpdateAt }
    var updateInterval: TimeInterval { sharing.updateInterval }
    var campusName: String { store.campus.shortName }
    var isActive: Bool { status == .active }

    var statusTitle: String {
        switch status {
        case .off: "Sharing is off"
        case .active: "You're contributing"
        case .permissionDenied: "Location access is off"
        }
    }

    var statusSubtitle: String {
        switch status {
        case .off: "Turn on sharing to help \(campusName) see where campus is busy. You can still view the heatmap either way."
        case .active: "Your location joins the anonymous heatmap every 2 minutes."
        case .permissionDenied: "Campus Pulse can't use your location. Enable it in Settings to contribute."
        }
    }

    var statusLabel: String {
        switch status {
        case .off: "Off"
        case .active: "Active"
        case .permissionDenied: "Blocked"
        }
    }

    var tint: Color {
        switch status {
        case .active: Theme.Colors.live
        case .permissionDenied: Theme.Colors.danger
        case .off: Theme.Colors.textTertiary
        }
    }
}
