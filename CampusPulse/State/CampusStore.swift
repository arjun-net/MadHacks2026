import Foundation
import Observation

/// UI state for the selected campus and the sample activity snapshot it displays.
/// Periodically swaps in a slightly different sample so the map and stats animate.
@Observable
@MainActor
final class CampusStore {
    let campuses: [Campus]
    private(set) var campus: Campus
    private(set) var snapshot: CampusSnapshot?
    private(set) var state: LoadState = .idle
    private(set) var isRefreshing = false

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var loopTask: Task<Void, Never>?

    init(campuses: [Campus], preferences: AppPreferences, initialSnapshot: CampusSnapshot? = nil) {
        self.campuses = campuses
        self.preferences = preferences
        self.campus = campuses.first { $0.id == preferences.selectedCampusID } ?? campuses[0]
        if let initialSnapshot, initialSnapshot.campusID == campus.id {
            snapshot = initialSnapshot
            state = initialSnapshot.isEmpty ? .empty : .loaded
        }
    }

    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(AppConfig.sampleRefreshInterval))
            }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        let requested = campus
        if snapshot == nil { state = .loading }
        isRefreshing = true
        defer { isRefreshing = false }
        // Brief pause so loading states and transitions are visible.
        try? await Task.sleep(for: snapshot == nil ? .milliseconds(900) : .milliseconds(250))
        guard requested.id == campus.id else { return }
        tick += 1
        let next = SampleActivityData.snapshot(for: requested, tick: tick)
        snapshot = next
        state = next.isEmpty ? .empty : .loaded
    }

    func select(_ newCampus: Campus) {
        guard newCampus.id != campus.id else { return }
        campus = newCampus
        preferences.selectedCampusID = newCampus.id
        snapshot = nil
        state = .loading
        isRefreshing = false
        loopTask?.cancel()
        loopTask = nil
        start()
    }
}
