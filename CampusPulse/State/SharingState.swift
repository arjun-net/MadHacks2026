import Observation
import SwiftUI

enum SharingStatus: Equatable {
    case off
    case active
    case permissionDenied
}

/// Placeholder for the system location permission, shown in the UI only.
enum PermissionDisplay: Equatable {
    case notRequested, allowed, denied

    var displayName: String {
        switch self {
        case .notRequested: "Not Requested"
        case .allowed: "While Using"
        case .denied: "Denied"
        }
    }

    var tint: Color {
        switch self {
        case .allowed: Theme.Colors.live
        case .denied: Theme.Colors.danger
        case .notRequested: Theme.Colors.warning
        }
    }
}

/// UI-only state for the sharing toggle. No location is read or sent; timestamps are
/// placeholders so the status tiles and countdown have something to show.
@Observable
@MainActor
final class SharingState {
    private(set) var permission: PermissionDisplay
    private(set) var lastUpdateAt: Date?
    private(set) var nextUpdateAt: Date?

    let updateInterval = AppConfig.updateInterval

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private var timerTask: Task<Void, Never>?

    init(preferences: AppPreferences, permission: PermissionDisplay = .notRequested) {
        self.preferences = preferences
        self.permission = permission
        if isEnabled { startClock() }
    }

    var isEnabled: Bool { preferences.sharingEnabled }

    var status: SharingStatus {
        if permission == .denied { return .permissionDenied }
        return isEnabled ? .active : .off
    }

    func setEnabled(_ enabled: Bool) {
        guard permission != .denied else { return }
        preferences.sharingEnabled = enabled
        if enabled {
            if permission == .notRequested { permission = .allowed }
            startClock()
        } else {
            timerTask?.cancel()
            timerTask = nil
            nextUpdateAt = nil
        }
    }

    /// Used by previews and the debug launch option to show the denied state.
    func simulate(permission: PermissionDisplay) {
        self.permission = permission
        if permission == .denied { setEnabledSilently(false) }
    }

    private func setEnabledSilently(_ enabled: Bool) {
        preferences.sharingEnabled = enabled
        timerTask?.cancel()
        timerTask = nil
        nextUpdateAt = nil
    }

    private func startClock() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.lastUpdateAt = .now
                self.nextUpdateAt = Date().addingTimeInterval(self.updateInterval)
                try? await Task.sleep(for: .seconds(self.updateInterval))
            }
        }
    }
}
