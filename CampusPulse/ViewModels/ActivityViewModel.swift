import Observation
import Foundation

/// Groups of places people look for together on the Activity screen.
enum AreaFilter: String, CaseIterable, Identifiable, Sendable {
    case all, study, dining, recreation, hangouts, housing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .study: "Study"
        case .dining: "Dining"
        case .recreation: "Recreation"
        case .hangouts: "Hangouts"
        case .housing: "Housing"
        }
    }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2.fill"
        case .study: "books.vertical.fill"
        case .dining: "fork.knife"
        case .recreation: "figure.run"
        case .hangouts: "cup.and.saucer.fill"
        case .housing: "bed.double.fill"
        }
    }

    /// `nil` means every category.
    var categories: Set<AreaCategory>? {
        switch self {
        case .all: nil
        case .study: [.library, .academic]
        case .dining: [.dining]
        case .recreation: [.recreation, .athletics]
        case .hangouts: [.union, .outdoors]
        case .housing: [.housing]
        }
    }

    func includes(_ category: AreaCategory) -> Bool {
        categories?.contains(category) ?? true
    }
}

enum AreaSort: String, CaseIterable, Identifiable, Sendable {
    case busiest, quietest, name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .busiest: "Busiest first"
        case .quietest: "Quietest first"
        case .name: "A–Z"
        }
    }

    var shortTitle: String {
        switch self {
        case .busiest: "Busiest"
        case .quietest: "Quietest"
        case .name: "A–Z"
        }
    }

    var symbol: String {
        switch self {
        case .busiest: "flame"
        case .quietest: "leaf"
        case .name: "textformat"
        }
    }
}

@Observable
@MainActor
final class ActivityViewModel {
    let store: CampusStore

    init(store: CampusStore) {
        self.store = store
    }

    var campus: Campus { store.campus }
    var snapshot: CampusSnapshot? { store.snapshot }
    var loadState: LoadState { store.state }

    private var selectedFilter: AreaFilter = .all

    /// Falls back to `.all` when the selected filter has no areas on the current campus.
    var filter: AreaFilter {
        get { availableFilters.contains(selectedFilter) ? selectedFilter : .all }
        set { selectedFilter = newValue }
    }
    var sort: AreaSort = .busiest

    /// Filters that match at least one area on this campus.
    var availableFilters: [AreaFilter] {
        let categories = Set(campus.areas.map(\.category))
        return AreaFilter.allCases.filter { filter in
            filter == .all || categories.contains { filter.includes($0) }
        }
    }

    func count(for filter: AreaFilter) -> Int {
        snapshot?.areas.filter { filter.includes($0.area.category) }.count ?? 0
    }

    /// Areas matching the current filter, busiest first.
    private var filteredAreas: [AreaActivity] {
        (snapshot?.areasByActivity ?? []).filter { filter.includes($0.area.category) }
    }

    var busiest: [AreaActivity] { Array(filteredAreas.prefix(5)) }

    var quietSpots: [AreaActivity] {
        var candidates = filteredAreas
        if filter == .all {
            // Prefer genuinely useful quiet places (libraries, unions, academic buildings) over a stadium.
            let useful: Set<AreaCategory> = [.library, .union, .academic, .dining, .outdoors]
            candidates = candidates.filter { useful.contains($0.area.category) }
        }
        return Array(candidates.reversed().prefix(3))
    }

    var allAreas: [AreaActivity] {
        switch sort {
        case .busiest: filteredAreas
        case .quietest: filteredAreas.reversed()
        case .name: filteredAreas.sorted { $0.area.name.localizedStandardCompare($1.area.name) == .orderedAscending }
        }
    }

    var participantsText: String {
        guard let snapshot else { return "—" }
        return "≈ " + Formatting.number(snapshot.participantCount)
    }

    var activeAreasText: String {
        guard let snapshot else { return "—" }
        return "\(snapshot.activeAreaCount) of \(snapshot.areas.count)"
    }

    func activity(for areaID: String) -> AreaActivity? {
        snapshot?.activity(for: areaID)
    }

    /// History and typical busy times for an area, anchored to the latest snapshot.
    func insights(for areaID: String) -> AreaInsights? {
        guard let snapshot, let activity = snapshot.activity(for: areaID) else { return nil }
        return SampleActivityData.insights(for: activity, campus: campus, date: snapshot.generatedAt)
    }

    func refresh() async {
        await store.refresh()
    }
}
