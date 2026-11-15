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

/// Loading a building's story for its detail screen.
enum BuildingStoryState: Equatable {
    case loading
    case loaded(BuildingStory)
    case failed(String)
}

/// Loading a building's past days: one story per day, newest first. Each day's `current` is
/// that day's count at this time of day; its `sameWeekday` gives what's usual for that weekday.
enum PastDaysState: Equatable {
    case loading
    case loaded([BuildingStory])
    case failed(String)
}

@Observable
@MainActor
final class ActivityViewModel {
    let store: CampusStore

    /// Building stories by area ID, with when each was fetched.
    private(set) var stories: [String: (state: BuildingStoryState, fetchedAt: Date)] = [:]
    @ObservationIgnored private let storyProvider = BuildingStoryProvider()
    /// A loaded story is reused for this long before it's fetched again.
    private static let storyLifetime: TimeInterval = 5 * 60

    /// Past days by area ID, with when they were fetched.
    private(set) var pastDays: [String: (state: PastDaysState, fetchedAt: Date)] = [:]
    /// How many days back the past-days section goes.
    static let pastDayCount = 7
    /// Past days don't change, but "this time of day" moves on, so they're refetched this often.
    private static let pastDaysLifetime: TimeInterval = 15 * 60

    init(store: CampusStore) {
        self.store = store
    }

    var campus: Campus { store.campus }
    /// The Activity tab's reading: the live one on fake data, else the server's stored day (see `CampusStore`).
    var snapshot: CampusSnapshot? { store.historySnapshot }
    var loadState: LoadState { store.historyState }

    private var selectedFilter: AreaFilter = .all

    /// Falls back to `.all` when the selected filter has no areas on the current campus.
    /// Navigation stack for the Activity tab, so other tabs can open an area's detail.
    var path: [AreaRoute] = []

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

    /// Starred places on this campus, busiest first.
    var favorites: [AreaActivity] {
        let ids = Set(store.preferences.favoriteAreaIDs)
        return (snapshot?.areasByActivity ?? []).filter { ids.contains($0.id) }
    }

    func isFavorite(_ areaID: String) -> Bool { store.preferences.isFavorite(areaID) }

    func toggleFavorite(_ areaID: String) { store.preferences.toggleFavorite(areaID) }

    func activity(for areaID: String) -> AreaActivity? {
        snapshot?.activity(for: areaID)
    }

    /// Usual busy times and past days for an area: generated when the app runs on fake data,
    /// otherwise from the server's stored day.
    func insights(for areaID: String) -> AreaInsights? {
        guard let snapshot, let activity = snapshot.activity(for: areaID) else { return nil }
        if AppConfig.simulatesActivityData {
            return SampleActivityData.insights(for: activity, campus: campus, date: snapshot.generatedAt)
        }
        if let history = store.history, history.campusID == campus.id {
            return history.insights(for: activity, now: snapshot.generatedAt)
        }
        return store.isPreview ? SampleActivityData.insights(for: activity, campus: campus, date: snapshot.generatedAt) : nil
    }

    func storyState(for areaID: String) -> BuildingStoryState {
        stories[areaID]?.state ?? .loading
    }

    /// Loads the building's story unless a recent one is in hand (`force` refetches anyway).
    /// A failed fetch keeps showing the last good story, if there is one.
    func loadStory(for areaID: String, force: Bool = false) async {
        guard let area = campus.area(withID: areaID) else { return }
        if !force, let cached = stories[areaID], case .loaded = cached.state,
           Date.now.timeIntervalSince(cached.fetchedAt) < Self.storyLifetime {
            return
        }
        let previous = stories[areaID]
        if previous == nil { stories[areaID] = (.loading, .now) }
        do {
            let story = try await storyProvider.story(for: area, campus: campus, live: activity(for: areaID))
            stories[areaID] = (.loaded(story), .now)
        } catch {
            if let previous, case .loaded = previous.state { return }
            stories[areaID] = (.failed(error.localizedDescription), .now)
        }
    }

    func pastDaysState(for areaID: String) -> PastDaysState {
        pastDays[areaID]?.state ?? .loading
    }

    /// Loads the building's last `pastDayCount` days at the current time of day, in parallel.
    /// A day that fails to load is left out; only if every day fails is the section an error.
    func loadPastDays(for areaID: String, force: Bool = false) async {
        guard let area = campus.area(withID: areaID) else { return }
        if !force, let cached = pastDays[areaID], case .loaded = cached.state,
           Date.now.timeIntervalSince(cached.fetchedAt) < Self.pastDaysLifetime {
            return
        }
        let previous = pastDays[areaID]
        if previous == nil { pastDays[areaID] = (.loading, .now) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = AppConfig.campusTimeZone
        let now = Date.now
        // Same wall-clock time on each earlier day (calendar math keeps it right across DST).
        let moments = (1...Self.pastDayCount).compactMap { calendar.date(byAdding: .day, value: -$0, to: now) }
        let provider = storyProvider
        let campus = campus

        var days: [BuildingStory] = []
        var firstError: Error?
        await withTaskGroup(of: Result<BuildingStory, Error>.self) { group in
            for moment in moments {
                group.addTask {
                    do { return .success(try await provider.story(for: area, campus: campus, live: nil, at: moment)) }
                    catch { return .failure(error) }
                }
            }
            for await result in group {
                switch result {
                case .success(let story): days.append(story)
                case .failure(let error): firstError = firstError ?? error
                }
            }
        }

        if days.isEmpty, let firstError {
            if let previous, case .loaded = previous.state { return }
            pastDays[areaID] = (.failed(firstError.localizedDescription), .now)
            return
        }
        pastDays[areaID] = (.loaded(days.sorted { $0.current.date > $1.current.date }), .now)
    }

    func refresh() async {
        await store.refresh()
    }
}
