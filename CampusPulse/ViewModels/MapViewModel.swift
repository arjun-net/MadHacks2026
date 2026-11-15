import Observation
import SwiftUI

@Observable
@MainActor
final class MapViewModel {
    let store: CampusStore
    private let sharing: SharingState

    var isHeatmapVisible = true
    private(set) var selectedAreaID: String?
    private(set) var recenterToken = 0

    init(store: CampusStore, sharing: SharingState) {
        self.store = store
        self.sharing = sharing
    }

    var campus: Campus { store.campus }
    var snapshot: CampusSnapshot? { store.snapshot }
    var loadState: LoadState { store.state }
    var sharingStatus: SharingStatus { sharing.status }

    var selectedActivity: AreaActivity? {
        guard let selectedAreaID else { return nil }
        return snapshot?.activity(for: selectedAreaID)
    }

    var showsInitialLoading: Bool {
        snapshot == nil && (loadState == .loading || loadState == .idle)
    }

    var favoriteAreaIDs: [String] { store.preferences.favoriteAreaIDs }

    func isFavorite(_ areaID: String) -> Bool { store.preferences.isFavorite(areaID) }

    func toggleFavorite(_ areaID: String) { store.preferences.toggleFavorite(areaID) }

    func select(areaID: String?) {
        withAnimation(Theme.Motion.smooth) {
            selectedAreaID = areaID
        }
    }

    func toggleHeatmap() {
        isHeatmapVisible.toggle()
    }

    func recenter() {
        select(areaID: nil)
        recenterToken += 1
    }

    func retry() {
        Task { await store.refresh() }
    }

    func campusDidChange() {
        selectedAreaID = nil
    }
}
